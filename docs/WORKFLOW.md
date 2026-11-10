# Working loop with Claude Code

This file is for us, the humans. It holds the kickoff steps and the prompts we paste into Claude Code.

## At kickoff (hour 0)

1. Create an empty public GitHub repo, `confluence`, and clone it on both laptops.
2. Copy this whole folder in: `CLAUDE.md`, `docs/`, `.claude/`. Copy `docs/claude-settings.example.json` to `.claude/settings.json` (pre-approves forge, pnpm, make and git commands; blocks reading `.env`). Commit: `docs: project context`.
3. Copy `.env.example` to `.env` (each teammate, with their own RPC key). Run `cast block-number --rpc-url $MAINNET_RPC_URL`, round down to a multiple of 100, and put the same `FORK_BLOCK` in both `.env` files and in DECISIONS D-01. Commit DECISIONS.
4. Open Claude Code in the repo. Run `/context` and check that CLAUDE.md is listed under memory files.
5. Re-read both prize pages; update `docs/PRIZES.md` if anything changed.
6. T1 and T2 start F00 together (one laptop), then split.

## The loop for every feature

1. `/clear`
2. Switch to plan mode (`Shift+Tab` until it shows plan mode) and paste:

   ```
   We are starting F0X. Read docs/specs/F0X-*.md, the ARCHITECTURE.md sections it names,
   and the last five entries of docs/PROGRESS.md. Check the [VERIFY] items against the
   source in contracts/lib/ and tell me what you found. Then propose a step-by-step plan
   with the files you will create or change and the tests you will write first.
   ```

3. Read the plan. Edit it (`Ctrl+G` opens it in your editor) or correct it in chat. Approve.
4. Let Claude build. It should write the acceptance tests early and run them until they pass.
5. Review against the spec:

   ```
   Use the spec-reviewer subagent to review the changes for F0X against docs/specs/F0X-*.md.
   Report only gaps that affect correctness or the acceptance criteria.
   ```

6. Fix real gaps only. Then:

   ```
   Run the full acceptance command for F0X and show the output. Update docs/FEATURES.md and
   append a PROGRESS.md entry. Commit with an "F0X:" message.
   ```

7. Push the branch; the other teammate pulls when they need it.

## When things go wrong

- Claude goes off track: press `Esc`, say what is wrong in one sentence.
- Two corrections on the same issue failed: `/clear`, then restart with a sharper prompt that includes what you learned.
- A change made things worse: `Esc Esc` or `/rewind` restores files and conversation to an earlier point. It does not undo shell commands; git does.
- A spec turns out wrong: fix the spec first, add a DECISIONS entry, then continue.

## Useful commands

- `/context` shows what is loaded and how full the context is.
- `/compact <what to keep>` shrinks a long session without starting over.
- `/rename <name>` names a session; `claude --resume` picks one back up.
- `/btw <question>` asks a side question without adding it to the session.

## v2 loop (solo, from Nov 11, 2026)

Once, before V2-00:

```
git tag v1-hackathon bf4b236 && git push origin v1-hackathon
```

Add `UNICHAIN_RPC_URL` (free Alchemy/Infura Unichain endpoint) and `UNICHAIN_FORK_BLOCK` to `.env`.

Per spec:

1. `git checkout main && git pull && git checkout -b v2/<nn>-<name>`, then `/clear` in Claude Code.
2. Plan mode, paste:

   ```
   We are starting V2-xx. Read docs/specs/V2-xx-*.md, the docs/ARCHITECTURE-v2.md sections it
   names, the Acceptance sections of its Depends-on specs, and the last five entries of
   docs/PROGRESS.md. Run forge build and the full test suite and report anything red. Check the
   [VERIFY] items against the source in contracts/lib/ and tell me what you found. Then propose a
   step-by-step plan: files you will create or change, and the acceptance tests you will write
   first and show failing.
   ```

3. Approve or correct the plan. Let it build: tests red first, then green.
4. Review:

   ```
   Use the spec-reviewer subagent to review the changes for V2-xx against docs/specs/V2-xx-*.md.
   Report only gaps that affect correctness, the acceptance criteria or a hard rule.
   ```

5. Fix real gaps only, then:

   ```
   Run the acceptance command for V2-xx and the full suite and show the output. Update
   docs/FEATURES.md and append a PROGRESS.md entry. Commit with a "V2-xx:" message.
   ```

6. `git checkout main && git merge --no-ff v2/<nn>-<name> && git push`.

Gate G0 is the first test of V2-00. If it fails, stop and bring the output to the planning chat before writing anything else.
