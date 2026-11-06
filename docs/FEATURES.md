# Features

Build in this order. A feature starts only when the features it depends on are Done. Update the Status column when a feature changes state (Todo, In progress, Done, Blocked, Dropped).

| ID | Feature | Owner | Depends on | Status | Gate / priority |
| --- | --- | --- | --- | --- | --- |
| F00 | Repo scaffold and dependencies | Both | — | Done | Hour 0-1 |
| F01 | Fork test base and MockMUMB | T1 | F00 | Done | Must |
| F02 | Aqua baseline: ship and swap on the canonical router | T2 | F00, F01 | Done | Must |
| F03 | PoolPriceBand extruction (no router changes) | T2 | F02 | In progress | Must (1inch) |
| F04 | Pool, seed position and hook skeleton (pool-only swaps) | T1 | F01 | Todo | Must |
| F05 | Aqua leg inside the hook (phase 1, hint) | T1 + T2 | F03, F04 | Todo | **Hour-8 gate** |
| F05-ALT | Router-level split fallback | T1 + T2 | F03, F04 | Todo | Only if F05 misses hour 8 |
| F06 | Safety: try/catch unwind and skip cases | T1 | F05 | Todo | Must |
| F07 | Off-chain quoter | T2 | F05 | Todo | Must (demo) |
| F08 | Invariant and fuzz tests | T1 | F06 | Todo | Should |
| F09 | Setup and demo runner scripts | T2 | F05, F07 | Todo | Must (demo) |
| F10 | Demo web app | Both | F09 | Todo | Should |
| F11 | Submission pack: README, FEEDBACK.md, video | Both | F09 | Todo | Must (prizes) |
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
| `test_F05_fullAquaFill` passes | 8 | | |
| Any path moves real tokens on the fork | 12 | | |
