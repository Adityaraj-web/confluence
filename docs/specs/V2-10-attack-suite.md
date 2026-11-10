# V2-10 Attack suite

- Owner: Adityaraj
- Depends on: V2-04 to V2-08
- Branch: `v2/10-attacks`
- Architecture: ARCHITECTURE-v2 sections 4, 6

## Goal
Show each known attack failing on v2, with the attacker's measured profit or loss, and show the worst ones succeeding on `v1-hackathon`.

## Files
- `contracts/test/attack/*.t.sol`
- `contracts/test/attack/v1/*.t.sol` (deploy `src/v1/ConfluenceHookV1` and v1's band contract on the same fork)
- `docs/THREATS.md`

## Behaviour
One test file per scenario; each reports attacker PnL and maker PnL.
1. Same-block guard sandwich: flash-push the pool to a stale maker price, fill the maker, swap back. v1: succeeds. v2: refused.
2. Cross-block push of the previous block's close: bounded by `driftBps`; report max maker loss and attacker cost.
3. Stale maker after a real market move: dropped as off-market.
4. Phantom and underfunded makers: capped before allocation, no revert.
5. Gas-burning strategy: bounded by `LEG_GAS_CAP`; evictable.
6. Registry spam and phantom-depth eviction. v1 displacement (D-18): succeeds. v2: refused.
7. Revert-data bomb: bounded copy.
8. Dust swaps farming rounding: legs under `MIN_LEG_BPS` skipped; rounding favours the maker.
9. Re-entry through the Extruction: anchor read is a view; PoolManager locked.
10. Direct router fill of an exclusive strategy: refused.
11. EMA lag in a fast market: record how long makers pause after a 10% move (the defence's cost).
- `THREATS.md`: attacker, asset, path, defence, test, residual risk, mapped to Uniswap's hook permission risk view.

## Acceptance
All scenario tests pass on v2. Scenarios 1 and 6 demonstrably succeed against `ConfluenceHookV1` (positive attacker PnL asserted). THREATS.md lists every scenario with its test name.
