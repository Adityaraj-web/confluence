# F09 Setup and demo runner scripts

- Owner: T2
- Depends on: F05, F07
- Architecture: sections 2 and 8
- Demo: docs/DEMO.md steps 3-6

## Goal
One command sets up the whole demo on a fresh anvil fork; another runs the comparison and prints the numbers the demo uses.

## Files
- `contracts/script/Setup.s.sol` (forge script, steps 2-5 and 7 of ARCHITECTURE section 2)
- `scripts/src/shipStrategy.ts` (step 6, as Priya)
- `scripts/src/demo.ts`
- `deployments/local.json` (written by setup; read by scripts and the web app)
- `Makefile` or `scripts/package.json` targets: `fork`, `setup`, `demo`

## Behaviour
- `make fork` starts anvil at `FORK_BLOCK`.
- `make setup` runs the forge script and `shipStrategy.ts`, takes a snapshot, saves the snapshot id to `deployments/local.json`.
- `make demo` runs: revert to snapshot, pool-only swap, record; revert, split swap with the quoter's hint, record; prints a table (MUMB out, average price, split, Priya's wallet and Aqua balances before and after, pool liquidity) and writes `deployments/last-demo.json`.
- `make demo-guard` moves the pool price with a large trade, then shows the Aqua leg being skipped (`AquaSkipped`).
- All keys are anvil's public test keys from `.env`.

## Acceptance
- From a fresh anvil: `make setup && make demo` completes and prints split output > pool-only output.
- `make demo` run twice in a row prints identical numbers (snapshot works).
- `make demo-guard` prints the skip reason.
