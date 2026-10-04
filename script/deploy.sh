#!/usr/bin/env bash
# Deploy PaidService and PerDiem to Arc mainnet.
#
# tailGas is deliberately 0 here. The gap that leaves is exactly what the
# calibration step measures against real receipts.
#
# Deployed addresses are written to deployments/arc-<network>.json, which is public
# data and belongs in the repo. Nothing is written back to .env.
set -euo pipefail

[ -f .env ] && { set -a; . ./.env; set +a; }
. "$(dirname "$0")/_network.sh"
OUT="$DEPLOYMENTS"

# $0.002, at rough parity with gas so the payload and execution legs are both visible
# on the dashboard. Recoverable via sweep(), so it costs nothing net.
#
# Deliberately NOT read from the environment. It is immutable once deployed, and a
# stale PRICE_PER_CALL in .env already silently overrode this default once and shipped
# a service priced 2000x too low. Deployment parameters belong in version control.
PRICE_PER_CALL=2000000000000000
BUDGET="${BUDGET:-1000000000000000000}"
WINDOW="${WINDOW:-86400}"
MAX_GAS_PRICE="${MAX_GAS_PRICE:-200000000000}"
# Measured on Arc testnet (chain 5042002), 8 rounds, zero variance across warm calls.
# Covers both the genuinely unobservable tail (the storage write, the reimbursement
# transfer, the event, the lock release) and the calldata floor's deliberate
# understatement, because calibration measured the total gap with tailGas at 0.
#
# A local fork said 26,135 for this. Arc says 14,187, so the fork was 84% high. Do not
# re-derive this number anywhere but a real Arc chain.
TAIL_GAS=14187

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

assert_chain
CHAIN_ID="$CHAIN_ID_EXPECTED"

OWNER=$(cast wallet address --private-key "$PRIVATE_KEY")
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL")
BAL_BEFORE=$(cast balance "$OWNER" --rpc-url "$RPC_URL")

say "deploying to Arc $NETWORK (chain $CHAIN_ID) at $(python3 -c "print(f'{int($GAS_PRICE)/1e9:.2f}')") gwei"
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
# deploy() runs in a subshell here, so its die() cannot stop this script. Check.
read -r SERVICE SERVICE_TX < <(deploy src/PaidService.sol:PaidService "$PRICE_PER_CALL" "$OWNER") || true
[ -n "${SERVICE:-}" ] || die "PaidService deploy failed, no address returned"
[ -n "${SERVICE_TX:-}" ] || die "PaidService deployed to $SERVICE but no tx hash was captured"
echo "  address  $SERVICE"
echo "  tx       $SERVICE_TX"

say "PerDiem"
read -r PERDIEM PERDIEM_TX < <(deploy src/PerDiem.sol:PerDiem \
  "$AGENT" "$BUDGET" "$WINDOW" "$TAIL_GAS" "$MAX_GAS_PRICE") || true
[ -n "${PERDIEM:-}" ] || die "PerDiem deploy failed, no address returned"
[ -n "${PERDIEM_TX:-}" ] || die "PerDiem deployed to $PERDIEM but no tx hash was captured"
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
  "network": "arc-$NETWORK",
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

say "next"
echo "  verify the source with: NETWORK=$NETWORK ./script/verify-source.sh"

say "wrote $OUT"
echo "  explorer   $EXPLORER/address/$PERDIEM"
cat "$OUT"
