# Features

Build in this order. A feature starts only when the features it depends on are Done. Update the Status column when a feature changes state (Todo, In progress, Done, Blocked, Dropped).

| ID | Feature | Owner | Depends on | Status | Gate / priority |
| --- | --- | --- | --- | --- | --- |
| F00 | Repo scaffold and dependencies | Both | — | Done | Hour 0-1 |
| F01 | Fork test base and MockMUMB | T1 | F00 | Done | Must |
| F02 | Aqua baseline: ship and swap on the canonical router | T2 | F00, F01 | Done | Must |
| F03 | PoolPriceBand extruction (no router changes) | T2 | F02 | Done | Must (1inch) |
| F04 | Pool, seed position and hook skeleton (pool-only swaps) | T1 | F01 | Done | Must |
| F05 | Aqua leg inside the hook (phase 1, hint) | T1 + T2 | F03, F04 | Done | **Hour-8 gate** |
| F05-ALT | Router-level split fallback | T1 + T2 | F03, F04 | Todo | Only if F05 misses hour 8 |
| F06 | Safety: try/catch unwind and skip cases | T1 | F05 | Done | Must |
| F07 | Off-chain quoter | T2 | F05 | Done | Must (demo) |
| F08 | Invariant and fuzz tests | T1 | F06 | Done | Should |
| F09 | Setup and demo runner scripts | T2 | F05, F07 | Done | Must (demo) |
| F10 | Demo web app | Both | F09 | Tier 1 done and deployed (https://confluence-delta-seven.vercel.app/, replay); Tier 2 not built | Should |
| F11 | Submission pack: README, FEEDBACK.md, video | Both | F09 | In progress (README and FEEDBACK.md written, links verified; video, Uniswap form and partner prizes pending) | Must (prizes) |
| F12 | On-chain bounded search (phase 2) | T2 | F06 | Todo | Stretch |

## Parallel tracks

- Hours 0-8: T1 does F01 then F04; T2 does F02 then F03. F03 is one small contract since D-13, so T2 should finish early and prepare F05's `ConfluenceBase` strategy wiring with T1. Both meet at F05.
- Hours 8-20: T1 does F06 then F08; T2 does F07 then F09.
- Hours 20-32: F10 together, then F11. F12 only if everything above is Done.
- Hours 32-36: freeze. Bug fixes, demo rehearsal, video, submission.

## Gate log

| Gate | Hour | Result | Decision |
| --- | --- | --- | --- |
| 1inch recommendation: use the canonical router + Extruction, not a custom opcode | 0 (Nov 5) | Accepted | D-13 |
| Mentor question: hook as Aqua taker on the canonical router inside `beforeSwap` | 1 | 1inch: possible (Nov 5) | Proceed with F05; mechanics verified in F02 |
| `test_F05_fullAquaFill` passes | 8 | Passed (Nov 6, commit 6fc7d94) | Stay on F05; F05-ALT not needed |
| Any path moves real tokens on the fork | 12 | Not triggered; F05 passed Nov 6 | |

# v2 Phase 1 (protocol)

Solo build by Adityaraj from Nov 11, 2026. Design: `docs/ARCHITECTURE-v2.md`. Build in milestone order; within a milestone, follow Depends on. V2-03 needs only V2-00 and may run in parallel with V2-01/02.

| ID | Spec | Milestone | Depends on | Status | Gate |
| --- | --- | --- | --- | --- | --- |
| V2-00 | Reference model and repo prep | M1 Maths core | — | Done | **G0 passed** (D-28) |
| V2-01 | SplitMath | M1 | V2-00 | Todo | |
| V2-02 | PoolVenue | M1 | V2-01 | Todo | M1: split = brute force and fork oracle |
| V2-03 | Anchor | M2 Guard | V2-00 | Todo | |
| V2-04 | BandGuardV2 | M2 | V2-03 | Todo | M2: same-block attack refused |
| V2-05 | StrategyTemplate and registry | M3 Maker market | V2-04 | Todo | |
| V2-06 | MakerVenue | M3 | V2-03, V2-05 | Todo | |
| V2-07 | Hint-free split in beforeSwap | M3 | V2-01, V2-02, V2-03, V2-06 | Todo | **M3: empty hookData beats v1's hinted best** |
| V2-08 | Exact output | M4 Completeness | V2-07 | Todo | |
| V2-09 | Quoting parity and Lens | M4 | V2-07, V2-08 | Todo | M4: quoter = swap, both modes |
| V2-10 | Attack suite | M5 Proof | V2-04 to V2-08 | Todo | |
| V2-11 | Gas budget | M5 | V2-07 to V2-09 | Todo | |
| V2-12 | Invariants v2 and Phase 1 exit | M5 | all | Todo | Phase 1 exit |
