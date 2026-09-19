---
name: work-issue
description: Use when picking up one or more issues from a repo's GitHub Project board (a single issue number, a column name, or the default "Next" column) and driving each through board → isolated branch/worktree → TDD → open PR. Agent-agnostic; uses the strongest isolation available.
argument-hint: "[issue-number | column-name]"
---

# work-issue

Pick up work from the current repo's GitHub Project (v2) board and drive it
through to an open PR.

## Board metadata

Never hardcode board IDs. Resolve them for the current repo, in this order:

1. **The project's `AGENTS.md`** - look for the `## GitHub Issue board
   wiring` section (written by `ai-env-setup add-github-issue-rules`). It has
   the project number, owner, Project ID, the Status field ID, and a table of
   Status option IDs.
2. **Runtime discovery** if that section is missing:
   - Resolve `<owner>` with `gh repo view --json owner -q .owner.login`.
   - `gh project list --owner <owner> --format json`, then
     `gh project field-list <number> --owner <owner> --format json`.
   - If more than one board could match, ask which one; don't guess.
   - If the owner has **no** boards, or none that plausibly belongs to this
     repo, stop and tell the user there is no board to work from. Don't
     invent one and don't fall back to working without the board.
   - Suggest running `ai-env-setup add-github-issue-rules` so the next run
     skips discovery.

Match Status columns **by name** (case-insensitive, ignore emoji): `Next`,
`In progress`, `In review`. If the board has no column that fits one of
those, stop and ask - don't invent a mapping.

Get each issue's **project item ID** from
`gh project item-list <number> --owner <owner> --format json --limit 200`
(match on the issue's content number).

**Check the token first.** Before any `gh project` call, confirm `gh auth
status` succeeds and lists the `project` scope. If it doesn't, stop and tell
the user to run `gh auth refresh -s project`; don't start the flow and fail
halfway.

## Argument

Input: `<issue-number> | <column-name> | (empty)`

Resolve the target:

- **Empty** → batch mode against the `Next` column. Work through **every**
  issue in `Next`, **in board order, top to bottom**. Board order = the order
  returned by `gh project item-list` filtered to that status, preserving the
  API's natural order. **Do not sort** by issue number, title, or anything
  else - the user hand-orders the column. If the column is empty, say so and
  stop.
- **Numeric** (e.g. `42`, `#42`) → single-issue mode. Work that exact issue,
  then stop.
- **Non-numeric string** (e.g. `Next`, `Backlog`, `all next`) → batch mode
  against the named column, in board order. Strip filler words (`all`, `the`,
  `column`, `issues`) before matching.

Any `--serial` / `--parallel=N` flags are accepted but ignored. Batch mode is
always serial.

## Execution model

Use the strongest isolation your agent supports:

1. **Native isolated worktree/sub-agent support** - use it when available.
   Each issue runs in its own isolated worktree; every install, build, edit,
   test, commit, push, and PR step happens inside it.
2. **Manual git worktree fallback** - create a dedicated worktree outside the
   repo, from the fresh default branch:

   ```bash
   git fetch origin
   git worktree add ../<repo>-work-<issue-number> -b <type>/<issue-number>-<slug> origin/<default-branch>
   ```

   Resolve `<default-branch>` with
   `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`. Run all
   work inside that worktree.
3. **No isolation available** - stop before editing and tell the user
   code-producing issue work requires isolated worktree support.

- **Single-issue mode:** run the per-issue flow once, report the PR URL.
- **Batch mode:** resolve the full ordered set, then run the per-issue flow
  for each issue **one at a time, in board order**. Finish (PR open + card
  moved to `In review`) before starting the next. Each branch is cut from a
  fresh `origin/<default-branch>` at the moment it starts, so an earlier PR
  that already merged is simply part of the next branch's base.

Do **not** `git checkout` the default branch or disturb the user's
uncommitted work in the main working tree. Leave the worktree in place after
the PR opens (it can be reused for fixups); it gets cleaned up later, after
the PR merges, via the `cleanup-worktrees` skill.

## Per-issue flow

1. **Pick task.** Single-issue mode: confirm the issue body has enough detail
   to act. Batch mode: take the top item from the named column. If the body
   is too thin or the scope is unclear, surface it and ask before coding.
2. **Sync refs.** `git fetch origin`.
3. **Move the issue to `In progress`** on the board (`gh project item-edit
   --project-id <id> --field-id <status-field-id> --id <item-id>
   --single-select-option-id <option-id>`) before any code is written.
4. **Branch in a worktree** (see above). Branch name:
   `<type>/<issue-number>-<short-slug>`, e.g. `feat/42-event-cancel-dm`, where
   `<type>` matches the commit type (`feat`, `fix`, `refactor`, `test`, …).
5. **Do the work - TDD is mandatory.** Failing test first, see it fail for
   the right reason, minimal implementation, then green. Run the project's
   checks and Definition of Done (see `AGENTS.md` / project instructions)
   before committing. If the project has no test setup, say so and ask
   rather than skipping TDD silently.
6. **Reference the issue.** Put `Closes #<issue-number>` in the commit body
   OR the PR description - exactly one of the two, never both (avoids
   double-close events). Follow the project's commit style.
7. **Rebase onto fresh default branch before pushing.** Inside the worktree:
   `git fetch origin && git rebase origin/<default-branch>`. On conflicts,
   stop and surface them - do **not** `git rebase --abort` silently or push
   without rebasing. Re-run the relevant tests after the rebase; only
   continue once it's clean and green.
8. **Push and open the PR** against the default branch, only after step 7
   succeeds (`git push -u origin <branch>`). Title mirrors the commit
   summary. Body has a short summary and a test-plan checklist. Follow the
   user's GitHub writing rules for the body (no hard-wrapped prose, no
   escaped backticks in heredocs).
9. **Move the issue to `In review`** on the board immediately after the PR
   opens.

## PR boundary

The finish line is an open PR and the card moved to `In review`.

Never, unless the user explicitly asks after human review/merge:

- merge the PR;
- mark the issue `Done`;
- delete the remote branch;
- remove the worktree;
- prune the local branch.

## Notes

- With `Closes #N` in the PR body, GitHub moves the issue to `Done` when a
  human merges it - don't move the column manually.
- Never force-push the default branch. In the standard flow the first push
  happens in step 8, after the rebase, so a plain `git push -u origin
  <branch>` is enough; only a branch pushed *before* a rebase needs
  `--force-with-lease`.
- Open the PR **only after** step 7's rebase succeeds. If the rebase fails or
  tests regress after it, fix that first - never open a PR on a stale base.
- In batch mode, if a step fails (test failure, rebase conflict, missing
  context), stop and report progress. Do **not** silently skip an item -
  surface the blocker and let the user decide whether to continue.

## Constraints

- One logical change per commit; one PR per issue.
- Never `git add -A` / `git add .` - stage specific files.
- Never commit with failing tests, type errors, or a broken build.
