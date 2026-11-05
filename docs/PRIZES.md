# Prize requirements checklist

Source: the ETHGlobal Mumbai prize pages, read on Oct 29, 2026. Re-read both pages at hour 0 in case they changed. Classic track only. Check every box before submitting.

## Uniswap Foundation: Build with Uniswap ($10,000; 4k / 3k / 2k / 1k)

Page: https://ethglobal.com/events/mumbai/prizes/uniswap-foundation

Scope: build on or integrate any part of the Uniswap stack; the page names new v4 hooks as eligible.

- [ ] Public GitHub repository with open-source code (licence file in the root)
- [ ] `FEEDBACK.md` in the repo describing our real experience building with Uniswap
- [ ] Uniswap Developer Feedback Form submitted (https://developers.uniswap.org/hackathon-feedback), including the link to our FEEDBACK.md
- [ ] README points to the exact contracts and lines of code that integrate Uniswap (hook `beforeSwap`, delta settlement, pool setup script)
- [ ] Treat all of the above as mandatory; the page says entries without them face review and audit before winners are finalised

How we satisfy it: ConfluenceHook is a new v4 hook with custom accounting; the split fill is the product.

## 1inch: Build an Aqua App ($5,000; 2.5k / 1.5k / 1k)

Page: https://ethglobal.com/events/mumbai/prizes/1inch

Ask: a custom Aqua app that implements a sophisticated DeFi position, shown through test scripts or a UI. SwapVM projects score higher; custom opcodes and instructions are allowed. At the event, 1inch recommended using their deployed SwapVM contracts with an Extruction rather than a custom opcode (D-13).

- [ ] Official Aqua contract used (we call the deployed registry; never modified)
- [ ] Official SwapVM used: Priya's strategy runs on the deployed `AquaSwapVMRouter` v1.0.2, unmodified; our custom logic is an Extruction target
- [ ] Onchain token transfers shown live in the final demo (a local fork is allowed)
- [ ] Proper Git commit history: steady commits from kickoff, no single-commit entry on the final day
- [ ] Position demonstrated through test scripts and the demo UI

How we satisfy it: Priya's position is a SwapVM strategy on Aqua that backs a v4 pool's depth, guarded by our PoolPriceBand Extruction, a reusable module any maker can plug into any strategy with no redeploy.

## ETHGlobal rules that apply to every submission

- [ ] All project code written after kickoff; planning docs only before
- [ ] README says how we used AI (Claude Code), as ETHGlobal's rules require
- [ ] Demo video recorded within the length ETHGlobal sets (check the submission form)
- [ ] Partner prizes picked on the submission form: Uniswap and 1inch

## Pitch lines per judge

- Uniswap judges: "A v4 pool with almost no locked liquidity trades deep, because a hook fills from makers' Aqua balances in the same swap."
- 1inch judges: "A SwapVM position on your own deployed router that powers a v4 pool, protected by an Extruction that pins fills to the pool's live price."
