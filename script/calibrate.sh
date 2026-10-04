#!/usr/bin/env bash
# Measure tailGas against a real Arc chain, using the contracts actually deployed.
#
# tailGas covers the work execute() cannot observe from inside itself: the storage
# write, the reimbursement transfer, the event and the lock release. All of it happens
# after the last gasleft() reading, so the only honest way to size it is to compare
# what the contract billed against what the receipt says the transaction really cost.
#
# This has to run on a real Arc chain. A local fork runs revm's gas schedule, and
# arc-meter measured cold SLOAD at 10,761 gas on Arc against 2,816 locally, so fork
# numbers are not transferable.
#
#   NETWORK=testnet ./script/calibrate.sh
set -euo pipefail

[ -z "${PRIVATE_KEY:-}" ] && [ -f .env ] && { set -a; . ./.env; set +a; }
. "$(dirname "$0")/_network.sh"

ROUNDS="${ROUNDS:-8}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
usd() { python3 -c "print(f'\${int($1)/1e18:.8f}')"; }

for v in PRIVATE_KEY AGENT_KEY; do
  case "${!v:-}" in
    *REPLACE_ME*|"") die "$v is still a placeholder in .env" ;;
  esac
done

[ -f "$DEPLOYMENTS" ] || die "no $DEPLOYMENTS, run deploy.sh for this network first"
read -r CAP SERVICE < <(python3 -c "
import json; d=json.load(open('$DEPLOYMENTS'))['contracts']
print(d['PerDiem']['address'], d['PaidService']['address'])")

say "target"
assert_chain
echo "  PerDiem      $CAP"
echo "  PaidService  $SERVICE"

OWNER=$(cast wallet address --private-key "$PRIVATE_KEY")
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL")
FEE=$(cast call "$SERVICE" 'pricePerCall()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
TAIL=$(cast call "$CAP" 'tailGas()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
BUDGET=$(cast call "$CAP" 'budgetPerWindow()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
CAP_BAL=$(cast balance "$CAP" --rpc-url "$RPC_URL")

echo "  fee          $(usd "$FEE")"
echo "  tailGas      $TAIL"
echo "  budget       $(usd "$BUDGET")"
echo "  cap balance  $(usd "$CAP_BAL")"

[ "$TAIL" = "0" ] || printf '\033[33m  warning: tailGas is already %s, the measured gap will be the residual\033[0m\n' "$TAIL"

# The cap pays out the fee plus the reimbursement each round, so it needs a float.
NEED=$(python3 -c "print($ROUNDS * ($FEE + 10**16))")
if python3 -c "import sys; sys.exit(0 if int('$CAP_BAL') < $NEED else 1)"; then
  say "funding the cap"
  cast send "$CAP" --value "$NEED" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
  echo "  sent $(usd "$NEED")"
fi

SPENT_TOPIC=$(cast keccak "Spent(address,uint256,uint256,uint256,uint256)")

say "$ROUNDS rounds"
printf '  %-3s %-10s %-10s %-10s %-9s %s\n' '#' gasUsed billed gap cost note
: > /tmp/perdiem_gaps.txt

for i in $(seq 1 "$ROUNDS"); do
  CD=$(cast calldata "query(bytes32)" "$(cast keccak "round-$i-$(date +%s%N)")")

  TX=$(cast send "$CAP" "execute(address,uint256,bytes)" "$SERVICE" "$FEE" "$CD" \
    --rpc-url "$RPC_URL" --private-key "$AGENT_KEY" \
    | grep -oE '^transactionHash +0x[0-9a-f]{64}' | grep -oE '0x[0-9a-f]{64}') \
    || die "round $i failed to send"
  [ -n "$TX" ] || die "round $i produced no tx hash"

  read -r GAS_USED EFF REPORTED < <(
    cast receipt "$TX" --rpc-url "$RPC_URL" --json | python3 -c "
import sys, json
r = json.load(sys.stdin)
h = lambda v: int(v, 16) if isinstance(v, str) else int(v)
rep = 0
for log in r['logs']:
    if log['topics'][0].lower() == '$SPENT_TOPIC'.lower():
        rep = int(log['data'][2:][64:128], 16)   # value, gasCost, spent, remaining
print(h(r['gasUsed']), h(r['effectiveGasPrice']), rep)")

  # Pure gas on both sides: the receipt's total, versus what the contract reimbursed.
  GAP=$(python3 -c "print(max(0, ($GAS_USED*$EFF - $REPORTED)//$EFF))")
  echo "$GAP" >> /tmp/perdiem_gaps.txt
  BILLED=$(python3 -c "print($REPORTED//$EFF)")
  NOTE=$([ "$i" = "1" ] && echo "cold window" || echo "")
  printf '  %-3s %-10s %-10s %-10s %-9s %s\n' "$i" "$GAS_USED" "$BILLED" "$GAP" \
    "$(python3 -c "print(f'{$GAS_USED*$EFF/1e18:.6f}')")" "$NOTE"
done

say "result"
python3 - <<PY
gaps=[int(x) for x in open('/tmp/perdiem_gaps.txt') if x.strip()]
gp=$GAS_PRICE
cold, warm = gaps[0], gaps[1:] or gaps
hi, mean = max(warm), sum(warm)//len(warm)
print(f"  cold first call   {cold:,} gas")
print(f"  warm calls        min {min(warm):,}  mean {mean:,}  max {hi:,}")
print()
print(f"  calibrate to worst warm case : {hi + hi//20:,}  (+5% margin)")
print(f"  calibrate to the cold case   : {cold + cold//20:,}  (never short, overpays warm calls)")
print()
print(f"  fork said 26,135. Arc says {mean:,} on a warm call, {100*(mean-26135)/26135:+.1f}%.")
print()
print("  erring high means the agent's float drifts up and the cap drains faster.")
print("  erring low means the agent slowly funds the shortfall itself.")
PY
