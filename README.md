# PerDiem

A spending cap for autonomous agents that counts **what a call moves** and **what it costs to make** against a single USDC budget.

Live on Arc mainnet. Both contracts verified, the agent registered in Arc's ERC-8004 registry, and a dashboard where you can make the contract refuse a call in front of you.

| | |
|---|---|
| Dashboard | https://raymondabiola.github.io/per-diem/ |
| PerDiem | [`0x3795C17A048F8A6e3f4C52007104C744AB1d7B07`](https://explorer.arc.io/address/0x3795C17A048F8A6e3f4C52007104C744AB1d7B07) |
| PaidService | [`0x21436b32Cd55d544130e7548c9A7591195F4d33C`](https://explorer.arc.io/address/0x21436b32Cd55d544130e7548c9A7591195F4d33C) |
| Agent identity | [ERC-8004 #1412](https://explorer.arc.io/token/0x8004A169FB4a3325136EB29fA0ceB6D2e539a432/instance/1412) |
| Chain | Arc mainnet, 5042 |

---

## The problem this solves

Give an agent a key and you want to say "you may spend at most $5 a day." On every other EVM chain you cannot enforce that, because spending happens in two currencies at once.

An agent's spend has two legs. The value a call moves, denominated in whatever token. And the gas it burns, denominated in a volatile native asset. A contract cannot add those together, because it has no trustworthy way to know what its own execution just cost in dollars. It would need an oracle, and then the cap is only as honest as the price feed.

So the usual answer is to cap the value leg and leave the gas leg uncapped. The agent then has a second, unbounded budget nobody is watching.

## Why it works on Arc

Arc pays gas in USDC. There is no separate gas token: one balance per account, viewed at 18 decimals for gas accounting and 6 decimals through the ERC-20 interface, sharing the same underlying value.

That single fact makes `gasUsed * tx.gasprice` a dollar amount. Not a dollar estimate, a dollar amount, available inside the EVM with no oracle and no trust assumption.

PerDiem is what you can build once that is true:

```
budget check  =  value the call moves  +  dollar cost of making it
```

One number, one budget, both legs. **This contract cannot be ported to a chain with a volatile gas token.** The arithmetic at its center stops being arithmetic and becomes a price feed.

## How it works

The owner funds a cap contract and sets a budget per window, say $1 per 24 hours. The agent holds a separate key and cannot touch the money directly. It must ask the cap to act for it.

On each call the cap:

1. reads `gasleft()` on entry
2. performs the call, forwarding value from its own balance
3. reads `gasleft()` again and multiplies the difference by `tx.gasprice`, giving dollars
4. adds the value moved, checks the total against the window's remaining budget, and reverts if it does not fit
5. **reimburses the agent** for the gas it fronted

Step 5 is the part that matters. Without it the agent would quietly fund gas from its own pocket and the stated cap would be a fiction, bounding one leg while the other ran free. With it, every cent leaves one pot.

It also makes the measurement load-bearing. The contract pays out real money based on its own reading, so measuring too high drains the cap and measuring too low drains the agent. A number nobody pays for is a guess. This one has to be right.

### The blind spot, and what it cost to close

A contract cannot measure itself finishing up. After the final `gasleft()` reading it still has to write the new total, send the reimbursement and emit the event, and none of that lands on the meter.

Measured on a real Arc chain:

```
what the contract's own meter sees     65,312 gas
what the chain actually charges        79,499 gas
                                       ------
the blind spot                         14,187 gas
```

`tailGas` is set to 14,187 and the arithmetic closes exactly. It is denominated in gas units, not dollars, so it holds as the gas price moves. Observed holding across a 25 to 58 gwei swing inside one session.

Calibration has to happen on a real Arc chain. A local fork put the blind spot at 26,135 gas, which is **84% too high**. Shipping that number would have over-reimbursed the agent on every call forever.

## What was measured on mainnet

A two hour unattended run. 120 calls at one minute intervals, zero throttles.

| | |
|---|---|
| Exact to the gas unit | **102 of 119 warm calls**, 86% |
| Warm drift range | −1 to +36 gas, mean +1.65 |
| Cold call drift | −17,100 gas, once per 24h window |
| Agent net position | **−$0.000324** across 120 calls |
| Payload share / gas share | 55.6% / 44.4% |
| Gas price during the run | 20.0 to 21.7 gwei |

The agent figure is the one to look at. That single cold call costs it $0.000342 on its own,
which is more than the $0.000324 it actually finished down, so the warm calls collectively
came out slightly ahead and absorbed part of it.

Across 120 mainnet transactions the contract priced its own execution to within three
hundredths of a cent, with no oracle and nothing off-chain involved.

The cold call is the first of each window, which pays for a fresh storage slot. Calibrating to the warm case means the agent absorbs that once a day rather than the cap over-paying on the other 277 calls.

The cap was also driven into its limit on mainnet and refused the call with `CapExceeded(needed, available)`. The dashboard lets anyone reproduce that on demand.

## Three things worth knowing if you build on Arc

These cost real debugging time and none of them are documented anywhere obvious.

**1. `eth_call` cannot preflight a gas-sensitive contract.** Static calls run with `tx.gasprice = 0`, so any logic that prices its own execution evaluates the gas leg as zero. A budget check that would reject a real transaction passes in simulation. Pass an explicit gas price.

**2. `eth_estimateGas` underestimates for the same reason.** It returned 78,342 against a true cost of 79,499, so every transaction died out of gas while the library reported success. Set an explicit gas limit.

**3. A reverted transaction still returns a receipt.** Viem does not throw for it, so three out-of-gas failures were logged as successful calls with a fabricated drift of −78,330 before the `receipt.status` check was added.

## Verify any of it yourself

Nothing here needs trusting. Every figure comes off the chain.

```bash
RPC=https://rpc.mainnet.arc.io
CAP=0x3795C17A048F8A6e3f4C52007104C744AB1d7B07
SVC=0x21436b32Cd55d544130e7548c9A7591195F4d33C

cast call $CAP 'budgetPerWindow()(uint256)' --rpc-url $RPC   # the cap, 18dp
cast call $CAP 'remaining()(uint256)'       --rpc-url $RPC   # headroom now
cast call $CAP 'tailGas()(uint256)'         --rpc-url $RPC   # 14187
cast call $SVC 'callsServed()(uint256)'     --rpc-url $RPC   # metered calls so far
```

To watch the metering hold, take any `Spent` event, compare its `gasCost` against the receipt's `gasUsed * effectiveGasPrice`, and the two should agree to within a few gas.

The dashboard does this live and lets you push the contract into refusing a call, through `eth_call`, with no wallet and nothing spent.

## What is deliberately simple, and what is missing

Stated plainly, because these are the first things a careful reader will look for.

**The counterparty is a stub.** `PaidService` charges $0.002 per call and returns a hash. It sells nothing. It exists so the payload leg is non-zero and roughly the size of the gas leg, which is what makes both visible. Because the owner is its beneficiary, that fee is recoverable via `sweep()`, so the fee circulates and only gas is truly spent. A real counterparty would be stronger. The tradeoff was accepted deliberately: the subject under test is the cap, and a trivial counterparty means no result depends on it.

**The agent is deterministic automation, not AI.** No model, no API key. It checks its headroom, buys one call if it fits, and sleeps. In this context "agent" means software holding its own key and acting unattended, which is all the contract needs to be true of it. Nothing here should be described as AI.

**`tailGas` is workload-specific.** 14,187 was calibrated for this call shape. A different target or payload size needs remeasuring, and an Arc upgrade that reprices storage would too.

**Windows tumble, they do not slide.** The counter resets at a boundary rather than rolling. Simpler, cheaper, and it means one cold call per window.

**Not audited.** It is a proof of concept with 60 tests and full line, branch and function coverage, which is not the same thing.

## Where it goes

The useful shape here is a primitive, not an app. A budget that bounds an agent completely, including the cost of acting, is the missing control for agent-held funds, and Arc is the first chain where it can be enforced rather than estimated.

The next steps that matter: ERC-4337 session keys so the cap composes with account abstraction, per-target allowances so an agent can be bounded differently per counterparty, and a budget readable from the agent's ERC-8004 card so anyone can verify an agent's limit before transacting with it. The card already names the enforcing contract.

## Build and test

```bash
git clone --recursive https://github.com/RaymondAbiola/per-diem
cd per-diem
forge test                 # 60 tests
forge coverage             # 100% lines, branches, functions
```

Scripts, each refusing to run against the wrong chain:

```bash
NETWORK=mainnet ./script/preflight.sh       # read-only, costs nothing
NETWORK=mainnet ./script/deploy.sh          # deploy
NETWORK=mainnet ./script/verify-source.sh   # publish source to Blockscout
NETWORK=testnet ./script/calibrate.sh       # measure tailGas on a real chain
NETWORK=mainnet ./script/verify.sh          # prove the float holds
NETWORK=mainnet ./script/prove-cap.sh       # drive the cap into its limit
```

```
src/PerDiem.sol        the cap
src/PaidService.sol    the metered counterparty
agent/agent.mjs        the loop
docs/index.html        the dashboard
deployments/           addresses and constructor arguments per network
```

## License

MIT
