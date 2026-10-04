#!/usr/bin/env bash
# Does the reimbursement actually hold the agent harmless?
#
# This is the claim the whole design rests on: the contract measures gas and pays the
# agent back, so if tailGas is wrong the agent's balance drifts.
#
# Drift is measured in GAS UNITS, read from each receipt, never in dollars. Arc's fee
# market moves (25 to 58 gwei observed inside one session) and tailGas is denominated
# in gas, so a dollar figure would conflate the metering error with the gas price.
#
#   NETWORK=testnet CALLS=20 ./script/verify.sh
set -euo pipefail

[ -z "${PRIVATE_KEY:-}" ] && [ -f .env ] && { set -a; . ./.env; set +a; }
. "$(dirname "$0")/_network.sh"

CALLS="${CALLS:-20}"
LOG=/tmp/perdiem_verify.txt

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$DEPLOYMENTS" ] || die "no $DEPLOYMENTS"
read -r CAP SERVICE < <(python3 -c "
import json; d=json.load(open('$DEPLOYMENTS'))['contracts']
print(d['PerDiem']['address'], d['PaidService']['address'])")

SPENT_TOPIC=$(cast keccak "Spent(address,uint256,uint256,uint256,uint256)")
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
FEE=$(cast call "$SERVICE" 'pricePerCall()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
TAIL=$(cast call "$CAP" 'tailGas()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
WINDOW=$(cast call "$CAP" 'windowLength()(uint64)' --rpc-url "$RPC_URL" | awk '{print $1}')

say "setup"
assert_chain
echo "  PerDiem    $CAP"
echo "  tailGas    $TAIL"
echo "  calls      $CALLS"

R0=$(cast call "$SERVICE" 'callsServed()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
CAP_BAL=$(cast balance "$CAP" --rpc-url "$RPC_URL")
NEED=$(python3 -c "print($CALLS * ($FEE + 2*10**16))")
if python3 -c "import sys; sys.exit(0 if int('$CAP_BAL') < $NEED else 1)"; then
  cast send "$CAP" --value "$NEED" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
  echo "  topped up the cap by $(python3 -c "print(f'\${$NEED/1e18:.6f}')")"
fi

say "running $CALLS calls"
: > "$LOG"
landed=0
for i in $(seq 1 "$CALLS"); do
  CD=$(cast calldata "query(bytes32)" "$(cast keccak "verify-$i-$(date +%s%N)")")
  TX=$(cast send "$CAP" "execute(address,uint256,bytes)" "$SERVICE" "$FEE" "$CD" \
       --rpc-url "$RPC_URL" --private-key "$AGENT_KEY" 2>/dev/null \
       | grep -oE '^transactionHash +0x[0-9a-f]{64}' | grep -oE '0x[0-9a-f]{64}') || TX=""
  if [ -z "$TX" ]; then
    printf '\r  call %s reverted, stopping\n' "$i"
    break
  fi
  landed=$((landed + 1))
  printf '\r  landed %s/%s' "$landed" "$CALLS"
  cast receipt "$TX" --rpc-url "$RPC_URL" --json \
    | TOPIC="$SPENT_TOPIC" python3 -c '
import sys, json, os
r = json.load(sys.stdin)
h = lambda v: int(v, 16) if isinstance(v, str) else int(v)
gu, eff = h(r["gasUsed"]), h(r["effectiveGasPrice"])
topic = os.environ["TOPIC"].lower()
rep = 0
for log in r["logs"]:
    if log["topics"][0].lower() == topic:
        rep = int(log["data"][2:][64:128], 16)
print(gu, eff, rep // eff if eff else 0)' >> "$LOG"
done
printf '\n'

R1=$(cast call "$SERVICE" 'callsServed()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')

say "result"
python3 "$(dirname "$0")/analyze_drift.py" "$LOG" "$TAIL" "$WINDOW" "$((R1 - R0))"
