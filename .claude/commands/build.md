---
description: Implement tasks incrementally with a split TDD loop — test-writer writes the failing tests, implementer makes them pass — brief, verify, commit. Add "auto" to run the whole plan in one approved pass.
---

Invoke the agent-skills:incremental-implementation skill for the loop shape. Two subagents do the coding under
agent-skills:test-driven-development: **test-writer** (Sonnet) writes the failing tests and may touch only test files;
**implementer** (Sonnet) makes them pass and may touch only production code. Hooks enforce both boundaries.
This conversation plans, briefs, verifies, arbitrates, and talks to the user. Keep this context free of file contents,
test output, and generated code.

## Modes

- **`/build`** — implement the *next* pending task, then stop (careful, one slice at a time).
- **`/build auto`** — generate the plan if needed, get a single approval, then implement *every* task without stopping between them.

`$ARGUMENTS` selects the mode. Treat `auto` (canonical) or `all` as autonomous mode; anything else (or empty) is the default single-task mode. Note: autonomous mode is not faster *per task* — it runs the same test-driven loop — it only removes the human stepping *between* tasks.

## Default: one task

Pick the next pending task from the plan. Then:

1. **Read the task's acceptance criteria** from `tasks/plan.md` (Grep for the task; do not read the whole plan if it is long).
2. **Decide whether the task needs investigation first.** If the change touches code whose behavior or dependencies you do not
   already understand from the plan, delegate to `codebase-analyst` with the task and the relevant paths and ask for: affected
   files with line numbers, the recommended approach, and risks. Skip this for tasks the plan already describes precisely.
   Do **not** load the files into this context yourself.
3. **RED — brief the test-writer.** Spawn `test-writer` once for this task with:
   - the task text and acceptance criteria, verbatim from the plan
   - the relevant paths (and the analyst's findings, if any)
   - what to deliver: failing tests for each acceptance criterion, run to confirm they fail for the right reason, committed as a
     test-only commit (`test: …`), plus a **contract** (modules, functions, signatures, expected values/exceptions the tests assume)
   - the report format: commit hash, test files, test names, contract, one line of RED evidence — 12 lines max, no test code
4. **Verify RED from artifacts.** Run `git show --stat HEAD` and confirm only test files changed. If the report contains a
   `BOUNDARY VIOLATION:` line, restore the listed files to their pre-task state (`git checkout <pre-task-commit> -- <files>`,
   amend or recommit), then decide whether the test-writer must redo part of its work.
5. **GREEN — brief the implementer.** Spawn `implementer` once for this task with:
   - the task text and acceptance criteria, verbatim
   - the test-writer's **contract** and the test file paths (it reads the tests itself; do not paste them)
   - the loop it must run: confirm RED → minimum code to pass → refactor with tests green → full test suite → build →
     one commit staging only the production files it touched → report
   - the report format: result, commit hash, files changed, test counts, open questions — 10 lines max, no diffs
6. **Handle the reports.**
   - *Done*: go to step 7.
   - *Implementer disputes a test* ("テストに異議"): you arbitrate. Read its evidence (paths and line numbers, not whole files),
     check the acceptance criteria, and decide. If the test is wrong, **resume the same test-writer** with the implementer's
     argument to revise the test and recommit; then **resume the same implementer**. If the test is right, resume the
     implementer with the reasoning. Never let the implementer edit tests, and never edit them yourself to unblock it.
   - *Needs a decision*: ask the user, then resume the same agent with the answer. Do not spawn a new one.
   - *Failed*: resume the same implementer with agent-skills:debugging-and-error-recovery guidance. If it is still stuck after one
     retry, stop and involve the user.
   - *Report contains `BOUNDARY VIOLATION:`*: restore the listed files to the state they had before that agent started
     (the test-writer's commit for the implementer; the pre-task commit for the test-writer), fix the commit, and resume the agent
     so it can finish cleanly. A second violation from the same agent is a stop-and-ask-the-user event.
7. **Verify GREEN from artifacts.** Run `git show --stat HEAD` and confirm only production files changed and the report names a
   passing full-suite run. For risky or user-facing changes, run the `code-reviewer` persona on the two commits. Do not read the
   changed files in full.
8. **Mark the task complete** in `tasks/plan.md` and stop.

Each task therefore produces two commits, RED then GREEN, which is the intended audit trail: the diff between them is exactly
"what it took to satisfy the tests".

## Autonomous: the whole plan (`/build auto`)

Use this once a spec exists and you want to collapse plan + build into one run. It removes the manual stepping between tasks — **not** the verification. Every task still earns a failing-then-passing test and its own commits.

1. **Require a spec.** Look only for a spec at a known path: `SPEC.md` at the repo root, `docs/SPEC.md`, or a file under `spec/`. A README or arbitrary doc does **not** count. If none exists, stop and tell the user to run `/spec` first — do not invent requirements.

2. **Establish a clean baseline.** Run `git status --porcelain`. If there are uncommitted changes outside the expected planning artifacts (`SPEC.md`, `docs/SPEC.md`, `spec/*`, `tasks/plan.md`, `tasks/todo.md`), stop and ask the user to commit, stash, or confirm how to handle them. Autonomous per-task commits must not absorb unrelated local work, or the clean-rollback guarantee breaks.

3. **Plan if needed.** If there is no `tasks/plan.md`, invoke agent-skills:planning-and-task-breakdown to generate one.

4. **Single checkpoint.** Present the full plan and wait for an unambiguous affirmative (e.g. "approve", "go", "yes"). Treat hedged responses ("looks reasonable", "I guess") as **not** approved. This is the only human gate — after approval, run autonomously. If you generated `tasks/plan.md`, commit it as a single preparatory commit now so it doesn't bleed into the first task's commit.

5. **Execute every task in dependency order.** Use each task's declared dependencies; if they aren't explicit, execute in the order the plan lists them. For each task, run the default loop above (analyst if needed → one test-writer → verify RED → one implementer → handle reports → verify GREEN → mark complete). One test-writer and one implementer per task; resume them for retries and disputes instead of spawning new ones. Independent tasks may run in parallel only when they touch disjoint files.

6. **Stop and ask the user** (do not push through) when:

   - the implementer reports a test it can't make pass or a build it can't fix after one debugging retry → follow agent-skills:debugging-and-error-recovery
   - a test dispute cannot be settled from the acceptance criteria, or a task needs a decision the spec doesn't cover
   - the same agent reports a `BOUNDARY VIOLATION:` twice on one task
   - a task is high-risk or irreversible — auth/permission changes, destructive data migrations, payments, deletions, deploys, anything touching secrets, **or anything you can't undo with `git revert`** → follow agent-skills:doubt-driven-development and get explicit sign-off before continuing

   After the user resolves a blocker, they re-invoke `/build auto` — it resumes from the next pending task.

7. **Summarize at the end:** tasks completed, tests added, commits made (RED/GREEN pairs), disputes arbitrated, and anything skipped, flagged, or left for the user.

If any step fails, follow the agent-skills:debugging-and-error-recovery skill.
