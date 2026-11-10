# V2-06 MakerVenue

- Owner: Adityaraj
- Depends on: V2-03, V2-05
- Branch: `v2/06-makervenue`
- Architecture: ARCHITECTURE-v2 sections 2 (step 3), 6

## Goal
Turn each registered strategy into a venue with honest reserves and a cap, before any money moves.

## Files
- `contracts/src/libraries/MakerVenue.sol`
- `contracts/test/fork/V206MakerVenue.t.sol`

## Behaviour
- X, Y = the strategy's Aqua virtual balances on the input and output side; fee factor 1 − feeE9/1e9.
- Output cap = min(virtual Y, maker wallet balance of the output token, maker allowance to Aqua). Converted to an input cap through the curve.
- Band cap = the largest input whose execution price stays within `bandBps` of the snapshot, solved from the curve formula (no search).
- PoolManager cap = PoolManager's balance of the input token (v1 `PoolManagerShort`).
- Drop the maker (status SKIP_BAND / SKIP_DRIFT / SKIP_UNDERFUNDED) when its curve price is outside the band, drift is broken, or its cap is zero.
- Rounding mirrors SwapVM v1.0.2: output floor, fee ceiling (`Fee.sol`, `XYCSwap.sol` under `contracts/lib/`).
- View only.

## Out of scope
Executing legs (V2-07).

## Acceptance
- `test_V206_capFromWallet`: the maker spends output tokens elsewhere; the cap shrinks to the new balance, and a router fill at the cap succeeds.
- `test_V206_sharedWallet`: same wallet backs a second Aqua strategy outside CONFLUENCE; caps reflect the real balance.
- `test_V206_bandCapMatchesGuard`: a fill at the band cap passes BandGuardV2; cap + 1 wei reverts `BandExceeded`.
- `test_V206_offMarketDropped`, `test_V206_driftDropped`.
- `test_V206_predictionEqualsRouterQuote`: predicted output equals the router's `quote` for 5 sizes (open strategy, so `quote` is allowed), to the wei.
