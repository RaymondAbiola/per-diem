// An autonomous agent buying metered calls under an on-chain dollar budget.
//
// The point of this loop is not what it buys. It is that the agent holds a key, spends
// real USDC unattended, and cannot exceed a dollar figure the owner set, because the
// contract counts the agent's own gas against that figure. The agent checks its
// remaining headroom before each call and backs off when a call would not fit, so the
// cap reads as a cooperative signal rather than only a wall.
//
//   NETWORK=mainnet INTERVAL=60 node agent.mjs

import { readFileSync } from "node:fs";
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  fallback,
  defineChain,
  encodeFunctionData,
  formatUnits,
  http,
  keccak256,
  encodePacked,
  BaseError,
  ContractFunctionRevertedError,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");

const NETWORK = process.env.NETWORK ?? "mainnet";
const INTERVAL_S = Number(process.env.INTERVAL ?? 60);
const MAX_CALLS = Number(process.env.MAX_CALLS ?? Infinity);

// Ordered by measured latency, fastest first. The canonical arc.io host is last on
// purpose: it went down mid-run once and, being the only endpoint, took the agent with
// it. An unattended loop cannot depend on one provider staying up.
const NETWORKS = {
  mainnet: {
    id: 5042,
    explorer: "https://explorer.arc.io",
    rpcs: [
      "https://arc.gateway.tenderly.co",
      "https://arc.drpc.org",
      "https://arc.rpc.thirdweb.com",
      "https://arc-rpc.publicnode.com",
      "https://rpc.mainnet.arc.io",
    ],
  },
  testnet: {
    id: 5042002,
    explorer: "https://explorer.testnet.arc.io",
    rpcs: ["https://rpc.testnet.arc.io"],
  },
};

// Arc's native view of USDC is 18 decimals. The ERC-20 interface onto the same balance
// uses 6. Everything here is in the native view, which is what msg.value and
// tx.gasprice speak.
function arcChain(cfg) {
  return defineChain({
    id: cfg.id,
    name: `Arc ${NETWORK}`,
    nativeCurrency: { name: "USD Coin", symbol: "USDC", decimals: 18 },
    rpcUrls: { default: { http: cfg.rpcs } },
    blockExplorers: { default: { name: "Blockscout", url: cfg.explorer } },
  });
}

const PER_DIEM_ABI = [
  {
    type: "function",
    name: "execute",
    stateMutability: "nonpayable",
    inputs: [
      { name: "target", type: "address" },
      { name: "value", type: "uint256" },
      { name: "data", type: "bytes" },
    ],
    outputs: [{ name: "ret", type: "bytes" }],
  },
  { type: "function", name: "remaining", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "currentWindow", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "windowLength", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "budgetPerWindow", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "agent", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "tailGas", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "error",
    name: "CapExceeded",
    inputs: [
      { name: "needed", type: "uint256" },
      { name: "available", type: "uint256" },
    ],
  },
  { type: "error", name: "GasPriceTooHigh", inputs: [{ name: "offered", type: "uint256" }, { name: "max", type: "uint256" }] },
  {
    type: "event",
    name: "Spent",
    inputs: [
      { name: "target", type: "address", indexed: true },
      { name: "value", type: "uint256" },
      { name: "gasCost", type: "uint256" },
      { name: "windowSpent", type: "uint256" },
      { name: "windowRemaining", type: "uint256" },
    ],
  },
];

const SERVICE_ABI = [
  {
    type: "function",
    name: "query",
    stateMutability: "payable",
    inputs: [{ name: "input", type: "bytes32" }],
    outputs: [{ type: "bytes32" }],
  },
  { type: "function", name: "pricePerCall", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "callsServed", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];

// Measured on Arc: a warm metered call costs 79,499 gas.
const GAS_PER_CALL = 79_499n;

// Covers the cold first call of a window, which pays an extra ~17,100 for the fresh
// spentInWindow slot.
const GAS_HEADROOM = 25_000n;

// We must set the gas limit ourselves. eth_estimateGas runs with tx.gasprice = 0, which
// makes the reimbursement leg cheaper than it really is, so the estimate comes back at
// 78,342 against a true cost of 79,499 and the transaction dies out of gas. Measured on
// Arc testnet: a 0-price estimate is 1,157 short, while estimating with the real gas
// price returns a safe 84,330. Passing an explicit limit sidesteps the whole problem,
// and unused gas is refunded so a generous limit is free.
const GAS_LIMIT = GAS_PER_CALL + GAS_HEADROOM + 20_000n;

// keccak256("Spent(address,uint256,uint256,uint256,uint256)")
const SPENT_TOPIC = "0xe8591e9373e8c4801ffc5bb031277889e3e771aee8c55961028bfc65728c9ba9";

const usd = (v) => `$${Number(formatUnits(v, 18)).toFixed(6)}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Reads .env without echoing it. Values go straight into the client.
function loadEnv() {
  try {
    const raw = readFileSync(join(ROOT, ".env"), "utf8");
    for (const line of raw.split("\n")) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
      if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
      
    }
  } catch {
    /* env file is optional if the vars are already exported */
  }
}

// Never logs, prints, or describes the key. Errors name the variable only.
function normalizeKey(raw) {
  if (!raw || raw.includes("REPLACE_ME")) {
    throw new Error("AGENT_KEY is missing or still a placeholder in .env");
  }
  let k = raw.trim().replace(/\r/g, "").replace(/^["']|["']$/g, "");
  if (!k.startsWith("0x")) k = `0x${k}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(k)) {
    throw new Error("AGENT_KEY is not a 32-byte hex private key");
  }
  return k;
}

let logPath;
function log(event, fields = {}) {
  const row = { t: new Date().toISOString(), event, ...fields };
  if (logPath) appendFileSync(logPath, `${JSON.stringify(row)}\n`);
  return row;
}

function say(msg) {
  process.stdout.write(`${msg}\n`);
}

async function main() {
  loadEnv();

  const cfg = NETWORKS[NETWORK];
  if (!cfg) throw new Error(`unknown NETWORK "${NETWORK}"`);

  // cast accepts a key with or without the 0x prefix, and tolerates stray quotes or a
  // CRLF line ending. viem does not. Normalise without inspecting or reporting the value.
  const key = normalizeKey(process.env.AGENT_KEY);

  const deployments = JSON.parse(
    readFileSync(join(ROOT, "deployments", `arc-${NETWORK}.json`), "utf8"),
  );
  const cap = deployments.contracts.PerDiem.address;
  const service = deployments.contracts.PaidService.address;

  const chain = arcChain(cfg);
  const transport = fallback(
    cfg.rpcs.map((u) => http(u, { retryCount: 2, retryDelay: 400, timeout: 15_000 })),
  );
  const pub = createPublicClient({ chain, transport });
  const account = privateKeyToAccount(key);
  const wallet = createWalletClient({ account, chain, transport });

  mkdirSync(join(HERE, "log"), { recursive: true });
  logPath = join(HERE, "log", `${NETWORK}.jsonl`);

  // --- preflight ---
  const chainId = await pub.getChainId();
  if (chainId !== cfg.id) throw new Error(`RPC reports chain ${chainId}, expected ${cfg.id}`);

  const read = (name, args = []) =>
    pub.readContract({ address: cap, abi: PER_DIEM_ABI, functionName: name, args });

  const [onChainAgent, windowLength, budget, tailGas, fee] = await Promise.all([
    read("agent"),
    read("windowLength"),
    read("budgetPerWindow"),
    read("tailGas"),
    pub.readContract({ address: service, abi: SERVICE_ABI, functionName: "pricePerCall" }),
  ]);

  if (onChainAgent.toLowerCase() !== account.address.toLowerCase()) {
    throw new Error(
      `this key is ${account.address} but the cap's agent is ${onChainAgent}. It cannot spend.`,
    );
  }

  say(`\nper-diem agent on Arc ${NETWORK} (chain ${chainId})`);
  say(`  cap        ${cap}`);
  say(`  service    ${service}`);
  say(`  agent      ${account.address}`);
  say(`  budget     ${usd(budget)} per ${Number(windowLength) / 3600}h window`);
  say(`  tailGas    ${tailGas}`);
  say(`  fee        ${usd(fee)} per call`);
  say(`  interval   ${INTERVAL_S}s`);
  say(`  log        ${logPath}\n`);

  log("start", {
    network: NETWORK,
    cap,
    service,
    agent: account.address,
    budget: budget.toString(),
    windowLength: Number(windowLength),
    intervalSeconds: INTERVAL_S,
  });

  let running = true;
  let calls = 0;
  let spentTotal = 0n;
  let throttles = 0;
  const stop = (sig) => {
    running = false;
    say(`\n${sig}, stopping after ${calls} calls, ${usd(spentTotal)} spent`);
    log("stop", { signal: sig, calls, spentTotal: spentTotal.toString(), throttles });
  };
  process.on("SIGINT", () => stop("SIGINT"));
  process.on("SIGTERM", () => stop("SIGTERM"));

  while (running && calls < MAX_CALLS) {
    const [remaining, gasPrice, capBalance, window] = await Promise.all([
      read("remaining"),
      pub.getGasPrice(),
      pub.getBalance({ address: cap }),
      read("currentWindow"),
    ]);

    const estGas = (GAS_PER_CALL + GAS_HEADROOM) * gasPrice;
    const estCost = fee + estGas;

    // The cap paying out requires the cap to hold funds. Running dry is an owner
    // problem, not a budget problem, and the two must not look alike.
    if (capBalance < estCost) {
      say(`cap balance ${usd(capBalance)} cannot cover a ${usd(estCost)} call. owner must fund it.`);
      log("cap_underfunded", { capBalance: capBalance.toString(), estCost: estCost.toString() });
      break;
    }

    // Back off rather than send something the cap will reject.
    if (remaining < estCost) {
      throttles += 1;
      const nextBoundary = (BigInt(window) + 1n) * BigInt(windowLength);
      const waitMs = Number(nextBoundary * 1000n - BigInt(Date.now()));
      const waitS = Math.max(5, Math.ceil(waitMs / 1000));
      say(
        `budget spent: ${usd(remaining)} left, a call needs ${usd(estCost)}. ` +
          `holding ${Math.round(waitS / 60)}m until window ${window + 1n}.`,
      );
      log("throttled", {
        window: window.toString(),
        remaining: remaining.toString(),
        needed: estCost.toString(),
        resumeInSeconds: waitS,
      });
      await sleep(Math.min(waitS, 300) * 1000); // re-check at least every 5 minutes
      continue;
    }

    const input = keccak256(encodePacked(["uint256", "uint256"], [BigInt(Date.now()), BigInt(calls)]));
    const data = encodeFunctionData({ abi: SERVICE_ABI, functionName: "query", args: [input] });

    try {
      const hash = await wallet.writeContract({
        address: cap,
        abi: PER_DIEM_ABI,
        functionName: "execute",
        args: [service, fee, data],
        gas: GAS_LIMIT,
      });
      const receipt = await pub.waitForTransactionReceipt({ hash });

      // A reverted transaction still produces a receipt. viem does not throw for it, so
      // without this check a failed call is recorded as a successful one.
      if (receipt.status !== "success") {
        say(`#${calls + 1} REVERTED ${hash} gas ${receipt.gasUsed}/${GAS_LIMIT}`);
        log("reverted", {
          tx: hash,
          gasUsed: Number(receipt.gasUsed),
          gasLimit: Number(GAS_LIMIT),
          outOfGas: receipt.gasUsed === GAS_LIMIT,
        });
        await sleep(10_000);
        continue;
      }

      // Read what the contract itself decided this cost, rather than trusting our guess.
      const spentLog = receipt.logs.find(
        (l) => l.address.toLowerCase() === cap.toLowerCase() && l.topics[0] === SPENT_TOPIC,
      );
      if (!spentLog) throw new Error(`no Spent event in ${hash}, cannot trust this call`);
      const d = spentLog.data.slice(2);
      const gasCost = BigInt(`0x${d.slice(64, 128)}`);
      const windowRemaining = BigInt(`0x${d.slice(192, 256)}`);

      calls += 1;
      spentTotal += fee + gasCost;
      const drift = Number(gasCost / gasPrice) - Number(receipt.gasUsed);

      say(
        `#${String(calls).padStart(4)} ${hash.slice(0, 10)} ` +
          `gas ${receipt.gasUsed} billed ${gasCost / gasPrice} drift ${drift >= 0 ? "+" : ""}${drift} ` +
          `| left ${usd(windowRemaining)}`,
      );
      log("call", {
        n: calls,
        tx: hash,
        block: Number(receipt.blockNumber),
        gasUsed: Number(receipt.gasUsed),
        gasPrice: gasPrice.toString(),
        fee: fee.toString(),
        gasCost: gasCost.toString(),
        driftGas: drift,
        windowRemaining: windowRemaining.toString(),
      });
    } catch (err) {
      const revert = err instanceof BaseError ? err.walk((e) => e instanceof ContractFunctionRevertedError) : null;
      if (revert?.data?.errorName === "CapExceeded") {
        const [needed, available] = revert.data.args;
        say(`rejected: needed ${usd(needed)}, ${usd(available)} available. the cap held.`);
        log("cap_exceeded", { needed: needed.toString(), available: available.toString() });
        continue; // the headroom check above will now throttle properly
      }
      const name = revert?.data?.errorName ?? err.shortMessage ?? err.message;
      say(`error: ${name}`);
      log("error", { error: String(name) });
      await sleep(10_000);
      continue;
    }

    if (running && calls < MAX_CALLS) await sleep(INTERVAL_S * 1000);
  }

  const served = await pub.readContract({ address: service, abi: SERVICE_ABI, functionName: "callsServed" });
  say(`\ndone. ${calls} calls this run, ${usd(spentTotal)} spent, ${throttles} throttles.`);
  say(`service has served ${served} calls in total.`);
  log("end", { calls, spentTotal: spentTotal.toString(), throttles, servedTotal: Number(served) });
}

main().catch((e) => {
  say(`fatal: ${e.message}`);
  log("fatal", { error: e.message });
  process.exit(1);
});
