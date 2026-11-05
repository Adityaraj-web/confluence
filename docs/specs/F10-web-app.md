# F10 Demo web app

- Owner: Both
- Depends on: F09
- Demo: docs/DEMO.md

## Goal
A single-page app that makes the demo readable from the back of a room: pool-only vs CONFLUENCE side by side, and where the depth came from.

## Files
- `web/src/` (React components, hooks)
- `web/src/lib/` (viem clients; reuses `scripts/src/quoter.ts` logic, imported or copied with a note)

## Screens and behaviour
1. **Header:** pair, pool fee, current pool price, band width.
2. **Trader panel:** amount input, direction toggle, "Quote" (runs the quoter) and two buttons: "Swap pool-only" and "Swap with CONFLUENCE". Each run reverts to the snapshot first (anvil `evm_revert` / `evm_snapshot` over JSON-RPC), so both start equal.
3. **Comparison card:** MUMB out and average price for both runs, the difference in percent, a bar showing the Aqua/pool split.
4. **Priya panel:** wallet MUMB and USDC, Aqua virtual balances, before and after the last swap.
5. **Pool panel:** in-range liquidity before and after (unchanged is the point).
6. **Guard button:** runs the guard scenario and shows "Aqua leg skipped: band exceeded".
- Wallets: anvil test keys as local accounts (no wallet pop-ups).
- Reads addresses from `deployments/local.json`.
- Large type, high contrast; works at 1280x720 for the projector.

## Out of scope
Wallet connection, mobile layout, hosted deployment (optional static build only).

## Acceptance
- With anvil set up by F09: both swap buttons work, numbers match `make demo` for the same amount.
- Guard button shows the skip.
- `pnpm --dir web build` passes with no type errors.
- Screenshot of the comparison screen saved to `docs/demo-screenshot.png`.
