#!/usr/bin/env bash
# Prove the cap binds on a real chain, not just in Forge.
#
# Two things this establishes that the unit tests cannot:
#
#  1. A plain eth_call cannot preflight the budget. Static calls run with
#     tx.gasprice = 0, so the gas leg evaluates to nothing and the check passes even
#     when a real send would be rejected. An agent that wants to know whether a call
#     fits has to simulate with an explicit gas price.
#
#  2. In the normal path, hitting the cap is free. Gas estimation reverts first, so the
#     client never broadcasts. Only an agent that forces a gas limit past the estimator
#     pays for the rejection.
#
# Restores the original budget on exit.
#
#   NETWORK=testnet ./script/prove-cap.sh
set -euo pipefail

[ -z "${PRIVATE_KEY:-}" ] && [ -f .env ] && { set -a; . ./.env; set +a; }
. "$(dirname "$0")/_network.sh"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
good() { printf '  \033[32m%s\033[0m\n' "$*"; }
note() { printf '  \033[33m%s\033[0m\n' "$*"; }
usd()  { python3 -c "print(f'\${int($1)/1e18:.8f}')"; }

[ -f "$DEPLOYMENTS" ] || die "no $DEPLOYMENTS"
read -r CAP SERVICE < <(python3 -c "
import json; d=json.load(open('$DEPLOYMENTS'))['contracts']
print(d['PerDiem']['address'], d['PaidService']['address'])")

AGENT=$(cast wallet address --private-key "$AGENT_KEY")
FEE=$(cast call "$SERVICE" 'pricePerCall()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
ORIG_BUDGET=$(cast call "$CAP" 'budgetPerWindow()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
WINDOW=$(cast call "$CAP" 'windowLength()(uint64)' --rpc-url "$RPC_URL" | awk '{print $1}')
GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL")

say "target"
assert_chain
echo "  PerDiem        $CAP"
echo "  budget now     $(usd "$ORIG_BUDGET")"

restore() {
  printf '\n  restoring budget to %s\n' "$(usd "$ORIG_BUDGET")"
  cast send "$CAP" 'setBudget(uint256,uint64)' "$ORIG_BUDGET" "$WINDOW" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null 2>&1 || true
}
trap restore EXIT

window_now() { cast call "$CAP" 'currentWindow()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}'; }
spent_now()  { cast call "$CAP" 'spentInWindow(uint256)(uint256)' "$(window_now)" \
                 --rpc-url "$RPC_URL" | awk '{print $1}'; }

SPENT=$(spent_now)
PER_CALL=$(python3 -c "print($FEE + 79499*$GAS_PRICE)")
TIGHT=$(python3 -c "print($SPENT + 3*$PER_CALL)")

say "tightening the budget"
echo "  already spent this window   $(usd "$SPENT")"
echo "  cost per call at $(python3 -c "print(f'{int($GAS_PRICE)/1e9:.1f}')") gwei   $(usd "$PER_CALL")"
echo "  new budget                  $(usd "$TIGHT")  (room for about 3)"
cast send "$CAP" 'setBudget(uint256,uint64)' "$TIGHT" "$WINDOW" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null

# Fund generously so "out of money" can never be mistaken for "cap bound".
CAP_BAL=$(cast balance "$CAP" --rpc-url "$RPC_URL")
NEED=$(python3 -c "print(8*($FEE + 2*10**16))")
if python3 -c "import sys; sys.exit(0 if int('$CAP_BAL') < $NEED else 1)"; then
  cast send "$CAP" --value "$NEED" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
  echo "  funded the cap with $(usd "$NEED") so running dry cannot be confused for the cap"
fi

SELECTOR=0x$(cast keccak 'CapExceeded(uint256,uint256)' | cut -c3-10)

say "spending into the cap"
landed=0
REJECTED_CD=""
for i in $(seq 1 10); do
  CD=$(cast calldata "query(bytes32)" "$(cast keccak "cap-$i-$(date +%s%N)")")

  # A static call with an explicit gas price, so the gas leg is actually priced.
  SIM=$(cast call "$CAP" "execute(address,uint256,bytes)" "$SERVICE" "$FEE" "$CD" \
        --from "$AGENT" --gas-price "$GAS_PRICE" --rpc-url "$RPC_URL" 2>&1 || true)
  SIM_REVERTED=no
  printf '%s' "$SIM" | grep -qi 'revert' && SIM_REVERTED=yes

  OUT=$(cast send "$CAP" "execute(address,uint256,bytes)" "$SERVICE" "$FEE" "$CD" \
        --rpc-url "$RPC_URL" --private-key "$AGENT_KEY" 2>&1 || true)

  if printf '%s' "$OUT" | grep -qi 'revert'; then
    REJECTED_CD="$CD"
    say "rejected on attempt $i"
    DATA=$(printf '%s' "$OUT" | grep -oE '0x[0-9a-fA-F]{72,}' | tail -1)
    if [ "${DATA:0:10}" = "$SELECTOR" ]; then
      good "selector is CapExceeded(uint256,uint256)"
      python3 - "$DATA" <<'PY'
import sys
d = sys.argv[1][10:]
needed, available = int(d[0:64], 16), int(d[64:128], 16)
print(f"  needed       ${needed/1e18:.8f}  (this call: fee plus metered gas)")
print(f"  available    ${available/1e18:.8f}  (headroom left in the window)")
print(f"  short by     ${(needed-available)/1e18:.8f}")
PY
    else
      echo "  revert data  ${DATA:0:74}"
    fi
    echo "  static call with gas price also reverted: $SIM_REVERTED"
    break
  fi

  landed=$((landed + 1))
  printf '  attempt %s landed\n' "$i"
done

[ -n "$REJECTED_CD" ] || die "the cap never bound in 10 attempts, budget sizing is off"

say "what the rejection costs"
A0=$(cast balance "$AGENT" --rpc-url "$RPC_URL")
note "gas estimation rejects it first, so nothing was broadcast"
printf '  agent balance unchanged: %s\n' \
  "$([ "$A0" = "$(cast balance "$AGENT" --rpc-url "$RPC_URL")" ] && echo yes || echo no)"

# Force past the estimator to show the other path: an on-chain revert the agent pays for.
cast send "$CAP" "execute(address,uint256,bytes)" "$SERVICE" "$FEE" "$REJECTED_CD" \
  --gas-limit 200000 --rpc-url "$RPC_URL" --private-key "$AGENT_KEY" >/dev/null 2>&1 || true
A1=$(cast balance "$AGENT" --rpc-url "$RPC_URL")
BURNED=$(python3 -c "print(max(0, int('$A0') - int('$A1')))")
printf '  forcing --gas-limit past the estimator costs the agent %s, unreimbursed\n' "$(usd "$BURNED")"

say "invariant"
FINAL=$(spent_now)
REMAIN=$(cast call "$CAP" 'remaining()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
SERVED=$(cast call "$SERVICE" 'callsServed()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
echo "  attempts that landed  $landed"
echo "  spent this window     $(usd "$FINAL")"
echo "  budget                $(usd "$TIGHT")"
echo "  remaining             $(usd "$REMAIN")  (dust, too small for another call)"
echo "  service callsServed   $SERVED"
if python3 -c "import sys; sys.exit(0 if int('$FINAL') <= int('$TIGHT') else 1)"; then
  good "spend never exceeded the budget. the cap held on-chain."
else
  die "INVARIANT VIOLATED: spend exceeds budget"
fi
