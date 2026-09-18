# Global Rules Library (Claude Code + Codex) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. (Note: superpowers:subagent-driven-development is not installed in this environment's skill set — use inline execution.)

**Goal:** Let Daniel maintain universal AGENTS.md/CLAUDE.md-style rules (commit attribution, commit conventions, agent/worktree isolation, tool-error retry) once in this repo, and have `bin/setup.sh` project them into Claude Code's `~/.claude/rules/` and a generated `~/.codex/AGENTS.md`, instead of hand-copying them into every project.

**Architecture:** A new top-level `rules/` directory holds one markdown file per topic, written tool-agnostically. `manifest/tools.yaml` gains a link entry per tool: Claude Code reuses the existing `expand: true` symlink mode to link each file individually into `~/.claude/rules/`; Codex CLI needs a new `concat: true` link mode (added to `bin/lib/links.sh`) that concatenates all of `rules/*.md` into one generated `~/.codex/AGENTS.md`, since Codex only reads a single global file.

**Tech Stack:** Bash 3.2 (macOS `/bin/bash`), `yq`, existing `bin/lib/*.sh` helpers. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-18-global-rules-library-design.md`

## Global Constraints

- macOS `/bin/bash` is 3.2 — no associative arrays, and any array that might be empty must be guarded with `[[ "${#arr[@]}" -gt 0 ]]` before `"${arr[@]}"`/`"${arr[*]}"` expansion (unbound variable under `set -u` otherwise).
- Content in `rules/*.md` must be tool-agnostic: no Claude Code-specific tool-call syntax (e.g. `Agent({...})`, `subagent_type`) or Claude Code-specific tool names (e.g. "the Edit tool", "the Bash tool") — the same files are projected verbatim into both Claude Code and Codex.
- No project-specific content in `rules/*.md` (e.g. no fixed commit-scope taxonomy, no GitHub Projects IDs) — only what's genuinely universal across every project.
- Follow this repo's existing conventions: `source` paths in `manifest/tools.yaml` are relative to the repo root; new link modes must not break `expand`'s existing behavior; `run_quiet`/`log_*`/`die` from `bin/lib/common.sh` are the standard logging/error idiom.
- This repo is safe to re-run any time — every new mechanism must be idempotent (a second run with no changes produces no writes/backups).

---

## Task 1: Content library — `rules/` directory

**Files:**
- Create: `rules/commit-attribution.md`
- Create: `rules/commit-conventions.md`
- Create: `rules/agent-delegation.md`
- Create: `rules/tool-error-retry.md`

**Interfaces:**
- Consumes: nothing (pure content).
- Produces: a directory `rules/` at the repo root containing exactly these four `.md` files, consumed by Task 3/4's link entries as the `source` for both the Claude Code `expand` link and the Codex `concat` link.

- [ ] **Step 1: Create `rules/commit-attribution.md`**

```markdown
## Commit attribution

Do not add AI co-author trailers or generated-by footers to commits, PRs,
issues, or comments.

Forbidden examples:

- `Co-Authored-By: Claude <noreply@anthropic.com>`
- `Co-Authored-By: ChatGPT <...>`
- `Generated with Claude Code`
- `🤖 Generated with ...`

Commits should be authored only by the configured local Git user unless the
human explicitly asks otherwise.
```

- [ ] **Step 2: Create `rules/commit-conventions.md`**

```markdown
## Commit conventions

Commit format: `type(scope): description`

- Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
- Scope: name it after the part of the codebase the commit touches (e.g. a
  package, app, or module). The exact scope list is project-specific -
  infer it from the project's existing commit history rather than
  inventing one.

Rules:

- **Subject line ≤ 70 characters.** GitHub's web UI truncates anything past
  ~72 characters with an ellipsis on every list view (history, PRs, blame,
  search). If `type(scope): description` doesn't fit, shorten the
  description, drop the scope, or split the change.
- One logical change per commit.
- Never commit with failing tests or a broken build/type-check.
- `git add` specific files - never `git add -A` or `git add .`.
```

- [ ] **Step 3: Create `rules/agent-delegation.md`**

```markdown
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
```

- [ ] **Step 4: Create `rules/tool-error-retry.md`**

```markdown
## Recoverable errors - retry, don't stop

When a tool call fails mid-task with a recoverable error, retry it up to
**3 times** in the same turn after fixing the obvious cause, before
surfacing it to the user. Surfacing should be the last resort, not the
first reaction - the goal is to finish the task without forcing the user to
hand-hold every minor hiccup.

A "recoverable error" is one with a clear, mechanical fix, including:

- A file-edit tool refuses because the file hasn't been read yet - read the
  file first, then retry the edit.
- A file-edit tool reports its target text isn't unique / not found -
  re-read the surrounding context, expand the match until it's unique,
  retry.
- A shell command hits a transient network failure (DNS, ECONNRESET, fetch
  timeout, a CLI's rate limit) - wait briefly and retry, up to 3 attempts.
  Don't loop on a hard 4xx/5xx that won't change.
- `gh pr create` fails because the branch isn't pushed yet - push, retry.
- `git push` fails because the remote moved - `git fetch && git pull
  --rebase` on the working branch (NOT main), retry. If the working branch
  is in fact the main branch, surface instead - don't auto-rebase shared
  history.
- A type-check or lint fails on a typo just introduced - fix the typo,
  retry.
- A test fails because a mock doesn't include a field just added to a
  type - extend the mock, retry.

Stop and surface (don't retry blindly) when:

- The error is a real semantic bug in the code that was written - fix the
  code, not the call.
- A destructive operation fails (`rm`, `git reset --hard`, force-push,
  etc.) - the user must decide.
- A permission prompt denies the call - adjusting permissions is the user's
  call.
- 3 retries have already been spent.
- The error message is novel with no confident mechanical fix.

Track the retry count silently per error. Don't narrate every retry - just
do the work. Mention the retry only when surfacing the final failure, or
when the fix is non-obvious enough that it's worth flagging.
```

- [ ] **Step 5: Verify no tool-specific leakage**

Run:
```bash
grep -riE 'Agent\(|subagent_type|typescript|claude code|codex cli' rules/
```
Expected: no output (exit status 1). If anything matches, reword that file to remove the tool-specific reference before continuing.

- [ ] **Step 6: Commit**

```bash
git add rules/commit-attribution.md rules/commit-conventions.md rules/agent-delegation.md rules/tool-error-retry.md
git commit -m "Add rules/ - universal, tool-agnostic AGENTS.md/CLAUDE.md content"
```

---

## Task 2: `write_generated_file` helper in `bin/lib/common.sh`

**Files:**
- Modify: `bin/lib/common.sh` (append after `backup_and_symlink`)

**Interfaces:**
- Consumes: nothing new (uses existing `log_success`, `log_warn` from the same file).
- Produces: `write_generated_file CONTENT TARGET_MARKER TARGET` — a function callable from `bin/lib/links.sh`'s Task 3 concat mode. Contract:
  - `CONTENT`: the full file content to write (marker line already included by the caller).
  - `MARKER_PREFIX`: the literal string every generated file's first line must start with, used to detect "this file was generated by us last time" vs. "this is something else."
  - `TARGET`: absolute path to write to.
  - Idempotent: a second call with identical `CONTENT` and `TARGET` is a no-op (logs `up to date`, no write).
  - If `TARGET` exists, isn't identical, and its first line does **not** start with `MARKER_PREFIX` (i.e. it's hand-edited or pre-existing, not one of ours), back it up to `TARGET.bak` once, same posture as `backup_and_symlink` (never overwrites an existing `.bak`).
  - If `TARGET`'s first line **does** start with `MARKER_PREFIX` (we generated it last time), overwrite without backing up.

- [ ] **Step 1: Add the function**

Append to `bin/lib/common.sh`, directly after the existing `backup_and_symlink` function:

```bash

# write_generated_file CONTENT MARKER_PREFIX TARGET
# Idempotently writes CONTENT to TARGET. TARGET's first line is expected to
# start with MARKER_PREFIX when TARGET was generated by us on a previous
# run - in that case a differing TARGET is overwritten without a backup.
# Otherwise (TARGET exists and doesn't start with MARKER_PREFIX - hand-edited
# or pre-existing) it's moved aside to TARGET.bak once, mirroring
# backup_and_symlink's posture (an existing .bak is never overwritten).
write_generated_file() {
  local content="$1" marker_prefix="$2" target="$3"

  if [[ -f "$target" ]] && [[ "$(cat "$target")" == "$content" ]]; then
    log_success "up to date: $target"
    return 0
  fi

  mkdir -p "$(dirname "$target")"

  if [[ -e "$target" || -L "$target" ]]; then
    if [[ "$(head -n1 "$target" 2>/dev/null)" == "$marker_prefix"* ]]; then
      : # previously generated by us - safe to overwrite without backup
    elif [[ -e "$target.bak" ]]; then
      log_warn "$target already backed up, leaving $target.bak as-is"
    else
      mv "$target" "$target.bak"
      log_warn "backed up existing $target -> $target.bak"
    fi
  fi

  printf '%s\n' "$content" >"$target"
  log_success "generated: $target"
}
```

- [ ] **Step 2: Manually verify idempotency and backup behavior**

Run (uses a scratch temp dir, not any real config):
```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
source bin/lib/common.sh
tmp="$(mktemp -d)"

# 1. First write: expect "generated"
write_generated_file "MARK
hello" "MARK" "$tmp/out.txt"
cat "$tmp/out.txt"   # expect: MARK\nhello

# 2. Same content again: expect "up to date", no .bak created
write_generated_file "MARK
hello" "MARK" "$tmp/out.txt"
[[ -e "$tmp/out.txt.bak" ]] && echo "FAIL: unexpected .bak" || echo "OK: no .bak"

# 3. Different content, marker still present: expect overwrite, still no .bak
write_generated_file "MARK
changed" "MARK" "$tmp/out.txt"
cat "$tmp/out.txt"   # expect: MARK\nchanged
[[ -e "$tmp/out.txt.bak" ]] && echo "FAIL: unexpected .bak" || echo "OK: no .bak"

# 4. Hand-edit the file so it no longer starts with MARK, then write again:
# expect a .bak of the hand-edited content
printf 'hand-edited, no marker\n' > "$tmp/out.txt"
write_generated_file "MARK
new" "MARK" "$tmp/out.txt"
cat "$tmp/out.txt"        # expect: MARK\nnew
cat "$tmp/out.txt.bak"    # expect: hand-edited, no marker

rm -rf "$tmp"
```
Expected: each labeled expectation matches; no `FAIL` lines printed.

- [ ] **Step 3: Commit**

```bash
git add bin/lib/common.sh
git commit -m "Add write_generated_file helper for single-file generated configs"
```

---

## Task 3: `concat: true` link mode in `bin/lib/links.sh`

**Files:**
- Modify: `bin/lib/links.sh`

**Interfaces:**
- Consumes: `write_generated_file(content, marker_prefix, target)` from Task 2.
- Produces: `tools::sync_links` (existing function, called by `bin/setup.sh` per selected tool) now also honors a `concat: true` field on a `manifest/tools.yaml` link entry, alongside the existing `expand: true`. Also produces an internal helper `links::_concat SOURCE_DIR TARGET` used only within this file.

- [ ] **Step 1: Read the current file to confirm line numbers before editing**

`bin/lib/links.sh` currently reads (for reference — do not skip re-reading the live file before editing, in case it drifted):

```bash
tools::sync_links() {
  local id="$1"
  local home count
  home="$(tools::home "$id")"
  count="$(tools::field_or_empty "$id" '.links | length')"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    log_info "$(tools::name "$id"): no config links declared, skipping"
    return 0
  fi

  local i src_rel tgt_rel expand src tgt entry
  for ((i = 0; i < count; i++)); do
    src_rel="$(tools::field_or_empty "$id" ".links[$i].source")"
    tgt_rel="$(tools::field_or_empty "$id" ".links[$i].target")"
    expand="$(tools::field_or_empty "$id" ".links[$i].expand")"

    src="$AI_ENV_SETUP_HOME/$src_rel"
    tgt="$home/$tgt_rel"

    [[ -e "$src" ]] || die "$(tools::name "$id"): link source missing at $src"

    if [[ "$expand" == "true" ]]; then
      for entry in "$src"/*; do
        [[ -e "$entry" ]] || continue
        backup_and_symlink "$entry" "$tgt/$(basename "$entry")"
      done
    else
      backup_and_symlink "$src" "$tgt"
    fi
  done
}
```

- [ ] **Step 2: Add the `links::_concat` helper and wire `concat` into `tools::sync_links`**

Replace the whole `tools::sync_links` function body with:

```bash
# links::_concat SOURCE_DIR TARGET
# Concatenates every file directly under SOURCE_DIR (bash glob order, which
# is alphabetical by filename) into a single generated TARGET file, via
# write_generated_file. Used by tools whose global instructions file has no
# directory-of-topics equivalent (e.g. Codex CLI's single ~/.codex/AGENTS.md),
# to reuse the same per-topic source files another tool symlinks individually.
links::_concat() {
  local src_dir="$1" target="$2"
  local marker="<!-- Generated by ai-env-setup from ${src_dir#"$AI_ENV_SETUP_HOME"/}/*.md - do not edit directly. -->"

  local entries=() entry
  for entry in "$src_dir"/*; do
    [[ -e "$entry" ]] || continue
    entries+=("$entry")
  done

  if [[ "${#entries[@]}" -eq 0 ]]; then
    log_info "no files under $src_dir to concatenate, skipping $target"
    return 0
  fi

  local content="$marker"
  for entry in "${entries[@]}"; do
    content+=$'\n\n'"$(cat "$entry")"
  done

  write_generated_file "$content" "$marker" "$target"
}

tools::sync_links() {
  local id="$1"
  local home count
  home="$(tools::home "$id")"
  count="$(tools::field_or_empty "$id" '.links | length')"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    log_info "$(tools::name "$id"): no config links declared, skipping"
    return 0
  fi

  local i src_rel tgt_rel expand concat src tgt entry
  for ((i = 0; i < count; i++)); do
    src_rel="$(tools::field_or_empty "$id" ".links[$i].source")"
    tgt_rel="$(tools::field_or_empty "$id" ".links[$i].target")"
    expand="$(tools::field_or_empty "$id" ".links[$i].expand")"
    concat="$(tools::field_or_empty "$id" ".links[$i].concat")"

    src="$AI_ENV_SETUP_HOME/$src_rel"
    tgt="$home/$tgt_rel"

    [[ -e "$src" ]] || die "$(tools::name "$id"): link source missing at $src"

    if [[ "$expand" == "true" ]]; then
      for entry in "$src"/*; do
        [[ -e "$entry" ]] || continue
        backup_and_symlink "$entry" "$tgt/$(basename "$entry")"
      done
    elif [[ "$concat" == "true" ]]; then
      links::_concat "$src" "$tgt"
    else
      backup_and_symlink "$src" "$tgt"
    fi
  done
}
```

- [ ] **Step 3: Manually verify `links::_concat` in isolation, against a scratch fixture (not real tools.yaml yet)**

Run:
```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
source bin/lib/common.sh
source bin/lib/tools.sh
source bin/lib/links.sh

fixture="$(mktemp -d)/rules"
mkdir -p "$fixture"
printf 'first file\n' > "$fixture/a.md"
printf 'second file\n' > "$fixture/b.md"
out="$(mktemp -d)/AGENTS.md"

links::_concat "$fixture" "$out"
cat "$out"
# Expected: marker line, blank line, "first file", blank line, "second file"

# Re-run with no changes: expect "up to date", no .bak
links::_concat "$fixture" "$out"

# Hand-edit target, re-run: expect a .bak of the hand-edited content
printf 'hand edit\n' > "$out"
links::_concat "$fixture" "$out"
cat "$out"       # expect: marker + first file + second file again
cat "$out.bak"   # expect: hand edit
```
Expected: output matches each comment; no errors.

- [ ] **Step 4: Commit**

```bash
git add bin/lib/links.sh
git commit -m "Add concat link mode for tools with a single global instructions file"
```

---

## Task 4: Wire `manifest/tools.yaml` and document the new mechanism

**Files:**
- Modify: `manifest/tools.yaml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `rules/` (Task 1), the `concat` field now read by `tools::sync_links` (Task 3).
- Produces: the actual manifest entries `bin/setup.sh` reads when a user selects `claude` and/or `codex`.

- [ ] **Step 1: Add the `claude` rules link**

In `manifest/tools.yaml`, under the `claude` tool's `links:`, add a third entry after the existing `skills` one:

```yaml
      - source: "rules"
        target: "rules"
        expand: true
```

So the full `claude` entry's `links:` block reads:

```yaml
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

- [ ] **Step 2: Add the `codex` rules link**

In `manifest/tools.yaml`, under the `codex` tool's `links:`, add:

```yaml
      - source: "rules"
        target: "AGENTS.md"
        concat: true
```

So the full `codex` entry's `links:` block reads:

```yaml
    links:
      - source: "skills"
        target: "skills"
        expand: true
      - source: "rules"
        target: "AGENTS.md"
        concat: true
```

- [ ] **Step 3: Update the top-of-file comment block in `manifest/tools.yaml`**

The file's header comment currently documents `expand: true` but not a second mode. Update it to also mention `concat`:

```yaml
# Registry of AI tools ai-env-setup can install and configure.
# Adding a tool = adding an entry here. No code changes required.
#
# install.method: npm | brew_cask | brew_formula | none (installed manually)
# links: source is a path relative to the repo root, symlinked to
#   <home>/<target>. Use config/<id>/... for config specific to one tool, or
#   a shared root path (e.g. skills/, rules/) for things multiple tools can
#   reuse.
#   expand: true syncs each child of source as its own symlink instead of
#   the whole directory (used for skills/, where you want each item
#   individually backed-up/linked rather than the whole folder as one unit).
#   concat: true concatenates every child of source into one generated file
#   at target instead of symlinking (used for rules/ -> Codex's single
#   global AGENTS.md, which has no directory-of-topics equivalent). Mutually
#   exclusive with expand.
# skills_agent: this tool's agent id in the `skills` CLI (manifest/skills.yaml's
#   `only` field), if different from this tool's own id. Omit when they match.
```

- [ ] **Step 4: Update `README.md`'s Layout section**

In the `## Layout` code block, after the `skills/<name>/` line, add:

```
rules/<topic>.md              # universal, tool-agnostic rules shared across every project - see "Adding a universal rule"
```

- [ ] **Step 5: Add a "Adding a universal rule" section to `README.md`**

Insert a new section after `## Adding a skill` (before `## Adding an external skill package`):

```markdown
## Adding a universal rule

`rules/<topic>.md` holds a behavioral rule that's genuinely universal - true
for every project, not tied to one project's IDs or conventions, and worded
without any one tool's specific syntax (no literal tool-call snippets, no
"the Edit tool" style references). Each file is one topic.

Link it into whichever tools should receive it, in `manifest/tools.yaml`:

- A tool with a directory-of-topics instructions mechanism (like Claude
  Code's `~/.claude/rules/`) uses `expand: true`, same as `skills/` - each
  file becomes its own symlink.
- A tool with a single global instructions file (like Codex CLI's
  `~/.codex/AGENTS.md`) uses `concat: true` - every file under `rules/` is
  concatenated into one generated file, marked at the top as
  generated-do-not-edit. Hand-editing that generated file gets it backed up
  to `<target>.bak` on the next run rather than silently overwritten.

Project-specific content (fixed IDs, a project's own commit-scope list,
etc.) does **not** belong in `rules/` - keep that in the project's own
`AGENTS.md`/`CLAUDE.md` instead.
```

- [ ] **Step 6: Commit**

```bash
git add manifest/tools.yaml README.md
git commit -m "Wire rules/ into Claude Code and Codex CLI via manifest/tools.yaml"
```

---

## Task 5: End-to-end verification (real machine) and wrap-up

**Files:** none (verification only; this repo already manages this machine's real `~/.claude` and `~/.codex`, and re-running it is this repo's normal, documented, idempotent usage — see `AGENTS.md`'s "Testing without the interactive picker" section).

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: nothing new — confirms the whole chain works together on the real target paths.

- [ ] **Step 1: Run setup for `claude` and `codex` only**

```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
AI_ENV_SETUP_TOOLS=claude,codex ./bin/setup.sh
```
Expected: no errors; log lines show `linked:` for each `~/.claude/rules/*.md` and `generated:` for `~/.codex/AGENTS.md`.

- [ ] **Step 2: Verify the Claude Code side**

```bash
ls -la ~/.claude/rules/
readlink ~/.claude/rules/commit-attribution.md
```
Expected: four symlinks (`commit-attribution.md`, `commit-conventions.md`, `agent-delegation.md`, `tool-error-retry.md`), each resolving into this repo's `rules/` directory.

- [ ] **Step 3: Verify the Codex side**

```bash
head -n1 ~/.codex/AGENTS.md
wc -c ~/.codex/AGENTS.md
grep -c '^## ' ~/.codex/AGENTS.md
```
Expected: first line is the generated-file marker; size well under the 32 KiB Codex cap; 4 `##` section headers (one per rule file).

- [ ] **Step 4: Confirm idempotency**

```bash
AI_ENV_SETUP_TOOLS=claude,codex ./bin/setup.sh
```
Expected: every relevant line logs `up to date:` — no new `linked:`/`generated:`/`backed up` lines, no new `.bak` files anywhere under `~/.claude/rules/` or at `~/.codex/AGENTS.md.bak`.

- [ ] **Step 5: Confirm edit-and-regenerate**

```bash
echo "" >> rules/commit-attribution.md   # trivial no-op-ish edit; revert after
AI_ENV_SETUP_TOOLS=claude,codex ./bin/setup.sh
git diff rules/commit-attribution.md      # revert this test edit
git checkout -- rules/commit-attribution.md
AI_ENV_SETUP_TOOLS=claude,codex ./bin/setup.sh
```
Expected: the first run regenerates `~/.codex/AGENTS.md` (logs `generated:`) while the Claude Code symlinks need no action (already point at the live source, so editing the source doesn't require re-running for Claude Code to see it — confirm by `cat ~/.claude/rules/commit-attribution.md` reflecting the edit even before the second setup.sh run).

- [ ] **Step 6: Confirm drift-backup on `~/.codex/AGENTS.md`**

```bash
printf 'hand edit, not ours\n' > ~/.codex/AGENTS.md
AI_ENV_SETUP_TOOLS=claude,codex ./bin/setup.sh
ls ~/.codex/AGENTS.md.bak
cat ~/.codex/AGENTS.md.bak   # expect: "hand edit, not ours"
head -n1 ~/.codex/AGENTS.md  # expect: the generated marker again
```
Expected: the hand-edited content is preserved in `.bak`, and the real file is regenerated correctly.

- [ ] **Step 7: Clean up the test artifact**

```bash
rm -f ~/.codex/AGENTS.md.bak
```

- [ ] **Step 8: Final status check**

```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
git status --short
git log --oneline -6
```
Expected: working tree clean except any unrelated pre-existing changes (e.g. `manifest/skills.yaml`); the four commits from Tasks 1–4 present in history.
