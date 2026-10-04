#!/usr/bin/env bash
# Register the agent in Arc's canonical ERC-8004 IdentityRegistry.
#
# The registry is an ERC-721 that mints an identity to whoever calls register(). Two
# things that shape how this works:
#
#  1. It must be called by the agent's own wallet, not through PerDiem. PerDiem is a
#     contract with no onERC721Received, so _safeMint refuses it with
#     ERC721InvalidReceiver. Verified against the live contract.
#
#  2. register(string) is NOT payable. Attaching value reverts. So this costs gas only
#     and nothing leaves permanently. The agent's identity is an NFT it keeps.
#
# The registry is mainnet-only on Arc. There is no testnet deployment, so the rehearsal
# is a simulated eth_call against the real contract, which this script always runs first.
#
#   NETWORK=mainnet ./script/register-agent.sh            # simulate only
#   NETWORK=mainnet ./script/register-agent.sh --send     # actually register
set -euo pipefail

[ -z "${AGENT_KEY:-}" ] && [ -f .env ] && { set -a; . ./.env; set +a; }
. "$(dirname "$0")/_network.sh"

REGISTRY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
CARD_URI="${CARD_URI:-https://raw.githubusercontent.com/RaymondAbiola/per-diem/main/agent/agent-card.json}"
SEND="${1:-}"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
good() { printf '  \033[32m%s\033[0m\n' "$*"; }
note() { printf '  \033[33m%s\033[0m\n' "$*"; }

case "${AGENT_KEY:-}" in
  *REPLACE_ME*|"") die "AGENT_KEY is missing or still a placeholder in .env" ;;
esac

AGENT=$(cast wallet address --private-key "$AGENT_KEY")

say "target"
assert_chain
CODE_LEN=$(( ($(cast code "$REGISTRY" --rpc-url "$RPC_URL" | wc -c) - 2) / 2 ))
[ "$CODE_LEN" -gt 0 ] || die "no ERC-8004 registry on $NETWORK (the registry is mainnet-only)"
echo "  registry   $REGISTRY  ($(cast call "$REGISTRY" 'name()(string)' --rpc-url "$RPC_URL"))"
echo "  agent      $AGENT"
echo "  card       $CARD_URI"

HELD=$(cast call "$REGISTRY" 'balanceOf(address)(uint256)' "$AGENT" --rpc-url "$RPC_URL" | awk '{print $1}')
if [ "$HELD" != "0" ]; then
  note "this wallet already holds $HELD agent identity token(s)"
  note "registering again would mint a second one. use setAgentURI to change the card instead."
fi

say "does the card URL resolve?"
HTTP=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$CARD_URI" || echo "000")
if [ "$HTTP" = "200" ]; then
  good "card is live (HTTP 200)"
else
  note "card returns HTTP $HTTP. registration still works, and setAgentURI can fix it later,"
  note "but push the card to the default branch so anyone reading the registry can see it."
fi

say "simulating against the real contract"
SIM=$(cast call "$REGISTRY" "register(string)" "$CARD_URI" --from "$AGENT" --rpc-url "$RPC_URL" 2>&1) \
  || die "simulation reverted: $SIM"
NEXT_ID=$(python3 -c "print(int('$SIM', 16))")
good "would mint agent id $NEXT_ID to $AGENT"

if [ "$SEND" != "--send" ]; then
  say "dry run"
  echo "  nothing was broadcast. rerun with --send to register."
  exit 0
fi

say "registering"
BAL_BEFORE=$(cast balance "$AGENT" --rpc-url "$RPC_URL")
TX=$(cast send "$REGISTRY" "register(string)" "$CARD_URI" \
     --rpc-url "$RPC_URL" --private-key "$AGENT_KEY" \
     | grep -oE '^transactionHash +0x[0-9a-f]{64}' | grep -oE '0x[0-9a-f]{64}') \
  || die "registration failed to send"
[ -n "$TX" ] || die "no transaction hash returned"
echo "  tx         $TX"

STATUS=$(cast receipt "$TX" --rpc-url "$RPC_URL" --json \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])")
[ "$STATUS" = "0x1" ] || die "transaction reverted (status $STATUS)"

BAL_AFTER=$(cast balance "$AGENT" --rpc-url "$RPC_URL")
GAS_PAID=$(python3 -c "print(int('$BAL_BEFORE') - int('$BAL_AFTER'))")

say "confirming on-chain"
OWNER_OF=$(cast call "$REGISTRY" 'ownerOf(uint256)(address)' "$NEXT_ID" --rpc-url "$RPC_URL" | awk '{print $1}')
URI_OF=$(cast call "$REGISTRY" 'tokenURI(uint256)(string)' "$NEXT_ID" --rpc-url "$RPC_URL")
if [ "$(printf '%s' "$OWNER_OF" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$AGENT" | tr 'A-Z' 'a-z')" ]; then
  good "agent id $NEXT_ID is owned by the agent"
else
  die "agent id $NEXT_ID is owned by $OWNER_OF, not $AGENT"
fi
echo "  tokenURI   $URI_OF"
printf '  cost       $%s\n' "$(python3 -c "print(f'{int('$GAS_PAID')/1e18:.6f}')")"
echo "  explorer   $EXPLORER/token/$REGISTRY/instance/$NEXT_ID"

say "next"
echo "  set \"agentId\": $NEXT_ID in agent/agent-card.json, then push it."
echo "  to change the card URL later: cast send $REGISTRY 'setAgentURI(uint256,string)' $NEXT_ID '<url>'"
