# Progress log

Newest entry at the bottom. Claude appends one entry after each feature step; humans may add notes too. Keep each entry short.

Entry format:

```
## <YYYY-MM-DD HH:MM IST> · <F0X> · <T1|T2> · <Done|In progress|Blocked>
- Changed: <files>
- Verified: <test command> -> <result>
- Decisions: <D-xx added or none>
- Next: <the next concrete step>
- Open issues: <none, or one line each>
```

## 2026-10-30 · pre-kickoff · both · Done
- Changed: docs drafted (CLAUDE.md, ARCHITECTURE, FEATURES, DECISIONS, PRIZES, DEMO, WORKFLOW, specs F00-F12).
- Verified: no code exists yet (Classic track rule).
- Decisions: D-04 and D-11 still Open.
- Next: at kickoff, create the repo, commit these docs, start F00.
- Open issues: FORK_BLOCK to fill in at kickoff. PoolManager address filled in on Oct 30.

## 2026-11-05 · pre-kickoff · both · Done
- Changed: CLAUDE.md, ARCHITECTURE, DECISIONS, FEATURES, PRIZES, DEMO, specs F00-F03, F05, F05-ALT, F11, .claude rules and spec-reviewer. 1inch recommended using their deployed SwapVM router with an Extruction instead of a custom opcode.
- Verified: canonical Aqua and router addresses and the Extruction interface checked against 1inch's docs (Nov 5).
- Decisions: D-13 and D-14 added; D-03 superseded; D-04 decided (v1.0.2); D-11 closed.
- Next: create the repo, commit these docs, fill D-01 FORK_BLOCK, start F00.
- Open issues: D-02 (hook as taker inside `beforeSwap`) is the hour-1 mentor question.
