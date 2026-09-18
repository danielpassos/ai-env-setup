# Global rules library (Claude Code + Codex)

## Problem

Daniel currently hand-copies a handful of behavioral rules (commit
attribution, commit conventions, agent/worktree isolation, recoverable-error
retry policy, ...) into every new project's `AGENTS.md`/`CLAUDE.md`, and
re-edits them per project. Some of that content is genuinely universal
(applies to every project he works on, regardless of tool), and belongs in
one versioned place instead of being re-pasted and drifting.

This repo (`ai-env-setup`) already keeps machine-level AI tooling config
identical across machines via `manifest/*.yaml` + `bin/setup.sh`. This design
extends that same idea to a **global rules library**: content lives once in
this repo, and `bin/setup.sh` projects it into each supported tool's
user-level (not project-level) instruction mechanism.

## Scope

**In scope:** Claude Code, Codex CLI.

**Explicitly out of scope for this round:** Cursor. Cursor's global "User
Rules" are not backed by a plain file — they live in an internal SQLite store
(`state.vscdb`) or, in current versions, are synced to the cloud. There is no
stable filesystem path this repo can symlink or write to. Project-level
`.cursor/rules/*.mdc` exists, but that's per-project, which is out of scope
by Daniel's explicit direction (this feature targets global config, not
per-project scaffolding). Cursor matters to Daniel (used at work) and will
get its own follow-up brainstorm/design immediately after this one ships,
rather than being bundled into this spec.

**Explicitly out of scope for the content itself:** anything that isn't
truly universal across all of Daniel's projects. Two things were identified
and deliberately excluded from the shared library:
- The specific commit `scope` taxonomy (`bot`, `web`, `core`, `api`) from the
  example project — only the generic conventional-commits skeleton is
  universal.
- The GitHub Issues/Projects workflow (board URL, Project ID, field IDs,
  option IDs) — not universal (not every project has a GitHub Projects
  board) and carries per-project IDs. Deferred; revisit later as a
  separate, parameterized mechanism if it's worth solving.

## Design

### Content library: `rules/`

A new top-level directory, sibling to `skills/`, holding one markdown file
per topic. Content is written tool-agnostically — no tool-specific tool-call
syntax (e.g. no literal `Agent({ isolation: "worktree" })` snippets), since
the same files are projected into both Claude Code and Codex CLI verbatim.

Initial files, derived from the three examples reviewed in this design's
brainstorm:

- `rules/commit-attribution.md` — no AI co-author trailers/footers in
  commits, PRs, issues, or comments.
- `rules/commit-conventions.md` — generic conventional-commits skeleton:
  `type(scope): description` format, subject line ≤70 chars, one logical
  change per commit, never commit with failing tests, `git add` specific
  files (never `-A`/`.`). No project-specific scope list.
- `rules/agent-delegation.md` — code-producing work should run in an
  isolated agent + git worktree, described conceptually (native isolation
  when the tool offers it, manual `git worktree` fallback otherwise, skip
  both for trivial edits), plus the "restart fresh rather than resume an
  orphaned worktree" guidance. No Claude-specific tool-call syntax.
- `rules/tool-error-retry.md` — retry recoverable tool errors (up to 3
  attempts) before surfacing to the user; stop and surface immediately for
  destructive ops, permission denials, or novel errors.

Each file is self-contained prose/markdown, documented well enough to stand
alone (per Daniel's explicit ask), and grouped one-topic-per-file so it's
easy to add, edit, or drop a single rule without touching the others.

### Delivery: Claude Code

Claude Code has a native mechanism for exactly this: `~/.claude/rules/`,
loaded at the start of every session, for every project, one file per topic
(confirmed against Claude Code's own docs). This repo already has a
`expand: true` link mode (used today for `skills/`) that symlinks each child
of a source directory individually into the target directory — no code
change needed.

`manifest/tools.yaml` gains one new link entry under the existing `claude`
tool:

```yaml
- id: claude
  links:
    - source: "config/claude/CLAUDE.md"
      target: "CLAUDE.md"
    - source: "skills"
      target: "skills"
      expand: true
    - source: "rules"
      target: "rules"
      expand: true
```

This symlinks `rules/commit-attribution.md` → `~/.claude/rules/commit-attribution.md`,
etc.

### Delivery: Codex CLI

Codex CLI has no directory-of-topics equivalent — it reads a single global
`~/.codex/AGENTS.md` (plain markdown, no `@import` syntax, concatenated with
every `AGENTS.md` up the project path, capped at 32 KiB; global content
should stay small, well under that cap). To reuse the same per-topic source
files without hand-duplicating their content into one file, `bin/lib/links.sh`
gains a new link mode: `concat: true`.

`manifest/tools.yaml` gains one new link entry under the existing `codex`
tool:

```yaml
- id: codex
  links:
    - source: "rules"
      target: "AGENTS.md"
      concat: true
```

Behavior of `concat: true` in `tools::sync_links` (`bin/lib/links.sh`):

1. Collect the files directly under `source`, sorted alphabetically by
   filename (deterministic order; no manual ordering config for now — file
   naming controls order if it ever matters).
2. Concatenate their contents, separated by a blank line, into a single
   generated file, prefixed with a marker comment, e.g.:
   ```
   <!-- Generated by ai-env-setup from rules/*.md — do not edit directly. -->
   ```
3. Write the result to `target` (e.g. `~/.codex/AGENTS.md`) — a real file,
   not a symlink, since Codex needs one physical file at that path (and
   this path may need to coexist with content Codex or the user adds later
   outside this mechanism).
4. Idempotency / drift handling: this reuses the existing backup-on-drift
   posture rather than inventing a second one — write only if the computed
   content differs from what's on disk, and if the existing file lacks the
   generated-file marker (i.e. was hand-edited or pre-existing), back it up
   first the same way `backup_and_symlink` already backs up pre-existing
   files before replacing them, rather than silently clobbering it.

### Testing

- `AI_ENV_SETUP_TOOLS=claude,codex ./bin/setup.sh` (per this repo's existing
  non-interactive test path).
- Verify `~/.claude/rules/*.md` are symlinks pointing back into the repo's
  `rules/` directory.
- Verify `~/.codex/AGENTS.md` contains all four rule files' content,
  concatenated, under the marker comment.
- Re-run and confirm both are no-ops (no unnecessary writes/backups) when
  nothing changed.
- Edit one `rules/*.md` file and re-run; confirm the Codex file regenerates
  and the Claude Code symlink needs no action (it's already pointing at the
  updated source).
- Manually edit `~/.codex/AGENTS.md` by hand, re-run, and confirm the tool
  backs it up before overwriting (drift-detection path).

### Non-goals

- No new interactive picker for individual rules — the whole `rules/`
  library is universal-by-definition (that's the scope filter applied
  during this design), so every selected tool gets the whole set, same as
  `config/claude/CLAUDE.md` today.
- No solution for the GitHub Issues/Projects workflow or other
  project-specific/parameterized content — explicitly deferred.
- No Cursor support — explicitly deferred to a follow-up design.
