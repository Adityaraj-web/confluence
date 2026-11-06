# Demo script (target: 3 minutes live, plus a recorded backup)

The numbers below are from `pnpm --dir scripts run demo` on the fork at `FORK_BLOCK` (F09; `deployments/last-demo.json`). Rerunning `demo` prints the same numbers, byte for byte. Never put a number on a slide that the demo did not produce. They hold for this setup (Priya's 0.30% fee against the pool's 0.30%, 100,000 of each token shipped, a 2,500 USDC / 2,500 MUMB seed); they are not a general claim.

## Setup before judges arrive
- A **fresh** anvil fork at `FORK_BLOCK`: `pnpm --dir scripts run fork` (it keeps running; leave it in its own terminal).
- Then `pnpm --dir scripts run deploy`: deploys, registers, ships Priya's strategy and takes the snapshot. **`deploy` needs a fresh fork. If the fork has been used, stop it and run `fork` again first.** A second `deploy` on a used fork does not fail: it deploys a second set of contracts (new MUMB token and hook, a different strategy hash) next to the first and overwrites `local.json`, so the addresses are no longer the ones this script's numbers were measured with (whether the numbers change was not checked). Only `ship` run twice on one deploy is refused ("already shipped").
- Between and during rehearsals use `pnpm --dir scripts run demo` (every run reverts to the snapshot itself and leaves a new one), and `demo:reset` if you want the chain back at the snapshot without running a swap. No new `deploy` is needed.
- Web app open on the comparison screen; terminal with the demo runner visible.
- Backup: the recorded run (OBS) on the desktop.

## Script

1. **The problem (20 s).** "A new token's Uniswap pool starts thin. To make it deep, a market maker has to lock inventory in that one pool, where it can serve nothing else."
2. **The idea (20 s).** "CONFLUENCE is a v4 hook. Its depth comes from Priya's Aqua strategy: her tokens stay in her wallet until the moment of a fill."
3. **Pool alone (30 s).** Revert to snapshot. Trader swaps 1,000 USDC with the hint set to zero. Show: **984.934194542570551127 MUMB** out, average price **1.015296 USDC per MUMB**. The swap moves the pool's price **2.40%**.
4. **CONFLUENCE (40 s).** Revert to snapshot. Same swap with the quoter's hint (550,000,000, 55%). Show: **991.549823315669231761 MUMB** out, average price **1.008522**, split **550 USDC to Aqua** and **450 USDC to the pool**. That is **+6.615628773098680634 MUMB, +67.16 bps** over the pool alone, and the pool's price moves **1.09%** instead of 2.40%.
   - Bigger trade, second line (`demo --amount 2000`): pool alone **1946.313880914421030318 MUMB** (average price 1.027583, price move 4.72%); with CONFLUENCE **1972.317821361470963008 MUMB** (1.014035, price move 2.16%), 1,100 USDC to Aqua and 900 to the pool: **+26.00394044704993269 MUMB, +133.60 bps**.
5. **Where the depth came from (30 s).** Show Priya's wallet: MUMB down by **545.359521066233309646** only at the fill (1,000,000 to 999,454.640478933766690354); her Aqua USDC balance up by **550** (100,000 to 100,550). The pool's locked liquidity is unchanged across both runs (81385316166712666 before and after; it is in `last-demo.json`).
6. **The guard (20 s).** `demo:guard`: a 1,500 USDC pool-only trade moves the pool price **3.57%**; then the same hinted swap (1,000 USDC, hint 550,000,000) succeeds but Aqua is refused: `AquaSkipped: PoolPriceBandExceeded(...): fill price 3.14% off the pool price, band 2.00%`. The hook falls back, the pool fills everything (**949.918037701570887505 MUMB**), and Priya's balances are untouched. "Priya is never filled at a stale price, and Aqua can never break a swap."
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
