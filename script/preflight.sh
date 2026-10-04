#!/usr/bin/env bash
# Read-only. Broadcasts nothing, signs nothing, costs nothing.
# Confirms both wallets can fund step 7 before it spends anything irreversible.
set -euo pipefail

[ -f .env ] && { set -a; . ./.env; set +a; }

RPC_URL="${RPC_URL:-https://rpc.mainnet.arc.io}"
EXPECTED_CHAIN_ID=5042
USDC_ERC20="${USDC_ERC20:-0x3600000000000000000000000000000000000000}"

# Gas measured on an Arc mainnet fork. revm's schedule, so treat as estimates:
# Arc's real schedule differs and step 8 is what settles it.
GAS_DEPLOY_SERVICE=302926
GAS_DEPLOY_PERDIEM=987054
GAS_PER_CALL=91447

ok=0
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
pass() { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; ok=1; }
bad()  { printf '  \033[31m[fail]\033[0m %s\n' "$*"; ok=2; }
usd()  { python3 -c "print(f'\${int($1)/1e18:,.6f}')"; }

for v in PRIVATE_KEY AGENT_KEY; do
  case "${!v:-}" in
    *REPLACE_ME*|"") die "$v is still a placeholder in .env, replace it first" ;;
  esac
done

printf '\n\033[1mnetwork\033[0m\n'
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || die "cannot reach $RPC_URL"
[ "$CHAIN_ID" = "$EXPECTED_CHAIN_ID" ] \
  && pass "chain id $CHAIN_ID (Arc mainnet)" \
  || bad "chain id $CHAIN_ID, expected $EXPECTED_CHAIN_ID"
GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL")
printf '  gas price  %s gwei\n' "$(python3 -c "print(f'{int($GAS_PRICE)/1e9:.3f}')")"
SYM=$(cast call "$USDC_ERC20" 'symbol()(string)' --rpc-url "$RPC_URL" 2>/dev/null || echo '?')
pass "gas token is $SYM at $USDC_ERC20"

printf '\n\033[1mwallets\033[0m\n'
# Only the derived public address is printed. The key never leaves the variable.
OWNER=$(cast wallet address --private-key "$PRIVATE_KEY")
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
printf '  owner  %s\n' "$OWNER"
printf '  agent  %s\n' "$AGENT"

[ "$OWNER" != "$AGENT" ] \
  && pass "owner and agent are distinct keys" \
  || bad "owner and agent are the SAME key, which makes the cap meaningless"

# If the addresses were also pasted into .env, confirm they match the keys.
check_addr() {
  local label="$1" declared="$2" derived="$3"
  case "$declared" in
    ''|*REPLACE_ME*) return ;;
  esac
  if [ "$(echo "$declared" | tr 'A-Z' 'a-z')" = "$(echo "$derived" | tr 'A-Z' 'a-z')" ]; then
    pass "$label matches the key in .env"
  else
    bad "$label in .env does not match the key it is paired with"
  fi
}
check_addr OWNER_ADDRESS "${OWNER_ADDRESS:-}" "$OWNER"
check_addr AGENT_ADDRESS "${AGENT_ADDRESS:-}" "$AGENT"

printf '\n\033[1mbalances\033[0m\n'
OWNER_BAL=$(cast balance "$OWNER" --rpc-url "$RPC_URL")
AGENT_BAL=$(cast balance "$AGENT" --rpc-url "$RPC_URL")
OWNER_6=$(cast call "$USDC_ERC20" 'balanceOf(address)(uint256)' "$OWNER" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}')
printf '  owner  %s native (18dp)\n' "$(usd "$OWNER_BAL")"
printf '  agent  %s native (18dp)\n' "$(usd "$AGENT_BAL")"
# python, not bash: 18e18 overflows a signed 64-bit int and the test fails silently
if [ -n "${OWNER_6:-}" ] && python3 -c "import sys; sys.exit(0 if int('$OWNER_BAL')//10**12 == int('$OWNER_6') else 1)"; then
  pass "native/1e12 equals the ERC-20 view: one balance, two interfaces"
else
  warn "could not confirm the dual-decimal view"
fi

printf '\n\033[1mforecast at %s gwei\033[0m\n' "$(python3 -c "print(f'{int($GAS_PRICE)/1e9:.1f}')")"
python3 - <<PY
gp=$GAS_PRICE
rounds=int("${ROUNDS:-5}")
budget=int("${BUDGET:-1000000000000000000}")
items=[
 ("deploy PaidService", $GAS_DEPLOY_SERVICE*gp),
 ("deploy PerDiem",     $GAS_DEPLOY_PERDIEM*gp),
 (f"fund the cap (recoverable)", budget),
 (f"calibration, {rounds} rounds", rounds*$GAS_PER_CALL*gp),
]
for label,amt in items:
    print(f"  {label:34s} \${amt/1e18:>12.6f}")
spend=sum(a for l,a in items if "recoverable" not in l)
total=sum(a for _,a in items)
print(f"  {'-'*34} {'-'*13}")
print(f"  {'irreversible (gas only)':34s} \${spend/1e18:>12.6f}")
print(f"  {'needed up front incl. budget':34s} \${total/1e18:>12.6f}")
print()
ob=int("$OWNER_BAL"); ab=int("$AGENT_BAL")
need_owner=int(total*1.5)
need_agent=int(5*$GAS_PER_CALL*gp)
print(f"  owner has \${ob/1e18:.6f}, needs ~\${need_owner/1e18:.6f}  -> {'OK' if ob>=need_owner else 'SHORT'}")
print(f"  agent has \${ab/1e18:.6f}, needs ~\${need_agent/1e18:.6f}  -> {'OK' if ab>=need_agent else 'SHORT'}")
per=$GAS_PER_CALL*gp
print()
print(f"  each metered call costs \${per/1e18:.6f}")
print(f"  owner balance funds roughly {int(ob/per):,} calls after deploys")
PY

printf '\n'
case $ok in
  0) printf '\033[32mREADY\033[0m  nothing was broadcast. step 7 can deploy.\n\n' ;;
  1) printf '\033[33mREADY WITH WARNINGS\033[0m  review above before deploying.\n\n' ;;
  *) printf '\033[31mNOT READY\033[0m  fix the failures above first.\n\n'; exit 1 ;;
esac
