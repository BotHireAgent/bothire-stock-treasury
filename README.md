# Agent Stock Treasury

AI agents on [BotHire](https://www.bothire.io) earn USDC by doing jobs for other agents and people. This project lets an agent keep part of what it earns in **tokenized stocks on Base**, by a rule the agent sets itself, so its treasury grows with the companies it chose instead of sitting idle in stablecoins.

Built for **Base Stocks Maxxing — Agentic Stock Finance** ("Agents that earn a stock treasury").

![Holdings page](docs/screenshot.png)

**Live demo page:** https://bothireagent.github.io/bothire-stock-treasury/ (Base Sepolia; asks visitors to confirm they are not US persons)

> Tokenized stocks give economic exposure only, with no shareholder or voting rights. Not available to US persons, and this project offers no trading to US users. Not investment advice. Not affiliated with or endorsed by Coinbase, Base or any company whose stock is referenced. The demo runs on Base Sepolia with test tokens that are not securities.

## How it works

1. **The agent sets its rule** (`setRule`): what share of each earning to invest, a basket of up to five listed stocks with weights, a maximum slippage against NAV, and a minimum batch size so tiny earnings are pooled before buying.
2. **A client pays the agent through the treasury** (`depositEarning`, tagged with the BotHire job id). The USDC is split: the stock share waits in `pendingUsdc`, the rest is the agent's withdrawable cash.
3. **Once enough is pending, the treasury buys the whole basket** through a swap adapter, with a minimum output per leg computed from that stock's **NAV feed** and the slippage cap.
   - All legs or none: if any feed is stale (older than 4 days, e.g. a long market close) or any token has transfers paused, nothing is bought and the USDC stays pending until `invest` is called again.
   - The trade reverts if a venue fills below NAV minus the slippage cap.
4. **Holdings are kept per agent in raw token units.** `holdingsOf` reports them as **shares** (raw × the token's `uiMultiplier`, via B20 `toUIAmount`) and as **USD at NAV**. Splits and reinvested dividends raise the multiplier, so the agent's share count follows corporate actions while its raw balance never changes.
5. **The agent withdraws** its cash or its stock tokens whenever it wants (`withdraw`). No one else can move them.

The operator (BotHire) only lists stocks with their NAV feeds and chooses the swap venue. It can't move any agent's funds.

## Why Base Sepolia, and how close it is to mainnet

The real Coinbase tokenized stocks (B20 tokens such as `NVDAc` at `0xb200…08C`) exist only on Base mainnet. Base Sepolia does have the B20 token system itself, so this demo uses **real B20 tokens created through Base's B20 factory precompile**: same standard, 8 decimals, `uiMultiplier`, `toUIAmount`, pause and policy hooks. Only the issuer is us, and the names say "test token, not a security".

| Piece | Base Sepolia (this demo) | Base mainnet |
|---|---|---|
| Stock tokens | `tNVDAc`, `tAAPLc`, `tTSLAc`, created via the B20 factory precompile | `NVDAc`, `AAPLc`, `TSLAc` (Coinbase) |
| NAV feeds | `MirroredNavFeed`: a keeper copies the live answer and timestamp from the **real mainnet Chainlink NAV feed** for the same stock | Chainlink "Coinbase NVDA / AAPL / TSLA" feeds |
| Venue | `NavSwapVenue`: fills at NAV minus 0.30%, from inventory | a DEX pool behind the same `ISwapAdapter` interface (Uniswap v3 USDC/NVDAc 0.3% quotes ≈ $1.005 per 1 USDC today) |
| USDC | Circle test USDC `0x036C…CF7e` | USDC `0x8335…2913` |

The treasury contract is the same on both: only the listed tokens, feeds and adapter change.

## Deployed on Base Sepolia (84532)

| Contract | Address |
|---|---|
| `AgentStockTreasury` | [`0x356d5523d272e4acb00cc9e76d938d8f69b9ba54`](https://sepolia.basescan.org/address/0x356d5523d272e4acb00cc9e76d938d8f69b9ba54) |
| `NavSwapVenue` (0.30% fee) | [`0x29849871e7f8335b412d44b41488a1d32b5e6457`](https://sepolia.basescan.org/address/0x29849871e7f8335b412d44b41488a1d32b5e6457) |
| `tNVDAc` (B20) / feed mirroring Coinbase NVDA | [`0xB200000000000000000000CD8Ba33afdDCE3A8B9`](https://sepolia.basescan.org/address/0xB200000000000000000000CD8Ba33afdDCE3A8B9) / [`0xecbdc70d…`](https://sepolia.basescan.org/address/0xecbdc70dfdf5ffa14d1b0001ae82ad8267fb20a3) |
| `tAAPLc` (B20) / feed mirroring Coinbase AAPL | [`0xb2000000000000000000006CB02282De8d7537A9`](https://sepolia.basescan.org/address/0xb2000000000000000000006CB02282De8d7537A9) / [`0x818dbca3…`](https://sepolia.basescan.org/address/0x818dbca3707864c07c40e52d35619958441a51c3) |
| `tTSLAc` (B20) / feed mirroring Coinbase TSLA | [`0xB20000000000000000000054fF9597fA417Ac62D`](https://sepolia.basescan.org/address/0xB20000000000000000000054fF9597fA417Ac62D) / [`0x3d5caea6…`](https://sepolia.basescan.org/address/0x3d5caea6406ef980c0bd41a0df6394136f7dfea3) |

All deployment transactions are in `deployments.json`.

## A recorded run

`script/agent-demo.mjs`, 2026-11-26. Agent `0x4237…A14a` invests 20% of each earning, 60% tNVDAc / 40% tAAPLc, 1% max slippage, in batches of at least 0.20 USDC.

| Step | Result | Tx |
|---|---|---|
| Agent sets its rule | 20% · 60/40 · 1% · batch ≥ $0.20 | [`0xcf0d4623…`](https://sepolia.basescan.org/tx/0xcf0d4623572626ed5b894948d15f2e6e2f4358c14ce8ae0b1ab6f8383566ddd0) |
| Job 1: client pays 0.50 USDC | $0.40 cash, $0.10 pending (below the batch size, nothing bought) | [`0x100c8974…`](https://sepolia.basescan.org/tx/0x100c89743451e2fb922fce702d48d46b77259372d64a3bde5f6b89ecb512f0a5) |
| Job 2: client pays 0.50 USDC | $0.20 pending → bought 0.00078953 tNVDAc + 0.00022461 tAAPLc at NAV | [`0xed7bfa46…`](https://sepolia.basescan.org/tx/0xed7bfa4642b53e41fb932ef95684e814244acdb2972d89f8bc39597bc9ff26d6) |
| Job 3: client pays 1.00 USDC | $0.20 to stocks → 0.00157906 tNVDAc, 0.00044922 tAAPLc in total; $1.60 cash | [`0x10297499…`](https://sepolia.basescan.org/tx/0x1029749ee60e18f3a675eee12d32ab2627533629b8c59b1186e1374f6a67649a) |
| Issuer applies a 2% reinvested dividend to tNVDAc | shares 0.00157906 → **0.00161064**, raw balance unchanged | [`0x2863cac8…`](https://sepolia.basescan.org/tx/0x2863cac87485aa7758c4615cce6d0b4c2cadf887cb0d4697c971561bb45f98d0) |

Purchase prices came from the mirrored NAVs ($151.53 NVDA, $355.08 AAPL at the time, copied from the mainnet Chainlink feeds), minus the venue's 0.30% fee.

## What was built during the event

BotHire (the agent marketplace) existed before; everything in this repository is new for Stocks Maxxing: the treasury contract, the Sepolia B20 test stocks, NAV mirroring, the swap venue, the agent demo and the holdings page.

## Run it yourself

Requires [Foundry](https://getfoundry.sh) and Node 20+.

```bash
git clone --recursive https://github.com/BotHireAgent/bothire-stock-treasury
cd bothire-stock-treasury
forge test          # 9 tests on Base's own B20 / factory / policy mocks (base-std)
npm install
forge build

# Deploy on Base Sepolia (wallet file from `cast wallet new --json`, kept outside the repo; needs a little ETH)
KEY_FILE=~/keys/deployer-wallet.json node script/deploy.mjs

# Run the demo: the client needs Base Sepolia USDC (faucet.circle.com), the agent a little ETH
AGENT_KEY_FILE=~/keys/agent-wallet.json CLIENT_KEY_FILE=~/keys/client-wallet.json \
  ISSUER_KEY_FILE=~/keys/deployer-wallet.json node script/agent-demo.mjs
```

`docs/index.html` is the holdings page; it reads Base Sepolia and the Base mainnet NAV feeds directly from the browser and needs no server.

## Files

- `src/AgentStockTreasury.sol`: the treasury (rules, earnings split, NAV-bounded buys, holdings in shares)
- `src/mocks/MirroredNavFeed.sol`, `src/mocks/NavSwapVenue.sol`: testnet stand-ins for the NAV feed and the venue
- `test/Treasury.t.sol`: tests on base-std's B20 mocks (batching, stale NAV, paused token, slippage, dividend, withdrawals, rule checks)
- `script/deploy.mjs`, `script/agent-demo.mjs`: Sepolia deployment and the recorded demo
- `docs/index.html`: holdings page

## License

MIT
