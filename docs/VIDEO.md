# Demo video script (target 2:45; check the length limit on the ETHGlobal submission form)

Record from **live mode** (`pnpm --dir web dev`) on a fresh `deploy`, browser at 1280x720, OBS, dark theme. Do one warm-up "Run both" first so anvil has fetched the forked state (the first run is slower), then `demo:reset`. Record voice separately if the room is loud. Every number below must be the one on screen; if a number differs, re-record, don't edit the script.

| Time | Screen | Voice-over |
| --- | --- | --- |
| 0:00-0:12 | Landing, pitch line | "CONFLUENCE: a Uniswap v4 pool with almost no locked liquidity that still trades deep, because its depth sits in a market maker's own wallet, through 1inch Aqua." |
| 0:12-0:30 | Landing, problem line | "A new token's pool starts thin. To make it deep, a market maker has to lock inventory in that one pool, where it can't serve anything else." |
| 0:30-0:55 | Tab 4, How it works, steps highlight one by one | "Our v4 hook runs before every swap. It buys part of the trade from Priya's Aqua strategy on 1inch's own deployed SwapVM router, and the pool curve fills the rest. Priya's program is a fee, a curve, and an Extruction step that calls our band contract: it refuses any fill more than 2% from the pool's live price." |
| 0:55-1:30 | Tab 1, 1,000 USDC, "Run both"; quoter curve draws | "Same trade, same starting state. Pool alone: 984.93 MUMB, price impact 2.40%. With CONFLUENCE: 991.55 MUMB, plus 67 basis points, and the price moves only 1.09%. Our quoter simulated sixteen splits and picked 55% through Aqua." |
| 1:30-1:40 | Click 2k preset, "Run both" | "At 2,000 USDC the gain is 134 basis points." |
| 1:40-2:00 | Tab 2, Depth | "Where did the depth come from? Priya's wallet paid 545.36 MUMB only at the moment of the fill, her Aqua balance gained 550 USDC, and the pool's locked liquidity didn't change at all." |
| 2:00-2:22 | Tab 3, Guard, run | "Now someone moves the pool 3.57% and we retry the same split. Priya's fill would be 3.14% off the pool price, outside her 2% band, so Aqua refuses. The swap still succeeds from the pool alone. Aqua can never break a swap." |
| 2:22-2:37 | Terminal: `forge test` summary (73 passed), then `pnpm --dir scripts run demo` table | "73 Foundry tests on a mainnet fork, including invariants and fuzzing, and the command-line demo prints the same numbers." |
| 2:37-2:45 | Tab 4, the two official addresses | "One hook and one Extruction module. Aqua and SwapVM are 1inch's official contracts, unmodified, with real token transfers on a mainnet fork." |

Do not say: that Priya's balance also quotes on 1inch; gas or volume figures; that the gain holds for every configuration (it holds for this setup: Priya's 0.30% fee against the pool's 0.30%, 100,000 of each token shipped, D-22).

Backup: export at 1080p, keep a copy on the desktop and one on a USB stick for the live judging.