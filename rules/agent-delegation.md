## Code work runs in an isolated agent + worktree

Any task that produces code - bug fixes, features, refactors, test changes,
anything that edits source files - runs in **both** a sub-agent **and** an
isolated git worktree. Not one or the other, both. This keeps the main
workspace and the main conversation free for parallel work: the user can
keep a dev server running, start another task, or hand over a second bug to
chase in the same conversation while the delegated work happens on its own
branch.

### Isolation is mandatory for code-producing delegated work

Every code-producing task delegated to a sub-agent must run in its own Git
branch and worktree. The main working tree must stay untouched.

- **Prefer native isolation** if the tool being used offers a built-in way
  to run a delegated task in its own worktree/branch - use it instead of
  managing worktrees by hand.
- **Otherwise, manage the worktree manually:**
  1. Check the repository and main working-tree state without modifying it.
  2. Create one dedicated branch and worktree per delegated task.
  3. Place worktrees outside the main repository directory.
  4. Point the delegated task at the absolute worktree path.
  5. Require all commands, edits, tests, and commits to run inside that
     worktree.
  6. Never assign the same worktree to two concurrent tasks.
  7. Inspect and verify the resulting commit(s) before integrating them.
  8. Remove the worktree only after its changes are committed and
     preserved.
- **If neither is available**, don't delegate code-producing work - only
  read-only investigation may still be delegated.

Delegated work commits only to its own branch. Merging or cherry-picking
into the target branch needs whatever authorization is otherwise required.

### Skip both the worktree and the delegation for

- Settings, dotfiles, `AGENTS.md`/`CLAUDE.md`, other `*.md` docs.
- One-line config tweaks.
- Explicit instructions to work on the current branch / "on main" / locally.

The worktree and delegation overhead is wasted on those tiny edits.

### When a delegated task dies with uncommitted work

If a delegated task crashes, times out, or returns without committing, the
default response is to restart fresh in a newly isolated worktree, not to
point a new task at the orphaned worktree path to "pick up where the last
one left off" - the new task arrives with no memory of the prior run, the
orphaned tree may be half-applied, and inheriting that state usually costs
more than redoing the work cleanly.

The only exception is when explicitly asked to recover the orphaned work
(e.g. "the last run wrote a 600-line refactor, salvage it"). In that case,
read the diff out of the orphaned tree first, then hand it to a fresh
isolated task as context - never resume a new task inside the old worktree.
