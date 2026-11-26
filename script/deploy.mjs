// Deploys the Agent Stock Treasury demo on Base Sepolia, where real tokenized stocks don't exist:
//   1. creates B20 test stocks (tNVDAc, tAAPLc, tTSLAc) through Base's B20 factory precompile, the same
//      token standard as the real Coinbase stocks on mainnet (8 decimals, uiMultiplier, policies);
//   2. deploys a NAV feed per stock and copies the live NAV from the real mainnet Chainlink feed;
//   3. deploys the NAV swap venue and the treasury, lists the stocks, stocks the venue's inventory.
// Foundry scripts can't do step 1 (the precompile only exists on the live network), so this uses viem.
// Idempotent: existing tokens and deployments.json entries are reused.
//
//   KEY_FILE=deployer-wallet.json node script/deploy.mjs
import fs from 'node:fs';
import {
  createPublicClient, createWalletClient, http, parseAbi, encodeAbiParameters, encodeFunctionData, keccak256, toHex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base, baseSepolia } from 'viem/chains';

if (!process.env.KEY_FILE) {
  console.error('usage: KEY_FILE=deployer-wallet.json node script/deploy.mjs');
  process.exit(2);
}
let kd = JSON.parse(fs.readFileSync(process.env.KEY_FILE, 'utf8'));
if (Array.isArray(kd)) kd = kd[0];
const me = privateKeyToAccount(kd.private_key || kd.privateKey);
const pub = createPublicClient({ chain: baseSepolia, transport: http(process.env.RPC_URL) });
const wal = createWalletClient({ chain: baseSepolia, transport: http(process.env.RPC_URL), account: me });
const mainnet = createPublicClient({ chain: base, transport: http(process.env.MAINNET_RPC_URL) });

const FACTORY = '0xB20f000000000000000000000000000000000000';
const USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'; // Circle test USDC on Base Sepolia
const STOCKS = [
  { sym: 'NVDA', mainnetToken: '0xb20000000000000000000078ee7ce2fE4908108C', mainnetFeed: '0x04689a41629776563E6822F76f2e57D148d28513', name: 'NVIDIA' },
  { sym: 'AAPL', mainnetToken: '0xb200000000000000000000C2e324d24d7eEcd1fb', mainnetFeed: '0x787f13dEa48Db0897CbCDD985de77809D837F988', name: 'Apple' },
  { sym: 'TSLA', mainnetToken: '0xb2000000000000000000001e800a7f5189430cD0', mainnetFeed: '0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4', name: 'Tesla' },
];
const INVENTORY = 1_000n * 10n ** 8n;

const factoryAbi = parseAbi([
  'function createB20(uint8 variant, bytes32 salt, bytes params, bytes[] initCalls) returns (address)',
  'function getB20Address(uint8 variant, address sender, bytes32 salt) view returns (address)',
  'function isB20Initialized(address token) view returns (bool)',
]);
const b20Abi = parseAbi([
  'function grantRole(bytes32 role, address account)',
  'function mint(address to, uint256 amount)',
  'function balanceOf(address) view returns (uint256)',
  'function symbol() view returns (string)',
  'function uiMultiplier() view returns (uint256)',
]);
const feedAbi = parseAbi(['function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)', 'function mirror(int256 answer, uint256 updatedAt)']);
const art = (name) => JSON.parse(fs.readFileSync(new URL(`../out/${name}.sol/${name}.json`, import.meta.url), 'utf8'));

const file = new URL('../deployments.json', import.meta.url);
const dep = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { chainId: 84532, deployer: me.address, stocks: {}, txs: {} };
const save = () => fs.writeFileSync(file, JSON.stringify(dep, null, 2) + '\n');

async function send(label, req) {
  const hash = await wal.sendTransaction(req);
  const rc = await pub.waitForTransactionReceipt({ hash });
  if (rc.status !== 'success') throw new Error(`${label} reverted ${hash}`);
  dep.txs[label] = hash;
  save();
  console.log(`  ${label.padEnd(22)} ${hash}`);
  return rc;
}
async function deploy(label, name, args = []) {
  if (dep[label]) return dep[label];
  const a = art(name);
  const hash = await wal.deployContract({ abi: a.abi, bytecode: a.bytecode.object, args });
  const rc = await pub.waitForTransactionReceipt({ hash });
  if (rc.status !== 'success') throw new Error(`${label} deploy reverted`);
  dep[label] = rc.contractAddress;
  dep.txs[label] = hash;
  save();
  console.log(`  ${label.padEnd(22)} ${rc.contractAddress}`);
  return rc.contractAddress;
}
const ROLE = (r) => keccak256(toHex(r));

console.log(`deployer ${me.address} on Base Sepolia`);
// 1. B20 test stocks
for (const s of STOCKS) {
  const salt = keccak256(toHex(`bothire-stock-treasury/t${s.sym}c`));
  const addr = await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: 'getB20Address', args: [0, me.address, salt] });
  if (!(await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: 'isB20Initialized', args: [addr] }))) {
    const params = encodeAbiParameters(
      [{ type: 'tuple', components: [{ type: 'uint8' }, { type: 'string' }, { type: 'string' }, { type: 'address' }, { type: 'uint8' }] }],
      [[1, `${s.name} (test token, not a security)`, `t${s.sym}c`, me.address, 8]],
    );
    const grants = ['MINT_ROLE', 'OPERATOR_ROLE', 'PAUSE_ROLE', 'UNPAUSE_ROLE'].map((r) =>
      encodeFunctionData({ abi: b20Abi, functionName: 'grantRole', args: [ROLE(r), me.address] }));
    await send(`create t${s.sym}c`, { to: FACTORY, data: encodeFunctionData({ abi: factoryAbi, functionName: 'createB20', args: [0, salt, params, grants] }) });
  }
  dep.stocks[s.sym] = { ...(dep.stocks[s.sym] || {}), token: addr, symbol: `t${s.sym}c`, mainnetToken: s.mainnetToken, mainnetFeed: s.mainnetFeed };
  save();
}
// 2. NAV feeds mirroring mainnet
for (const s of STOCKS) {
  const feed = await deploy(`feed ${s.sym}`, 'MirroredNavFeed', [`Coinbase ${s.sym} (mirror of Base mainnet)`, s.mainnetFeed]);
  dep.stocks[s.sym].feed = feed;
  const [, answer, , updatedAt] = await mainnet.readContract({ address: s.mainnetFeed, abi: feedAbi, functionName: 'latestRoundData' });
  await send(`mirror ${s.sym}`, { to: feed, data: encodeFunctionData({ abi: feedAbi, functionName: 'mirror', args: [answer, updatedAt] }) });
  dep.stocks[s.sym].mirroredNav = { answer: answer.toString(), updatedAt: Number(updatedAt) };
  save();
}
// 3. venue + treasury
const venue = await deploy('venue', 'NavSwapVenue', [30]);
const treasury = await deploy('treasury', 'AgentStockTreasury', [USDC, venue]);
const vAbi = art('NavSwapVenue').abi;
const tAbi = art('AgentStockTreasury').abi;
for (const s of STOCKS) {
  const { token, feed } = dep.stocks[s.sym];
  if ((await pub.readContract({ address: venue, abi: vAbi, functionName: 'feedOf', args: [token] })).toLowerCase() !== feed.toLowerCase()) {
    await send(`venue.list ${s.sym}`, { to: venue, data: encodeFunctionData({ abi: vAbi, functionName: 'list', args: [token, feed] }) });
  }
  if ((await pub.readContract({ address: treasury, abi: tAbi, functionName: 'navFeedOf', args: [token] })).toLowerCase() !== feed.toLowerCase()) {
    await send(`treasury.list ${s.sym}`, { to: treasury, data: encodeFunctionData({ abi: tAbi, functionName: 'listStock', args: [token, feed] }) });
  }
  if ((await pub.readContract({ address: token, abi: b20Abi, functionName: 'balanceOf', args: [venue] })) < INVENTORY / 2n) {
    await send(`inventory ${s.sym}`, { to: token, data: encodeFunctionData({ abi: b20Abi, functionName: 'mint', args: [venue, INVENTORY] }) });
  }
}
dep.usdc = USDC;
save();
console.log('wrote deployments.json');
