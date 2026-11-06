# Demo script (target: 3 minutes live, plus a recorded backup)

Numbers in angle brackets are filled in from the real run during F09. Never put a number on a slide that the demo did not produce.

## Setup before judges arrive
- A **fresh** anvil fork at `FORK_BLOCK`: `pnpm --dir scripts run fork` (it keeps running; leave it in its own terminal).
- Then `pnpm --dir scripts run deploy`: deploys, registers, ships Priya's strategy and takes the snapshot. **`deploy` needs a fresh fork. If the fork has been used, stop it and run `fork` again first**: a second `deploy` on the same fork stops with "already shipped".
- Between and during rehearsals use `pnpm --dir scripts run demo` (every run reverts to the snapshot itself and leaves a new one), and `demo:reset` if you want the chain back at the snapshot without running a swap. No new `deploy` is needed.
- Web app open on the comparison screen; terminal with the demo runner visible.
- Backup: the recorded run (OBS) on the desktop.

## Script

1. **The problem (20 s).** "A new token's Uniswap pool starts thin. To make it deep, a market maker has to lock inventory in that one pool, where it can serve nothing else."
2. **The idea (20 s).** "CONFLUENCE is a v4 hook. Its depth comes from Priya's Aqua strategy: her tokens stay in her wallet until the moment of a fill."
3. **Pool alone (30 s).** Revert to snapshot. Trader swaps 1,000 USDC with the hint set to zero. Show: `<X>` MUMB out, average price `<p1>`.
4. **CONFLUENCE (40 s).** Revert to snapshot. Same swap with the quoter's hint. Show: `<Y>` MUMB out, average price `<p2>`, split `<a>` USDC to Aqua and `<rest>` to the pool.
5. **Where the depth came from (30 s).** Show Priya's wallet: MUMB down by `<b>` only at the fill; her Aqua USDC balance up by `<a>`. Show the pool's locked liquidity: unchanged across both runs.
6. **The guard (20 s).** Move the pool price with a large trade, then swap again: PoolPriceBand refuses the Aqua leg, the hook falls back, the pool fills everything. "Priya is never filled at a stale price, and Aqua can never break a swap."
7. **Close (20 s).** "One v4 hook and one Extruction module on 1inch's own deployed SwapVM router. Aqua and SwapVM are untouched, and it all runs on a mainnet fork with real token transfers."

## Lines to avoid
- Do not say Priya's balance also quotes on 1inch (unverified).
- Do not quote gas costs or volumes we did not measure.

## Questions judges may ask
- "Why not just add liquidity?" Locked liquidity serves one pool; Aqua liquidity stays in the maker's wallet and can back several strategies.
- "How is this different from Unihook?" Unihook used off-chain market-maker quotes; we fill from a self-custodial onchain Aqua balance in the same swap, guarded by an onchain price band.
- "What if Aqua fails mid-swap?" The hook unwinds and the pool fills the whole swap (show `test_F06_*`).
- "Why an Extruction and not a custom opcode?" 1inch recommended it: no forked router, the strategy runs on their deployed contracts, and the band is reusable by any maker.
- "Who sets the hint?" Phase 1: the quoter simulates splits off-chain. Phase 2 (if built): the hook searches on-chain with a fixed number of quotes.
