# Prize requirements checklist

Source: the ETHGlobal Mumbai prize pages, read on Oct 29, 2026. Re-read both pages at hour 0 in case they changed. Classic track only. Check every box before submitting.

## Uniswap Foundation: Build with Uniswap ($10,000; 4k / 3k / 2k / 1k)

Page: https://ethglobal.com/events/mumbai/prizes/uniswap-foundation

Scope: build on or integrate any part of the Uniswap stack; the page names new v4 hooks as eligible.

- [x] Public GitHub repository with open-source code (licence file in the root)
- [x] `FEEDBACK.md` in the repo describing our real experience building with Uniswap
- [ ] Uniswap Developer Feedback Form submitted (https://developers.uniswap.org/hackathon-feedback), including the link to our FEEDBACK.md
- [x] README points to the exact contracts and lines of code that integrate Uniswap (hook `beforeSwap`, delta settlement, pool setup script)
- [ ] Treat all of the above as mandatory; the page says entries without them face review and audit before winners are finalised

How we satisfy it: ConfluenceHook is a new v4 hook with custom accounting; the split fill is the product.

## 1inch: Build an Aqua App ($5,000; 2.5k / 1.5k / 1k)

Page: https://ethglobal.com/events/mumbai/prizes/1inch

Ask: a custom Aqua app that implements a sophisticated DeFi position, shown through test scripts or a UI. SwapVM projects score higher; custom opcodes and instructions are allowed. At the event, 1inch recommended using their deployed SwapVM contracts with an Extruction rather than a custom opcode (D-13).

- [x] Official Aqua contract used (we call the deployed registry; never modified)
- [x] Official SwapVM used: Priya's strategy runs on the deployed `AquaSwapVMRouter` v1.0.2, unmodified; our custom logic is an Extruction target
- [ ] Onchain token transfers shown live in the final demo (a local fork is allowed)
- [x] Proper Git commit history: steady commits from kickoff, no single-commit entry on the final day
- [x] Position demonstrated through test scripts and the demo UI

How we satisfy it: Priya's position is a SwapVM strategy on Aqua that backs a v4 pool's depth, guarded by our PoolPriceBand Extruction, a reusable module any maker can plug into any strategy with no redeploy.

## ETHGlobal rules that apply to every submission

- [ ] All project code written after kickoff; planning docs only before
- [x] README says how we used AI (Claude Code), as ETHGlobal's rules require
- [ ] Demo video recorded within the length ETHGlobal sets (check the submission form)
- [ ] Partner prizes picked on the submission form: Uniswap and 1inch

## Pitch lines per judge

- Uniswap judges: "A v4 pool with almost no locked liquidity trades deep, because a hook fills from makers' Aqua balances in the same swap."
- 1inch judges: "A SwapVM position on your own deployed router that powers a v4 pool, protected by an Extruction that pins fills to the pool's live price."

## Status (F11, Nov 7, 2026)

Ticked, with the evidence:
- Public repo and licence: `gh repo view` reports PUBLIC and MIT; `LICENSE` is in the root.
- FEEDBACK.md and README code links: all 12 pinned blob links in README.md return 200 and the anchored lines hold the code named (checked by fetching the raw file at the pinned commit).
- Official Aqua and SwapVM: the registry and `AquaSwapVMRouter` v1.0.2 at their official addresses, unmodified (F01 asserts `AQUA()` and `eip712Domain()`; F02 and F05 fill through them on the fork).
- Commit history: 97 commits before F11 across Nov 5 (14) and Nov 6 (83), all `F0X:` messages from F00 on; the first commit (Nov 5, 15:40 UTC) holds only planning docs and `.claude` config.
- AI statement: README section 8.

**Not ticked, on purpose** (each needs a person or an event that has not happened):
- Uniswap Developer Feedback Form: not submitted. Submit it with the link to FEEDBACK.md.
- "Onchain token transfers shown live in the final demo": the video is not recorded and the final demo has not happened.
- "All project code written after kickoff": the team makes this claim.
- Demo video: placeholder only (`docs/demo-video-link.md`).
- Partner prizes picked on the submission form.
