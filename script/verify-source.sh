#!/usr/bin/env bash
# Publish source for the deployed contracts on Arc's Blockscout explorer.
#
# Deliberately separate from deploy.sh. Verification is retryable and can fail for
# reasons that have nothing to do with the deploy (explorer indexing lag, rate limits),
# and a failure here must never make a successful deployment look broken.
#
# A reviewer opening the grant submission wants to read the code at the address, so
# this is not cosmetic.
#
#   NETWORK=testnet ./script/verify-source.sh
set -euo pipefail

[ -z "${PRIVATE_KEY:-}" ] && [ -f .env ] && { set -a; . ./.env; set +a; }
. "$(dirname "$0")/_network.sh"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
good() { printf '  \033[32m%s\033[0m\n' "$*"; }
note() { printf '  \033[33m%s\033[0m\n' "$*"; }

[ -f "$DEPLOYMENTS" ] || die "no $DEPLOYMENTS, deploy first"

say "target"
assert_chain
echo "  explorer   $EXPLORER"
echo "  verifier   $VERIFIER_URL"

read -r PERDIEM SERVICE AGENT BUDGET WINDOW TAIL MAXGP PRICE OWNER < <(python3 -c "
import json
d = json.load(open('$DEPLOYMENTS'))
p, s = d['contracts']['PerDiem'], d['contracts']['PaidService']
a = p['args']
print(p['address'], s['address'], a['agent'], a['budgetPerWindow'], a['windowLength'],
      a['tailGas'], a['maxGasPrice'], s['args']['pricePerCall'], s['args']['beneficiary'])")

# Blockscout needs the constructor arguments ABI-encoded exactly as they were passed.
PERDIEM_ARGS=$(cast abi-encode "constructor(address,uint256,uint64,uint256,uint256)" \
  "$AGENT" "$BUDGET" "$WINDOW" "$TAIL" "$MAXGP")
SERVICE_ARGS=$(cast abi-encode "constructor(uint256,address)" "$PRICE" "$OWNER")

verify_one() {
  local addr="$1" target="$2" args="$3" name="${2##*:}"
  say "$name"
  echo "  address    $addr"
  if forge verify-contract "$addr" "$target" \
       --chain-id "$CHAIN_ID_EXPECTED" \
       --verifier blockscout \
       --verifier-url "$VERIFIER_URL" \
       --constructor-args "$args" \
       --watch 2>&1 | sed 's/^/    /'; then
    good "submitted"
  else
    note "verification did not complete, safe to re-run"
  fi
  echo "  $EXPLORER/address/$addr"
}

verify_one "$SERVICE" src/PaidService.sol:PaidService "$SERVICE_ARGS"
verify_one "$PERDIEM" src/PerDiem.sol:PerDiem "$PERDIEM_ARGS"

say "confirming on-chain state matches what we think we deployed"
check() {
  local label="$1" got="$2" want="$3"
  if [ "$(printf '%s' "$got" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$want" | tr 'A-Z' 'a-z')" ]; then
    good "$label = $got"
  else
    printf '  \033[31m%s mismatch: chain says %s, deployments says %s\033[0m\n' "$label" "$got" "$want"
  fi
}
check tailGas        "$(cast call "$PERDIEM" 'tailGas()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" "$TAIL"
check budgetPerWindow "$(cast call "$PERDIEM" 'budgetPerWindow()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" "$BUDGET"
check windowLength   "$(cast call "$PERDIEM" 'windowLength()(uint64)' --rpc-url "$RPC_URL" | awk '{print $1}')" "$WINDOW"
check maxGasPrice    "$(cast call "$PERDIEM" 'maxGasPrice()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" "$MAXGP"
check agent          "$(cast call "$PERDIEM" 'agent()(address)' --rpc-url "$RPC_URL" | awk '{print $1}')" "$AGENT"
check pricePerCall   "$(cast call "$SERVICE" 'pricePerCall()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" "$PRICE"
check beneficiary    "$(cast call "$SERVICE" 'beneficiary()(address)' --rpc-url "$RPC_URL" | awk '{print $1}')" "$OWNER"
