#!/usr/bin/env bash
# Deploy PaidService and PerDiem to Arc mainnet.
#
# tailGas is deliberately 0 here. The gap that leaves is exactly what the
# calibration step measures against real receipts.
#
# Deployed addresses are written to deployments/arc-mainnet.json, which is public
# data and belongs in the repo. Nothing is written back to .env.
set -euo pipefail

[ -f .env ] && { set -a; . ./.env; set +a; }

RPC_URL="${RPC_URL:-https://rpc.mainnet.arc.io}"
EXPECTED_CHAIN_ID=5042
OUT=deployments/arc-mainnet.json

# $0.002, at rough parity with gas so the payload and execution legs are both
# visible on the dashboard. Recoverable via sweep(), so it costs nothing net.
PRICE_PER_CALL="${PRICE_PER_CALL:-2000000000000000}"
BUDGET="${BUDGET:-1000000000000000000}"
WINDOW="${WINDOW:-86400}"
MAX_GAS_PRICE="${MAX_GAS_PRICE:-200000000000}"
TAIL_GAS=0

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

for v in PRIVATE_KEY AGENT_KEY; do
  case "${!v:-}" in
    *REPLACE_ME*|"") die "$v is still a placeholder in .env" ;;
  esac
done

if [ -f "$OUT" ] && [ "${1:-}" != "--force" ]; then
  die "$OUT already exists. These contracts are deployed. Pass --force to redeploy."
fi

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
[ "$CHAIN_ID" = "$EXPECTED_CHAIN_ID" ] || die "wrong chain: $CHAIN_ID, want $EXPECTED_CHAIN_ID"

OWNER=$(cast wallet address --private-key "$PRIVATE_KEY")
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL")
BAL_BEFORE=$(cast balance "$OWNER" --rpc-url "$RPC_URL")

say "deploying to Arc mainnet (chain $CHAIN_ID) at $(python3 -c "print(f'{int($GAS_PRICE)/1e9:.2f}')") gwei"
echo "  owner  $OWNER"
echo "  agent  $AGENT"

forge build --quiet

deploy() {
  local what="$1"; shift
  local out
  out=$(forge create "$what" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
        --broadcast --constructor-args "$@")
  local addr tx
  addr=$(echo "$out" | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')
  tx=$(echo "$out"   | grep -oE 'Transaction hash: 0x[0-9a-f]{64}' | grep -oE '0x[0-9a-f]{64}')
  [ -n "$addr" ] || die "$what deploy produced no address"
  echo "$addr $tx"
}

say "PaidService"
read -r SERVICE SERVICE_TX < <(deploy src/PaidService.sol:PaidService "$PRICE_PER_CALL" "$OWNER")
echo "  address  $SERVICE"
echo "  tx       $SERVICE_TX"

say "PerDiem"
read -r PERDIEM PERDIEM_TX < <(deploy src/PerDiem.sol:PerDiem \
  "$AGENT" "$BUDGET" "$WINDOW" "$TAIL_GAS" "$MAX_GAS_PRICE")
echo "  address  $PERDIEM"
echo "  tx       $PERDIEM_TX"

say "actual cost on Arc, versus the fork estimate"
gas_of() { cast receipt "$1" --rpc-url "$RPC_URL" --json \
  | python3 -c "import sys,json;d=json.load(sys.stdin);g=d['gasUsed'];print(int(g,16) if isinstance(g,str) else g)"; }
G1=$(gas_of "$SERVICE_TX"); G2=$(gas_of "$PERDIEM_TX")
BAL_AFTER=$(cast balance "$OWNER" --rpc-url "$RPC_URL")
python3 - <<PY
gp=$GAS_PRICE
for name,actual,est in (("PaidService",$G1,302926),("PerDiem",$G2,987054)):
    d=100*(actual-est)/est
    print(f"  {name:12s} {actual:>9,} gas  (fork said {est:>9,}, {d:+.1f}%)  \${actual*gp/1e18:.6f}")
print(f"  owner balance \${int('$BAL_BEFORE')/1e18:.6f} -> \${int('$BAL_AFTER')/1e18:.6f}"
      f"  spent \${(int('$BAL_BEFORE')-int('$BAL_AFTER'))/1e18:.6f}")
PY

mkdir -p deployments
cat > "$OUT" <<JSON
{
  "network": "arc-mainnet",
  "chainId": $CHAIN_ID,
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "owner": "$OWNER",
  "agent": "$AGENT",
  "contracts": {
    "PerDiem": {
      "address": "$PERDIEM",
      "tx": "$PERDIEM_TX",
      "gasUsed": $G2,
      "args": {
        "agent": "$AGENT",
        "budgetPerWindow": "$BUDGET",
        "windowLength": $WINDOW,
        "tailGas": $TAIL_GAS,
        "maxGasPrice": "$MAX_GAS_PRICE"
      }
    },
    "PaidService": {
      "address": "$SERVICE",
      "tx": "$SERVICE_TX",
      "gasUsed": $G1,
      "args": {
        "pricePerCall": "$PRICE_PER_CALL",
        "beneficiary": "$OWNER"
      }
    }
  }
}
JSON

say "wrote $OUT"
cat "$OUT"
