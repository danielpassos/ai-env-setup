# Per-project GitHub Issues/Projects rules

## Problem

`docs/superpowers/specs/2026-09-18-global-rules-library-design.md` deliberately
excluded the GitHub Issues/Projects workflow content (issue filing rules,
writing style, priority/size Project fields, the `gh` two-step
create+add-to-board pattern) from the shared `rules/` library, because part
of it embeds one specific GitHub Projects (v2) board's IDs (Project ID,
Status/Priority/Size field IDs, column/priority/size option IDs). Those IDs
are not universal - confirmed live against Daniel's own boards
(`gh project list --owner danielpassos`) that even the same owner has
multiple, similarly-named boards (two both titled "Moorea", at `/projects/1`
and `/projects/4`), and Daniel confirmed no assumption should be made that
one board applies to every project - each repo may have its own board, or
none.

This design covers that deferred piece: a new `ai-env-setup` subcommand,
run from inside a specific target project's repo, that discovers that
repo's actual GitHub Projects board via `gh` and writes the board-specific
rules - with real, freshly-fetched IDs - into that project's own
`AGENTS.md`. It does not touch this repo's own machine-wide distribution
mechanism.

## Scope

**In scope:**
- A new `rules/github-issue-style.md` file in the existing global rules
  library (see prior spec) for the parts of the original example that are
  universal - true for any project using `gh issue create`, whether or not
  it has a Projects board.
- A new `ai-env-setup add-github-issue-rules` subcommand that discovers a target
  repo's GitHub Projects board (owner + project number, Status/Priority/Size
  fields and their option IDs) live via `gh`, and writes/refreshes a
  clearly-marked, board-specific block into that repo's own `AGENTS.md`.

**Explicitly out of scope:**
- Any change to how boards are structured on GitHub itself (creating
  columns/fields) - this only reads.
- Supporting non-`gh`-shaped project trackers (Linear, Jira, etc.) - `gh
  project` (GitHub Projects v2) only.
- Cursor - still deferred from the prior design, unrelated to this one.

**Revised after initial implementation:** the first version of this design
excluded creating `CLAUDE.md` in the target project, reasoning that was "a
separate, existing concern for that project." That was wrong in practice -
Claude Code reads `CLAUDE.md`, not `AGENTS.md`, so a target project with no
`CLAUDE.md` (or one that doesn't import `AGENTS.md`) would never actually
see the rules this subcommand writes. `github_rules::run` now also calls
`github_rules::_ensure_claude_import`: creates `./CLAUDE.md` with an
`@AGENTS.md` import if it doesn't exist yet (same convention this repo's
own root `CLAUDE.md` uses); if `CLAUDE.md` already exists, it's never
overwritten - only a warning is logged when it doesn't already import
`AGENTS.md`.

## Design

### Content split (resolves the ambiguity raised mid-review)

Walking the original example line by line:

**Universal → `rules/github-issue-style.md`** (no board dependency, works
for any project, gets distributed exactly like the other four `rules/*.md`
files via the existing `expand`/`concat` link modes):
- "Markdown in HEREDOC bodies - never escape backticks."
- "Never hard-wrap prose in issue/PR/comment bodies."
- The issue-writing-style shape (What can go wrong / Example / Why this
  matters / Where this seems to happen / Expected behavior / Fix idea) and
  the guidance to avoid technical/implementation-detail phrasing in titles.
- "Issue title format reminder: plain language, never commit-style
  prefixes."

**Board-specific → generated per-project block** (everything that
mentions a board, a column, Priority, Size, or any ID):
- The mandate to add every filed issue to the project board and assign a
  column, plus default-column-by-intent behavior.
- The `bug` label + Priority (Urgent/High) heuristic.
- The Size heuristic.
- The two-step `gh issue create` → `gh project item-add` → `gh project
  item-edit` pattern, with that board's real Project ID and field IDs
  substituted in.
- The column/priority/size option-ID tables, freshly fetched (not a stale
  hand-copied snapshot).

### `ai-env-setup add-github-issue-rules`

**Invocation:** run from inside the target project's repo (or pass
`--owner`/`--project` to skip auto-detection/interactive pick, e.g. for
testing or scripting):

```
ai-env-setup add-github-issue-rules [--owner <login>] [--project <number>]
```

**Flow:**

1. **Preflight:** `require_cmd gh`. Verify auth: `gh auth status` must
   succeed; if the response indicates the `project` scope is missing, fail
   with a clear message pointing at `gh auth refresh -s project` (matching
   the scope note in `gh project --help`).
2. **Resolve owner:** if `--owner` wasn't given, run `gh repo view --json
   owner -q .owner.login` in the current directory. Fail clearly if the
   current directory isn't a GitHub-backed git repo.
3. **Resolve project:** if `--project` wasn't given, run `gh project list
   --owner <owner> --format json`, present the results (title + number +
   URL, since titles alone aren't unique - confirmed live) via `gum choose`
   for a single pick, `label:id`-style like the rest of this repo's
   pickers. Fail clearly if the owner has zero projects.
4. **Fetch fields:** `gh project field-list <number> --owner <owner>
   --format json`. Parse with `yq -p json` (no new `jq` dependency - `yq`
   already handles JSON, matching this repo's existing tooling). Look for
   single-select fields named exactly `Status`, `Priority`, and `Size`;
   each is independently optional - a board missing one of them just
   omits that field's section from the generated block, rather than
   erroring.
5. **Render the block:** build the board-specific markdown (mandate +
   whichever of Status/Priority/Size sections were found + the two-step
   `gh` command block with real IDs + the ID tables), wrapped between
   marker comments:
   ```
   <!-- ai-env-setup:github-issues:start -->
   ...board-specific content...
   <!-- ai-env-setup:github-issues:end -->
   ```
6. **Write it:** upsert that block into `<cwd>/AGENTS.md`:
   - File doesn't exist → create it containing just the block.
   - File exists, markers present → replace only the content between the
     markers (preserves everything else in the file).
   - File exists, markers absent → append the block at the end.
   - Idempotent: if the computed block is byte-identical to what's already
     between the markers, no write happens (`up to date`).

**New file:** `bin/lib/github_rules.sh`, sourced from `bin/setup.sh`
alongside the other `bin/lib/*.sh` modules, functions namespaced
`github_rules::*` (consistent with `tools::`, `skills::`, `mcp::`,
`plugins::`, `picker::`).

**Dispatch:** `bin/setup.sh`'s `main()` gets a short-circuit at the top:

```bash
main() {
  if [[ "${1:-}" == "add-github-issue-rules" ]]; then
    shift
    github_rules::run "$@"
    exit $?
  fi

  ensure_macos
  ...
}
```

`add-github-issue-rules` never runs the brew/tool-selection/skills/plugins/MCP
flow - it's a standalone action scoped to the current directory.

### Idempotency / refresh

Re-running `add-github-issue-rules` in the same project re-fetches live from
`gh` and replaces only the marked block - this is the fix for the original
problem (a hand-copied ID snapshot going stale, like the "Refined" column
that existed on the real board but wasn't in the example doc). Everything
else in the target project's `AGENTS.md` is left untouched.

### Testing

Because this subcommand discovers real data via `gh` and writes into an
arbitrary target directory's `AGENTS.md`, testing must not touch any of
Daniel's actual project repos:

- Use a scratch temp directory as the "target project." For the
  owner-auto-detection path specifically, `git init` it and `git remote add
  origin git@github.com:danielpassos/ai-env-setup.git` (a real,
  `gh`-accessible repo) so `gh repo view` resolves a real owner without
  requiring the scratch dir to literally be that repo, or any real
  project's files to be touched.
- Exercise the fully non-interactive path with `--owner danielpassos
  --project 1` (a real board, confirmed live during this design) against a
  plain scratch directory (no git needed at all when both flags are given).
- Verify: `AGENTS.md` is created with the marker block; the block contains
  real IDs matching what `gh project field-list 1 --owner danielpassos
  --format json` returns; re-running is a no-op (`up to date`); editing
  unrelated content elsewhere in the scratch `AGENTS.md` and re-running
  preserves it and only replaces the marked block; deleting the markers by
  hand and re-running appends rather than duplicating.

### Non-goals

- No new interactive picker persistence/state file for the chosen project -
  each run either takes `--project` or asks fresh. (Revisit only if
  re-asking every time turns out to be annoying in practice.)
- No support for boards whose Status/Priority/Size fields use different
  names - detection is by exact field name for now.
