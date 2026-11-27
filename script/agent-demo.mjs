// End-to-end demo on Base Sepolia:
//   1. the agent sets its rule: invest 20% of each earning, 60% tNVDAc / 40% tAAPLc, 1% max slippage;
//   2. a client pays the agent for three jobs through the treasury (depositEarning);
//      the treasury batches the stock share and buys at the mirrored mainnet NAV;
//   3. the issuer applies a 2% reinvested dividend to tNVDAc (uiMultiplier × 1.02):
//      the agent's raw balance stays the same, its share-equivalent count goes up;
//   4. the agent withdraws part of its USDC cash.
// Every tx hash and the holdings before/after are written to runs/.
//
//   AGENT_KEY_FILE=... CLIENT_KEY_FILE=... ISSUER_KEY_FILE=... node script/agent-demo.mjs
import fs from 'node:fs';
import { createPublicClient, createWalletClient, http, parseAbi, formatUnits, toHex, keccak256 } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { baseSepolia } from 'viem/chains';
import { Attribution } from 'ox/erc8021';

for (const k of ['AGENT_KEY_FILE', 'CLIENT_KEY_FILE', 'ISSUER_KEY_FILE']) {
  if (!process.env[k]) {
    console.error('usage: AGENT_KEY_FILE=... CLIENT_KEY_FILE=... ISSUER_KEY_FILE=... node script/agent-demo.mjs');
    process.exit(2);
  }
}
const acct = (env) => {
  let d = JSON.parse(fs.readFileSync(process.env[env], 'utf8'));
  if (Array.isArray(d)) d = d[0];
  return privateKeyToAccount(d.private_key || d.privateKey);
};
const agent = acct('AGENT_KEY_FILE');
const client = acct('CLIENT_KEY_FILE');
const issuer = acct('ISSUER_KEY_FILE');
const dep = JSON.parse(fs.readFileSync(new URL('../deployments.json', import.meta.url), 'utf8'));
const transport = http(process.env.RPC_URL);
const pub = createPublicClient({ chain: baseSepolia, transport });
const tAbi = JSON.parse(fs.readFileSync(new URL('../out/AgentStockTreasury.sol/AgentStockTreasury.json', import.meta.url), 'utf8')).abi;
const erc20 = parseAbi(['function approve(address,uint256) returns (bool)', 'function allowance(address,address) view returns (uint256)', 'function balanceOf(address) view returns (uint256)']);
const b20 = parseAbi(['function updateUIMultiplier(uint256 newMultiplier, uint256 effectiveAt)', 'function uiMultiplier() view returns (uint256)', 'function symbol() view returns (string)']);
const NVDA = dep.stocks.NVDA.token;
const AAPL = dep.stocks.AAPL.token;
const log = [];

// Base Builder Code (ERC-8021): every transaction this demo sends carries BotHire's attribution
// suffix after the calldata. Contracts ignore the trailing bytes; Base indexers read them.
const BUILDER_CODE = process.env.BUILDER_CODE ?? 'bc_q4i53poy';
if (BUILDER_CODE && !/^[A-Za-z0-9_]{1,32}$/.test(BUILDER_CODE)) {
  console.error(`BUILDER_CODE must be one code of letters, digits and _ (got ${JSON.stringify(BUILDER_CODE)})`);
  process.exit(2);
}
const dataSuffix = BUILDER_CODE ? Attribution.toDataSuffix({ codes: [BUILDER_CODE] }) : undefined;

async function tx(who, label, req) {
  const wal = createWalletClient({ chain: baseSepolia, transport, account: who, dataSuffix });
  const { request } = await pub.simulateContract({ ...req, account: who, dataSuffix });
  const hash = await wal.writeContract(request);
  const rc = await pub.waitForTransactionReceipt({ hash });
  if (rc.status !== 'success') throw new Error(`${label} reverted ${hash}`);
  if (dataSuffix) {
    const sent = await pub.getTransaction({ hash });
    if (!sent.input.toLowerCase().endsWith(dataSuffix.slice(2).toLowerCase())) throw new Error(`${label}: builder code suffix missing ${hash}`);
  }
  console.log(`  ${label.padEnd(34)} ${hash}`);
  log.push({ step: label, tx: hash, block: Number(rc.blockNumber) });
  return rc;
}

async function holdings(tag) {
  const h = await pub.readContract({ address: dep.treasury, abi: tAbi, functionName: 'holdingsOf', args: [agent.address] });
  const [cash, pending] = await Promise.all([
    pub.readContract({ address: dep.treasury, abi: tAbi, functionName: 'cashUsdc', args: [agent.address] }),
    pub.readContract({ address: dep.treasury, abi: tAbi, functionName: 'pendingUsdc', args: [agent.address] }),
  ]);
  const view = {
    tag,
    cashUsdc: formatUnits(cash, 6),
    pendingUsdc: formatUnits(pending, 6),
    stocks: await Promise.all(h.map(async (x) => ({
      symbol: await pub.readContract({ address: x.token, abi: b20, functionName: 'symbol' }),
      raw: x.raw.toString(),
      shareEquivalents: formatUnits(x.shares, 8),
      usd: formatUnits(x.usdValue, 6),
    }))),
  };
  console.log(`  [${tag}] cash ${view.cashUsdc} USDC, pending ${view.pendingUsdc} USDC, ` + view.stocks.map((s) => `${s.symbol} ${s.shareEquivalents} share-eq ≈ $${s.usd}`).join(', '));
  log.push({ holdings: view });
  return view;
}

console.log(`agent ${agent.address}, client ${client.address}, treasury ${dep.treasury}`);
// 1. rule
await tx(agent, 'agent sets rule (20%, 60/40, 1%)', {
  address: dep.treasury, abi: tAbi, functionName: 'setRule',
  args: [2_000, 100, 200_000n, [{ token: NVDA, weightBps: 6_000 }, { token: AAPL, weightBps: 4_000 }]],
});
// 2. three paid jobs
const allowance = await pub.readContract({ address: dep.usdc, abi: erc20, functionName: 'allowance', args: [client.address, dep.treasury] });
if (allowance < 3_000_000n) await tx(client, 'client approves USDC', { address: dep.usdc, abi: erc20, functionName: 'approve', args: [dep.treasury, 10_000_000n] });
for (const [i, amount] of [[1, 500_000n], [2, 500_000n], [3, 1_000_000n]]) {
  await tx(client, `job ${i}: pays agent ${formatUnits(amount, 6)} USDC`, {
    address: dep.treasury, abi: tAbi, functionName: 'depositEarning', args: [agent.address, amount, keccak256(toHex(`bothire-demo-job-${i}`))],
  });
  await holdings(`after job ${i}`);
}
// 3. a reinvested dividend on tNVDAc
const before = await holdings('before dividend');
const now = Number((await pub.getBlock()).timestamp);
const m0 = await pub.readContract({ address: NVDA, abi: b20, functionName: 'uiMultiplier' });
await tx(issuer, 'issuer: tNVDAc 2% dividend', { address: NVDA, abi: b20, functionName: 'updateUIMultiplier', args: [m0 * 102n / 100n, BigInt(now + 20)] });
await new Promise((r) => setTimeout(r, 30_000));
const after = await holdings('after dividend');
console.log(`  tNVDAc share-equivalents ${before.stocks[0].shareEquivalents} → ${after.stocks[0].shareEquivalents} (raw unchanged: ${before.stocks[0].raw === after.stocks[0].raw})`);
// 4. the agent withdraws some of its cash (only it can)
await tx(agent, 'agent withdraws 0.5 USDC cash', { address: dep.treasury, abi: tAbi, functionName: 'withdraw', args: [dep.usdc, 500_000n, agent.address] });
await holdings('after withdrawal');

fs.mkdirSync(new URL('../runs/', import.meta.url), { recursive: true });
const out = new URL(`../runs/demo-${Date.now()}.json`, import.meta.url);
fs.writeFileSync(out, JSON.stringify({ treasury: dep.treasury, agent: agent.address, client: client.address, builderCode: BUILDER_CODE || null, dataSuffix: dataSuffix ?? null, log }, null, 2) + '\n');
console.log(`wrote runs/${out.pathname.split('/').pop()}`);
