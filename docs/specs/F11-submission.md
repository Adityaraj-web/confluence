# F11 Submission pack

- Owner: Both
- Depends on: F09 (F10 for screenshots)
- Checklist: docs/PRIZES.md

## Goal
Everything judges and sponsors check, written from what we actually built.

## Files
- `README.md`
- `FEEDBACK.md` (Uniswap)
- `docs/demo-video-link.md`

## README sections
1. One-line pitch and the problem (3 sentences).
2. How it works: the six steps from CLAUDE.md and the diagram from ARCHITECTURE.
3. **Uniswap integration**: links to the exact files and line ranges of `beforeSwap`, the take/settle code, the delta return, and the pool setup script.
4. **1inch integration**: links to `PoolPriceBandExtruction`, Priya's program builder (showing the Extruction step), and the Aqua `ship` call. State that Aqua and the AquaSwapVMRouter are used unmodified at their official addresses, and that we chose Extruction on 1inch's recommendation. State the D-14 limitation for outside takers.
5. Run it: prerequisites, `.env`, `make fork`, `make setup`, `make demo`, web app.
6. Tests: how to run them, and the list of acceptance and invariant tests.
7. Limitations: exact-input only, one maker per pool, hint computed off-chain, fork-only demo.
8. How we used AI: Claude Code for implementation from our own specs in `docs/`; humans designed the architecture and reviewed every change.
9. Licence and credits (any vendored swap-vm interface files keep their licence).

## FEEDBACK.md
Real notes collected during the build (keep a running list in PROGRESS.md from hour 0): what was easy, what was confusing in v4 docs, bugs or friction, suggestions. Honest and specific.

## Acceptance
- Every box in `docs/PRIZES.md` ticked.
- Every README code link opens the right lines on GitHub.
- A teammate who did not write the README can run the demo from it on a clean clone.
- Uniswap feedback form submitted with the FEEDBACK.md link.
