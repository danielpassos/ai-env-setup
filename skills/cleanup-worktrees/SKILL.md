---
name: cleanup-worktrees
description: Use when removing the git worktrees and local branches left behind by the work-issue skill once their PRs have merged. Detects state, verifies safety, then removes. Supports --dry-run and --force.
argument-hint: "[target] [--dry-run] [--force]"
disable-model-invocation: true
---

# cleanup-worktrees

Clean up the worktrees and branches left behind by the `work-issue` skill
once their PRs have been merged on GitHub. The flow is **generic** - never
hardcode issue numbers, branch names, or directories. Detect what's there,
verify safety, then remove.

**Project root:** resolve it with `git rev-parse --show-toplevel`. **Base
branch:** resolve it with
`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name` (fall back
to `main` if `gh` is unavailable); use `origin/<base>` wherever this skill
says "base". Honor a different base only if the user says so.

## Argument

Input: `[<target>] [--dry-run] [--force]` - `<target>` is empty (all), a
worktree path, or a branch name. Split on whitespace; flags may appear in any
position. Strip them before resolving the target.

Resolve the target:

- **Empty** → discover candidates from `git worktree list --porcelain`. By
  default, consider worktrees that match any of:
  - paths under `.agents/worktrees/`;
  - paths under `.claude/worktrees/`;
  - sibling worktrees named `../<repo-name>-work-*`;
  - branches matching `<type>/<issue-number>-<slug>`.
- **A path** that is a worktree (resolves through `git worktree list
  --porcelain`) → process only that worktree.
- **A branch name** → find the worktree currently checked out on that branch
  and process only it. If none matches, attempt branch-only cleanup (skip the
  worktree-removal step).

Flag semantics:

- `--dry-run` → report exactly what would happen and exit. Do not modify any
  state.
- `--force` → in addition to merged worktrees, also clean up worktrees whose
  branch has unique commits ahead of the base (normally skipped). Only use
  when the user has confirmed those commits are intentionally being
  discarded. Never applies to worktrees with **uncommitted** changes - those
  are always skipped regardless of `--force`.

## Per-worktree decision tree

Only clean up worktrees after the PR has been merged by a human reviewer, or
when the user explicitly asks to remove an unmerged one.

For every candidate:

1. **Capture state.** Resolve the worktree's absolute path and the branch
   checked out (the human-readable branch like `feat/42-foo`, not an
   auxiliary `worktree-agent-XXXX` ref), via `git worktree list --porcelain`.

2. **Skip if dirty.** Run `git -C <path> status --porcelain`. If non-empty,
   skip with reason "uncommitted changes" - never remove dirty worktrees,
   even with `--force`. Surface the file list so the user can decide.

3. **Skip if an operation is in progress.** Look for `rebase-apply`,
   `rebase-merge`, `MERGE_HEAD`, `CHERRY_PICK_HEAD` in the worktree's git
   dir (`git -C <path> rev-parse --git-dir`; a linked worktree's `.git` is a
   file, not a directory). If any exist, skip with reason "operation in
   progress".

4. **Determine merge status.** Try in order:

   a. **GitHub PR state.** `gh pr list --state merged --head <branch> --base
      <base> --json number,mergedAt --limit 5`. A non-empty result is the
      strongest signal - it holds whether the PR was merged, squashed, or
      rebased. Record the PR number(s).

   b. **Patch-id fallback.** When GitHub returns nothing (branch never
      pushed, PR closed without merging, or `gh` unavailable), run
      `git cherry origin/<base> <branch>` from the main repo. `+` lines are
      commits whose patch-id is **not** in the base - any of them means the
      branch has unique work and is **not** safely merged. `-` lines are
      equivalents already in the base.

   Treat as merged-and-safe when (a) returns at least one merged PR, OR (b)
   produces zero `+` lines. Otherwise treat as unmerged.

5. **Decide.**

   | merge status            | --force? | action                                                |
   |-------------------------|----------|-------------------------------------------------------|
   | merged-and-safe         | -        | clean up                                              |
   | unmerged with `+` lines | no       | skip (report the count)                               |
   | unmerged with `+` lines | yes      | clean up after a clear warning lists the dropped commits |

6. **Cleanup actions** (skip during `--dry-run`):

   a. `git worktree remove <path>`. If it fails, surface the error and
      continue with the next worktree - do **not** add `--force` to the
      removal automatically.

   b. `git branch -D <branch>`. `-D` is needed because a squash or rebase
      merge leaves the local branch unreachable from the base even though
      its content shipped.

   c. Auxiliary agent branches (e.g. `worktree-agent-*`): delete only ones
      that match a known auxiliary pattern, have no live worktree in
      `git worktree list --porcelain`, and are not checked out anywhere.

## Final sweep

After all candidates are processed (skip the state-changing parts during
`--dry-run`):

1. **Prune.** `git worktree prune` to drop administrative entries whose
   directories vanished.
2. **Orphan auxiliary branches.** List branches matching known auxiliary
   patterns and cross-check against `git worktree list --porcelain`. Any that
   no longer own a worktree are orphans - delete with `git branch -D`.
3. **Fetch + prune remote refs.** `git fetch --prune` so deleted PR branches
   on GitHub stop showing up locally.

## Reporting

Always finish with a summary table covering every worktree found, with
columns `path`, `branch`, `result`, `reason / PR`:

```
.claude/worktrees/agent-ac409e7  docs/64-…    cleaned   PR #72 merged
.claude/worktrees/agent-a88c834  feat/66-…    skipped   uncommitted: src/X.ts
../repo-work-61                  feat/61-…    cleaned   PR #73 merged
```

Then a one-line tally: `cleaned: N | skipped: M | errors: K`. In `--dry-run`
mode the table shows what *would* happen - append `(dry-run)` to the result
column.

## Notes

- Never hardcode an absolute path containing a username.
- Never `--no-verify`, never force-push, never `git reset --hard` outside the
  explicit cleanup actions above.
- If `gh` is not authenticated (`gh auth status` non-zero), fall back to the
  `git cherry` path and note it in one line in the report. Don't start an
  OAuth flow inline.
- A worktree whose branch you can't determine (detached HEAD, unusual
  layout): skip it with reason `unknown branch state` and report - don't
  guess.

## Constraints

- Never delete a worktree, branch, or ref the user did not implicitly
  authorize via this skill's contract.
- Respect `--dry-run` rigorously - emit zero state-changing commands.
- Surface every skip with a one-line reason; never silently ignore a
  worktree.
