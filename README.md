# Glacier

**Stock Cubes on Base.** One stock is a position. A Cube is a strategy.

Glacier lets anyone bundle up to five tokenized stocks into a single onchain position called a **Cube**. Creators set the weights and fees. Investors join with USDC and exit to USDC (or to the underlying stocks) at any time. Everything settles on Base.

## Live on Base mainnet

All contracts are verified on BaseScan.

| Contract | Address |
|---|---|
| StockRegistry | [`0x4A68A731741C9253CA6293Dbe1b28078Ac58998b`](https://basescan.org/address/0x4A68A731741C9253CA6293Dbe1b28078Ac58998b#code) |
| CubeFactory | [`0x67DBAeAA5B8e6B1179ceb56aed82345cDe5B9BED`](https://basescan.org/address/0x67DBAeAA5B8e6B1179ceb56aed82345cDe5B9BED#code) |
| GlacierRouterV2 | [`0x4F854230f990615f91b0Fe73625BDb02299cB3cD`](https://basescan.org/address/0x4F854230f990615f91b0Fe73625BDb02299cB3cD#code) |
| GlacierRouter (v1, retired) | [`0x6bEF409f6cC4C0C392b2E40ff08773F214405Fcb`](https://basescan.org/address/0x6bEF409f6cC4C0C392b2E40ff08773F214405Fcb#code) |

Supported stocks (13, every Coinbase tokenized stock on Base with a live Chainlink feed): NVDAc, AAPLc, MSFTc, TSLAc, GOOGLc, AMZNc, METAc, MSTRc, SPCXc, SNDKc, INTCc, CRCLc, ANTc. Each one has a Chainlink feed and a USDC route through a verified Aerodrome CL pool.

## How it works
        USDC                                   stock tokens

Investor ───────► GlacierRouterV2 ──── swaps ────► Aerodrome CL pools
▲ │
│ shares │ seed / join / exitFor
│ ▼
└────────────────── Cube ◄──── created by ──── CubeFactory ◄── StockRegistry
(holds the stocks, (1-5 stocks, (allowed stocks +
prices via Chainlink) fee caps) Chainlink feeds)


- **StockRegistry** lists the stocks a Cube may hold, each paired with its Chainlink feed.
- **CubeFactory** creates Cubes: 1 to 5 listed stocks, weights summing to 100%, entry fee up to 3%, profit fee up to 25% of profit.
- **Cube** holds the stocks and mints shares (1 share = $1 at seed). Joins and exits are pro rata to current holdings. Shares are non-transferable so each holder's cost basis stays exact. The profit fee is only charged on exit, and only on profit. Creators can lower fees, never raise them.
- **GlacierRouterV2** turns USDC into a Cube position and back in one transaction: `seedWithUSDC`, `joinWithUSDC`, `exitToUSDC`.

## Design decisions

- **Prices come from Chainlink, and are never multiplied again.** The Coinbase feeds on Base already report the price per token (they match the Tokenized Stocks API `nav_price`), so applying the B20 multiplier a second time would misprice stocks after corporate actions (for example, SNDKc has a multiplier of 8).
- **Swaps go through Aerodrome, not Uniswap v3.** Onchain checks in November 2026 found the c-stock/USDC liquidity concentrated in Aerodrome CL pools ($57k to $286k of USDC per pool) while Uniswap v3 pools held $0 to $8k. v2 of the router was built and deployed for this.
- **Every swap is floored at the Chainlink price.** Minimum outputs come from the oracle, not the pool, so a thin or manipulated pool cannot fill far from fair value. Slippage is hard-capped at 10%.
- **Pools are checked against the factory.** The router only accepts a pool that pairs USDC with that stock, comes from an allowed factory, and is confirmed by that factory's `getPool`. The swap callback only pays the pool that is mid-swap.
- **Exits always work.** `exit` (in kind) needs no swaps and never reverts on a bad price; the profit fee is skipped instead.

## Proof on mainnet

- Contracts can hold and send B20 stocks: [transfer into a test contract](https://basescan.org/tx/0x7ea94f3319f0fbcf544da185ab1be73314082636bab3a77e9288091da044f56c), then swept back.
- Full USDC round trip through GlacierRouterV2 on a 50/50 NVDAc/AAPLc Cube: 2.000000 USDC in, 1.999150 USDC out (0.04% total cost). [Exit transaction](https://basescan.org/tx/0xb598f7f26293c3227eb7204ee39bfc14bd6084fed11ddd8480bb7f01c814c786).

## Run it locally

```bash
git clone --recursive https://github.com/MELcodes99/Glacier.git
cd Glacier
forge build
forge test
```

Deploy scripts are in `script/`. Never put private keys in files; use `cast wallet import` and `--account`.

## Eligibility

Coinbase Tokenized Stocks are available only to eligible users and are not offered to U.S. persons. Glacier is non-custodial software; using it is subject to the eligibility rules of the underlying tokens. Nothing here is investment advice.

## License

MIT
