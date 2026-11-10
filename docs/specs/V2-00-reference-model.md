# V2-00 Reference model and repo prep

- Owner: Adityaraj
- Depends on: none
- Branch: `v2/00-reference`
- Architecture: ARCHITECTURE-v2 sections 3, 5
- Decisions: D-27

## Goal
One source of truth for the right answer, outside Solidity, so every on-chain number in V2 can be checked against an independent model and against real swaps on the fork.

## Files
- `reference/venues.py`, `reference/waterfill.py`, `reference/brute.py`, `reference/gen_vectors.py`, `reference/test_reference.py`, `reference/README.md`
- `contracts/test/vectors/*.json` (generated, committed)
- `contracts/test/base/Vectors.sol`
- `contracts/test/base/ForkOracle.sol`
- `contracts/test/unit/V200Reference.t.sol`, `contracts/test/fork/V200ForkOracle.t.sol`, `contracts/test/fork/V200UnichainTaker.t.sol`
- `.env.example` (`UNICHAIN_RPC_URL`, `UNICHAIN_FORK_BLOCK`)
- `foundry.toml` (only `fs_permissions` read access to `test/vectors`)
- `contracts/src/v1/ConfluenceHookV1.sol`, `contracts/src/v1/PoolPriceBandExtruction.sol` (moved with `git mv`; contract renamed `ConfluenceHookV1`; no behaviour change)
- import paths in `contracts/test/**` and `contracts/script/Setup.s.sol` that reference the moved files (path edits only). The committed ABIs under `scripts/src/abis/` and the web app are not regenerated or changed.
- git tag `v1-hackathon` on `bf4b236` (pushed)

## Behaviour
- `venues.py`: constant-product venue (X, Y, feeE9, cap); a v4 pool venue built from `(sqrtPriceX96, liquidity, [(tick, liquidityNet)], feePips)` with exact tick maths.
- `waterfill.py`: closed form for exact input and exact output (ARCHITECTURE-v2 section 3), active set, cap pinning, piecewise pool walk.
- `brute.py`: grid optimiser over 2 and 3 venues for both swap types; the referee for `waterfill.py`.
- `gen_vectors.py`: writes JSON vectors (inputs, expected per-venue amounts, totals). Integer mode mirrors Solidity: `FullMath.mulDiv` floor, integer sqrt floor, maker amounts floored, pool takes the remainder. Python stdlib only, no numpy, deterministic output (same bytes on rerun).
- `Vectors.sol`: loads a vector file with `vm.readFile` + `vm.parseJson`. CI needs no FFI.
- `ForkOracle.sol`: given candidate splits, runs each from one `vm.snapshotState()` on the fork with the v1 deployment and returns the realised outputs.
- Gate G0, run before anything else: on a Unichain fork, a test maker ships a program shaped like template T1 (fee, XYC, Extruction to a stub that returns registers unchanged; no KYC opcode) and a test contract fills it through Unichain's router as taker. This is what every later spec assumes. Read the router address from 1inch's deployments page and check its bytecode hash matches mainnet's [VERIFY].
- Freeze v1: move the v1 hook and band contract into `src/v1/` so the v2 hook can be written fresh at `src/ConfluenceHook.sol` (V2-03) while the attack suite (V2-10) can still deploy v1. Only paths and the contract name change; the v1 suite must pass unchanged.
- Python checks run with `python3 -m unittest reference/test_reference.py`.

## Out of scope
Any behaviour change under `contracts/src/` (the v1 move is paths and a name only). CLAUDE.md is updated in the docs commit that ships these specs, not here.

## Acceptance
- `test_V200_ungatedTakerOnUnichain` **(gate G0, first)**: passes, or stop all V2 work and record the failure in DECISIONS.
- `python3 -m unittest reference/test_reference.py`: `test_closed_form_matches_brute` (2 and 3 venues, exact in and out, relative error < 1e-6), `test_pool_only_matches_v1` (1,000 USDC -> 984.934195 MUMB, 6 dp), `test_vectors_deterministic`.
- `test_V200_vectorsLoad`: every file in `test/vectors` parses and has the expected fields.
- `test_V200_forkOracleReproducesV1`: pool-only exactly 984934194542570551127 wei MUMB and hint 550000000 -> exactly 991549823315669231761 wei MUMB for 1,000 USDC (D-21 numbers).
- All 73 v1 tests still pass after the move, with no assertion changed.
