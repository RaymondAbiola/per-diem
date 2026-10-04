#!/usr/bin/env bash
# Calibrate tailGas against real Arc mainnet, then verify the reimbursement is honest.
#
# Local EVM gas numbers do not transfer to Arc. arc-meter measured cold SLOAD at
# 10,761 gas on Arc against 2,816 locally, so every constant in here has to come from
# the chain itself rather than from a local test run. That is what this script is for.
#
# Usage:
#   export PRIVATE_KEY=0x...        # owner, funds and deploys
#   export AGENT_KEY=0x...          # the agent, submits metered calls
#   ./script/calibrate.sh
set -euo pipefail

RPC_URL="${RPC_URL:-https://rpc.mainnet.arc.io}"
ROUNDS="${ROUNDS:-5}"
EXPECTED_CHAIN_ID=5042

# $1.00 in 18 decimal native units
ONE_DOLLAR=1000000000000000000
BUDGET="${BUDGET:-$ONE_DOLLAR}"          # $1 per window for calibration
WINDOW="${WINDOW:-86400}"
MAX_GAS_PRICE="${MAX_GAS_PRICE:-200000000000}"  # 200 gwei ceiling
PRICE_PER_CALL="${PRICE_PER_CALL:-1000000000000}"  # $0.000001 per service call

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
usd() { python3 -c "print(f'\${int($1)/1e18:.8f}')"; }

# Load .env unless keys are already in the environment (fork runs set their own).
if [ -z "${PRIVATE_KEY:-}" ] && [ -f .env ]; then
  set -a; . ./.env; set +a
fi

: "${PRIVATE_KEY:?set PRIVATE_KEY (owner)}"
: "${AGENT_KEY:?set AGENT_KEY (agent)}"

# Refuse to run on placeholders. Reports the variable name only, never its value.
for v in PRIVATE_KEY AGENT_KEY; do
  case "${!v:-}" in
    *REPLACE_ME*|"") die "$v is still a placeholder in .env, replace it first" ;;
  esac
done

OWNER=$(cast wallet address --private-key "$PRIVATE_KEY")
AGENT=$(cast wallet address --private-key "$AGENT_KEY")

say "preflight"
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
[ "$CHAIN_ID" = "$EXPECTED_CHAIN_ID" ] || die "wrong chain: got $CHAIN_ID, want $EXPECTED_CHAIN_ID"
GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL")
OWNER_BAL=$(cast balance "$OWNER" --rpc-url "$RPC_URL")
AGENT_BAL=$(cast balance "$AGENT" --rpc-url "$RPC_URL")

echo "chain id      $CHAIN_ID (Arc mainnet)"
echo "gas price     $GAS_PRICE wei ($(python3 -c "print(f'{int($GAS_PRICE)/1e9:.3f}')") gwei)"
echo "owner         $OWNER  $(usd "$OWNER_BAL")"
echo "agent         $AGENT  $(usd "$AGENT_BAL")"

# Deploy plus calibration rounds plus funding. Generous but still cents.
MIN_OWNER=$((ONE_DOLLAR / 100))
if [ "$(python3 -c "print(1 if int('$OWNER_BAL') < $MIN_OWNER else 0)")" = "1" ]; then
  die "owner needs USDC on Arc mainnet. Bridge via portal.arc.io, then rerun.
       Gas on Arc is USDC, so the bridged USDC funds everything."
fi
if [ "$(python3 -c "print(1 if int('$AGENT_BAL') == 0 else 0)")" = "1" ]; then
  die "agent needs a small USDC float to front gas. It gets reimbursed per call."
fi

say "deploying"
SERVICE=$(forge create src/PaidService.sol:PaidService \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "$PRICE_PER_CALL" "$OWNER" \
  | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')
[ -n "$SERVICE" ] || die "PaidService deploy failed"
echo "PaidService  $SERVICE"

# tailGas starts at 0 on purpose: the gap it leaves is exactly what we measure.
PERDIEM=$(forge create src/PerDiem.sol:PerDiem \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "$AGENT" "$BUDGET" "$WINDOW" 0 "$MAX_GAS_PRICE" \
  | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')
[ -n "$PERDIEM" ] || die "PerDiem deploy failed"
echo "PerDiem      $PERDIEM"

say "funding PerDiem"
cast send "$PERDIEM" --value "$BUDGET" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
echo "sent $(usd "$BUDGET") to the cap"

SPENT_TOPIC=$(cast keccak "Spent(address,uint256,uint256,uint256,uint256)")

say "calibration rounds"
printf '%-6s %-12s %-12s %-10s %s\n' round reported actual delta_gas note
: > /tmp/perdiem_deltas.txt

for i in $(seq 1 "$ROUNDS"); do
  INPUT=$(cast keccak "round-$i")
  CALLDATA=$(cast calldata "query(bytes32)" "$INPUT")

  TX=$(cast send "$PERDIEM" \
    "execute(address,uint256,bytes)" "$SERVICE" "$PRICE_PER_CALL" "$CALLDATA" \
    --rpc-url "$RPC_URL" --private-key "$AGENT_KEY" \
    | grep -oE '^transactionHash +0x[0-9a-f]{64}' | grep -oE '0x[0-9a-f]{64}')
  [ -n "$TX" ] || die "execute() round $i failed"

  RECEIPT=$(cast receipt "$TX" --rpc-url "$RPC_URL" --json)

  read -r GAS_USED EFF_PRICE REPORTED < <(python3 - "$RECEIPT" "$SPENT_TOPIC" <<'PY'
import sys, json
r = json.loads(sys.argv[1]); topic = sys.argv[2].lower()
gas_used = int(r["gasUsed"], 16) if isinstance(r["gasUsed"], str) else int(r["gasUsed"])
eff = r.get("effectiveGasPrice")
eff = int(eff, 16) if isinstance(eff, str) else int(eff)
reported = 0
for log in r["logs"]:
    if log["topics"][0].lower() == topic:
        data = log["data"][2:]
        # value, gasCost, windowSpent, windowRemaining
        reported = int(data[64:128], 16)
print(gas_used, eff, reported)
PY
)

  # What the agent truly paid in gas for this transaction, straight from the receipt.
  ACTUAL=$((GAS_USED * EFF_PRICE))
  # What the contract measured and reimbursed. Both are pure gas, no service fee.
  REPORTED_GAS=$REPORTED
  DELTA_GAS=$(python3 -c "print(max(0, ($ACTUAL - $REPORTED_GAS)//$EFF_PRICE))")
  echo "$DELTA_GAS" >> /tmp/perdiem_deltas.txt

  NOTE=$([ "$DELTA_GAS" -gt 0 ] && echo "under by ${DELTA_GAS}g" || echo "covered")
  printf '%-6s %-12s %-12s %-10s %s\n' "$i" "$REPORTED_GAS" "$ACTUAL" "$DELTA_GAS" "$NOTE"
done

say "result"
python3 - <<PY
deltas = [int(x) for x in open('/tmp/perdiem_deltas.txt') if x.strip()]
gp = $GAS_PRICE
hi, avg = max(deltas), sum(deltas)//len(deltas)
rec = hi + (hi // 10)   # cover the worst round plus 10%
print(f"deltas (gas)      {deltas}")
print(f"worst / mean      {hi} / {avg}")
print(f"recommended       tailGas = {rec}")
print(f"costs the agent   \${rec*gp/1e18:.8f} per call if left at 0")
print()
print("Set it with:")
print(f"  cast send $PERDIEM 'calibrateTailGas(uint256)' {rec} \\\\")
print(f"    --rpc-url $RPC_URL --private-key \$PRIVATE_KEY")
PY

cat <<EOF

addresses
  PaidService  $SERVICE
  PerDiem      $PERDIEM
  owner        $OWNER
  agent        $AGENT
EOF
