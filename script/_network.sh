# Resolve the target network. Sourced by the other scripts, not run directly.
#
# NETWORK picks the RPC, deliberately overriding anything .env says. Letting .env
# set RPC_URL while NETWORK said something else is how you deploy to mainnet
# believing you are on testnet. The chain id assertion below is the second guard.

NETWORK="${NETWORK:-mainnet}"

case "$NETWORK" in
  mainnet)
    RPC_URL=https://rpc.mainnet.arc.io
    CHAIN_ID_EXPECTED=5042
    EXPLORER=https://explorer.arc.io
    VERIFIER_URL=https://explorer.arc.io/api/
    ;;
  testnet)
    RPC_URL=https://rpc.testnet.arc.io
    CHAIN_ID_EXPECTED=5042002
    EXPLORER=https://explorer.testnet.arc.io
    VERIFIER_URL=https://explorer.testnet.arc.io/api/
    ;;
  *)
    printf '\033[31merror: unknown NETWORK "%s", use mainnet or testnet\033[0m\n' "$NETWORK" >&2
    exit 1
    ;;
esac

# Escape hatch for an alternate provider on the same chain. The chain id check still runs.
[ -n "${ARC_RPC_OVERRIDE:-}" ] && RPC_URL="$ARC_RPC_OVERRIDE"

DEPLOYMENTS="deployments/arc-$NETWORK.json"

assert_chain() {
  local actual
  actual=$(cast chain-id --rpc-url "$RPC_URL") || {
    printf '\033[31merror: cannot reach %s\033[0m\n' "$RPC_URL" >&2; exit 1; }
  if [ "$actual" != "$CHAIN_ID_EXPECTED" ]; then
    printf '\033[31merror: %s should be chain %s but the RPC reports %s. refusing.\033[0m\n' \
      "$NETWORK" "$CHAIN_ID_EXPECTED" "$actual" >&2
    exit 1
  fi
  printf '  network    %s (chain %s)\n' "$NETWORK" "$actual"
}
