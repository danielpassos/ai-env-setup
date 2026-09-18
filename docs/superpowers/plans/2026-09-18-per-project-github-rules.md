# Per-project GitHub Issue Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. (superpowers:subagent-driven-development is not reliably available in this environment's skill set — inline execution is the fallback used for the prior plan too.)

**Goal:** Add `ai-env-setup add-github-issue-rules`, a subcommand run from inside a target project's repo that discovers that repo's real GitHub Projects (v2) board via `gh` and writes a freshly-fetched, board-specific rules block into that project's own `AGENTS.md` — plus a new universal `rules/github-issue-style.md` for the parts of the original example that don't depend on a board at all.

**Architecture:** A new `bin/lib/github_rules.sh` module resolves owner/project (via `gh`, with `--owner`/`--project` flags to skip auto-detection), fetches the board's fields via `gh project field-list` (parsed with `yq -p json` — no new `jq` dependency), renders a markdown block with the real IDs substituted in, and upserts that block into the target `AGENTS.md` between marker comments (idempotent — re-running replaces only the marked section). `bin/setup.sh`'s `main()` gets a short-circuit dispatch for this subcommand before its normal machine-setup flow runs.

**Tech Stack:** Bash 3.2 (macOS `/bin/bash`), `gh` (GitHub CLI — new hard dependency for this feature), `yq`, `gum`, `awk` (BSD awk on macOS). No new Homebrew dependency: `gh` is already part of the user's workflow (used throughout the original example this design is based on) and isn't installed by this repo for any of the three managed tools, so it's a documented prerequisite, not a `Brewfile` addition.

**Spec:** `docs/superpowers/specs/2026-09-18-per-project-github-rules-design.md`

## Global Constraints

- macOS `/bin/bash` is 3.2 — guard any array that might be empty with `[[ "${#arr[@]}" -gt 0 ]]` before `"${arr[@]}"` expansion.
- The subcommand is named `add-github-issue-rules` (renamed from an earlier `add-github-rules` during spec review — the spec file already reflects this; nothing else to migrate).
- `add-github-issue-rules` only ever touches `AGENTS.md` in the current directory — it must never create/modify `CLAUDE.md`, and must never run the brew/tool-selection/skills/plugins/MCP flow that `bin/setup.sh`'s normal path runs.
- Field detection (Status/Priority/Size) is by exact field name; each is independently optional — a missing field just omits that field's section, never an error.
- No new `jq` dependency — use `yq -p json` (optionally `-o json` when literal Unicode/emoji must survive in the output) for all `gh ... --format json` parsing, consistent with this repo's existing `yq`-only tooling.
- Testing must never touch any of Daniel's real project repos' files — use scratch temp directories, with real (read-only) `gh` calls against `danielpassos/ai-env-setup` (for owner auto-detection) and project `1` (a real, confirmed-live board) only where explicitly needed.

---

## Task 1: Universal content — `rules/github-issue-style.md`

**Files:**
- Create: `rules/github-issue-style.md`

**Interfaces:**
- Consumes: nothing (pure content).
- Produces: a fifth file in `rules/`, picked up automatically by the existing `expand`/`concat` links in `manifest/tools.yaml` (no manifest change needed — those links already point at the whole `rules/` directory).

- [ ] **Step 1: Create the file**

```markdown
## GitHub issue writing style

These apply to any `gh issue create`, `gh pr create`, `gh issue comment`, or
`gh pr comment` body, whether or not the project has a GitHub Projects
board.

### Markdown in HEREDOC bodies - never escape backticks

When writing an issue/PR/comment body via:

```bash
gh issue create --body "$(cat <<'EOF'
...
EOF
)"
```

...the **single-quoted** `<<'EOF'` already disables shell expansion.
Backticks, `$`, `"`, and `\` are already literal. Do NOT add `\` before
them - the backslashes survive into the body verbatim and break the
rendered Markdown. A triple-backtick fence "escaped" as `` \`\`\`tsx ``
renders on GitHub as the literal text `` \`\`\`tsx `` instead of opening a
code block.

Rule: inside `<<'EOF'` ... `EOF`, write Markdown the way you'd write it in
a `.md` file. No escapes. Ever.

### Never hard-wrap prose in issue/PR/comment bodies

GitHub renders issue, PR, and comment bodies differently from files in the
repo. A file rendered from the repo (a README, a doc under `docs/`) follows
CommonMark: a single `\n` inside a paragraph is a soft break and collapses
to a space. Issue/PR/comment bodies do **not** follow that rule - GitHub
renders every single `\n` there as a literal `<br>`. Text hand-wrapped at
~80 columns will render as one choppy line per source line instead of a
flowing paragraph.

Rule: write each paragraph as a single unwrapped line - no interior
newlines - and use a blank line only to separate paragraphs, list items, or
headings. This applies to prose paragraphs specifically; list items, code
fences, and headings still each take their own line as normal Markdown
requires.

### Issue body shape

For bug and audit findings, use this shape by default:

1. **What can go wrong** - describe the bad behavior in product terms.
2. **Example** - give a concrete action sequence or data scenario.
3. **Why this matters** - explain the user, admin, or data impact.
4. **Where this seems to happen** - name files/functions after the problem
   is clear.
5. **Expected behavior** - describe what the system should do instead.
6. **Fix idea** - keep this short and clearly separate from the problem.

Avoid opening with implementation-detail phrasing (race conditions,
compare-and-swap, ORM internals, etc.) - that can appear in a technical
section, but the title and summary should say what a person would observe.

### Issue title format

Plain language - never commit-style prefixes like `fix(web):` or
`feat(bot):` in an issue title.
```

- [ ] **Step 2: Verify no board/ID leakage**

Run:
```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
grep -riE 'project id|field id|option id|priority field|size field|status field' rules/github-issue-style.md
```
Expected: no output (exit status 1) — confirms nothing board-specific slipped into the universal file.

- [ ] **Step 3: Commit**

```bash
git add rules/github-issue-style.md
git commit -m "Add rules/github-issue-style.md - universal GitHub issue formatting rules"
```

---

## Task 2: `bin/lib/github_rules.sh` — discovery, rendering, and upsert

**Files:**
- Create: `bin/lib/github_rules.sh`

**Interfaces:**
- Consumes: `log_info`/`log_success`/`log_warn`/`die`/`require_cmd` from `bin/lib/common.sh`.
- Produces: `github_rules::run` — the entry point `bin/setup.sh` will dispatch to in Task 3. Signature: `github_rules::run [--owner LOGIN] [--project NUMBER]`, no return value used (relies on `die` for failure), writes to `./AGENTS.md` as a side effect.

- [ ] **Step 1: Create the file with the module header and marker constants**

```bash
#!/usr/bin/env bash
# ai-env-setup add-github-issue-rules - discovers a target repo's GitHub
# Projects (v2) board via `gh` and writes the board-specific rules (with
# real, freshly-fetched IDs) into that project's own AGENTS.md. Scoped to
# the current directory; does not touch this repo's own manifest-driven
# distribution (see bin/lib/links.sh / manifest/tools.yaml for that).

GITHUB_RULES_START='<!-- ai-env-setup:github-issues:start -->'
GITHUB_RULES_END='<!-- ai-env-setup:github-issues:end -->'

readonly GITHUB_RULES_START GITHUB_RULES_END
```

- [ ] **Step 2: Add `github_rules::_check_gh` and verify it**

Append:
```bash

# github_rules::_check_gh - fails fast with a clear message if `gh` isn't
# installed, authenticated, or missing the `project` token scope required
# for every `gh project ...` call this module makes.
github_rules::_check_gh() {
  require_cmd gh
  require_cmd yq

  local status
  status="$(gh auth status 2>&1)" || die "gh is not authenticated - run 'gh auth login' first"

  printf '%s' "$status" | grep -q "'project'" \
    || die "gh's token is missing the 'project' scope - run 'gh auth refresh -s project'"
}
```

Run:
```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
source bin/lib/common.sh
source bin/lib/github_rules.sh
github_rules::_check_gh && echo "OK: gh is authenticated with the project scope"
```
Expected: `OK: gh is authenticated with the project scope` (this machine's `gh` is already confirmed logged in with `project` in its scopes — verified earlier in this session's `gh auth status` output).

- [ ] **Step 3: Add `github_rules::_resolve_owner` and verify it**

Append:
```bash

# github_rules::_resolve_owner OWNER_FLAG -> prints the owner login to use.
# If OWNER_FLAG is non-empty, uses it as-is. Otherwise resolves it from the
# current directory's GitHub-backed git remote via `gh repo view`.
github_rules::_resolve_owner() {
  local owner_flag="$1"
  if [[ -n "$owner_flag" ]]; then
    printf '%s\n' "$owner_flag"
    return 0
  fi

  local owner
  owner="$(gh repo view --json owner -q .owner.login 2>/dev/null)" \
    || die "couldn't resolve a GitHub owner from the current directory - pass --owner, or run this inside a GitHub-backed git repo"
  printf '%s\n' "$owner"
}
```

Run:
```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
source bin/lib/common.sh
source bin/lib/github_rules.sh

# explicit flag wins, no gh call needed
[[ "$(github_rules::_resolve_owner "someone-else")" == "someone-else" ]] && echo "OK: explicit owner wins"

# auto-detect from this real repo's own GitHub-backed remote
[[ "$(github_rules::_resolve_owner "")" == "danielpassos" ]] && echo "OK: auto-detected owner"
```
Expected: both `OK:` lines print (this repo's own `origin` remote is `git@github.com:danielpassos/ai-env-setup.git`, confirmed earlier in this session).

- [ ] **Step 4: Add `github_rules::_resolve_project` and verify it**

Append:
```bash

# github_rules::_resolve_project OWNER PROJECT_FLAG -> prints the project
# number to use. If PROJECT_FLAG is non-empty, uses it as-is (no `gh` call).
# Otherwise lists OWNER's GitHub Projects and asks for a single pick via
# gum - titles alone aren't a reliable identifier (an owner can have
# multiple boards with the same title), so the picker shows title + URL.
github_rules::_resolve_project() {
  local owner="$1" project_flag="$2"
  if [[ -n "$project_flag" ]]; then
    printf '%s\n' "$project_flag"
    return 0
  fi

  local raw
  raw="$(gh project list --owner "$owner" --format json)" \
    || die "couldn't list GitHub Projects for owner $owner"

  local options=() line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    options+=("$line")
  done < <(printf '%s' "$raw" | yq -p json '.projects[] | .title + " (" + .url + "):" + (.number | tostring)')

  [[ "${#options[@]}" -eq 0 ]] && die "owner $owner has no GitHub Projects"

  require_cmd gum
  local chosen
  chosen="$(gum choose --header "Which GitHub Project board does this repo use?" \
    --label-delimiter=":" "${options[@]}")"
  [[ -z "$chosen" ]] && die "no project selected"

  printf '%s\n' "$chosen"
}
```

Run (non-interactive path only — the interactive `gum choose` branch is exercised manually in Task 4, since it needs a real TTY):
```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
source bin/lib/common.sh
source bin/lib/github_rules.sh

[[ "$(github_rules::_resolve_project "danielpassos" "1")" == "1" ]] && echo "OK: explicit project wins"
```
Expected: `OK: explicit project wins`.

- [ ] **Step 5: Add the field-lookup helpers and verify them**

Append:
```bash

# github_rules::_fields_json OWNER PROJECT -> prints the raw `gh project
# field-list` JSON, fetched once and reused by every lookup below.
github_rules::_fields_json() {
  local owner="$1" project="$2"
  gh project field-list "$project" --owner "$owner" --format json \
    || die "couldn't list fields for project $project (owner $owner)"
}

# github_rules::_field_id FIELDS_JSON NAME -> prints that field's id, or
# nothing if no field with that exact name exists.
github_rules::_field_id() {
  local fields_json="$1" name="$2"
  printf '%s' "$fields_json" | yq -p json ".fields[] | select(.name == \"$name\") | .id"
}

# github_rules::_field_options_table FIELDS_JSON NAME -> prints a markdown
# table of that field's options (name | id), or nothing if the field
# doesn't exist.
github_rules::_field_options_table() {
  local fields_json="$1" name="$2"
  local rows
  rows="$(printf '%s' "$fields_json" | yq -p json ".fields[] | select(.name == \"$name\") | .options[] | .name + \"\t\" + .id")"
  [[ -z "$rows" ]] && return 0

  printf '| %s | Option ID |\n' "$name"
  printf '|---|---|\n'
  local label id
  while IFS=$'\t' read -r label id; do
    [[ -z "$label" ]] && continue
    printf '| %s | `%s` |\n' "$label" "$id"
  done <<<"$rows"
}
```

Run (real, read-only `gh` calls against `danielpassos`'s project `1`, confirmed live earlier in this session to have Status/Priority/Size fields):
```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
source bin/lib/common.sh
source bin/lib/github_rules.sh

fields_json="$(github_rules::_fields_json danielpassos 1)"

[[ "$(github_rules::_field_id "$fields_json" "Priority")" == "PVTSSF_lAHNNBnOAA9Iy84AjMzH" ]] \
  && echo "OK: Priority field id matches"

[[ -z "$(github_rules::_field_id "$fields_json" "NoSuchField")" ]] \
  && echo "OK: missing field returns empty, not an error"

github_rules::_field_options_table "$fields_json" "Priority"
```
Expected: both `OK:` lines print, followed by a markdown table with 4 rows (Urgent/High/Medium/Low) and their option IDs (`7bcc7c37`, `59cc2e7d`, `86ebad03`, `90190884`).

- [ ] **Step 6: Add `github_rules::_render_block` and verify it**

Append:
```bash

# github_rules::_render_block OWNER PROJECT -> prints the full
# board-specific markdown block (unwrapped - no marker comments; the
# caller wraps it via github_rules::_upsert_block).
github_rules::_render_block() {
  local owner="$1" project="$2"
  local fields_json project_json project_id project_url project_title
  fields_json="$(github_rules::_fields_json "$owner" "$project")"

  project_json="$(gh project view "$project" --owner "$owner" --format json)" \
    || die "couldn't view project $project (owner $owner)"
  project_id="$(printf '%s' "$project_json" | yq -p json '.id')"
  project_url="$(printf '%s' "$project_json" | yq -p json '.url')"
  project_title="$(printf '%s' "$project_json" | yq -p json '.title')"

  local status_id priority_id size_id
  status_id="$(github_rules::_field_id "$fields_json" "Status")"
  priority_id="$(github_rules::_field_id "$fields_json" "Priority")"
  size_id="$(github_rules::_field_id "$fields_json" "Size")"

  printf '## GitHub Issue board wiring\n\n'
  printf 'Board: [%s](%s) (project %s, owner %s).\n\n' "$project_title" "$project_url" "$project" "$owner"
  printf 'Every `gh issue create` must be followed by adding the issue to the\n'
  printf 'project board and assigning it to a column. Never leave an issue\n'
  printf 'floating off the board.\n\n'
  printf '**Project metadata:**\n\n'
  printf -- '- Project ID: `%s`\n' "$project_id"
  [[ -n "$status_id" ]] && printf -- '- Status field ID: `%s`\n' "$status_id"
  [[ -n "$priority_id" ]] && printf -- '- Priority field ID: `%s`\n' "$priority_id"
  [[ -n "$size_id" ]] && printf -- '- Size field ID: `%s`\n' "$size_id"
  printf '\n'

  if [[ -n "$status_id" ]]; then
    printf '**Two-step pattern** (re-verify option IDs via `gh project\n'
    printf 'field-list %s --owner %s --format json` if the board structure\n' "$project" "$owner"
    printf 'changes):\n\n'
    printf '```bash\n'
    printf '# Step 1: create the issue\n'
    printf 'gh issue create --title "..." --body "..."  # -> returns the issue URL\n\n'
    printf '# Step 2: add to the board + assign column\n'
    printf 'ITEM_ID=$(gh project item-add %s --owner %s \\\n' "$project" "$owner"
    printf '  --url <issue-url-from-step-1> --format json | jq -r .id)\n'
    printf 'gh project item-edit \\\n'
    printf '  --project-id %s \\\n' "$project_id"
    printf '  --field-id %s \\\n' "$status_id"
    printf '  --id "$ITEM_ID" \\\n'
    printf '  --single-select-option-id <column-option-id>\n'
    printf '```\n\n'
  fi

  local table
  if [[ -n "$status_id" ]]; then
    table="$(github_rules::_field_options_table "$fields_json" "Status")"
    [[ -n "$table" ]] && printf '%s\n\n' "$table"
  fi
  if [[ -n "$priority_id" ]]; then
    table="$(github_rules::_field_options_table "$fields_json" "Priority")"
    [[ -n "$table" ]] && printf '%s\n\n' "$table"
  fi
  if [[ -n "$size_id" ]]; then
    table="$(github_rules::_field_options_table "$fields_json" "Size")"
    [[ -n "$table" ]] && printf '%s\n\n' "$table"
  fi
}
```

Run:
```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
source bin/lib/common.sh
source bin/lib/github_rules.sh

github_rules::_render_block danielpassos 1
```
Expected: a markdown block starting with `## GitHub Issue board wiring`, a `Board: [Moorea](https://github.com/users/danielpassos/projects/1) ...` line, `Project ID: \`PVT_kwHNNBnOAA9Iyw\``, a two-step `gh` command block with real IDs substituted, and three option tables (Status, Priority, Size) with real rows.

- [ ] **Step 7: Add `github_rules::_upsert_block` and verify it**

Append:
```bash

# github_rules::_upsert_block FILE BLOCK
# Idempotently writes BLOCK, wrapped in GITHUB_RULES_START/END markers,
# into FILE. Replaces the content between existing markers, appends a new
# marked section if FILE exists without markers, or creates FILE containing
# just the marked block if it doesn't exist yet. A no-op (no write) if the
# computed block already matches what's between the markers.
github_rules::_upsert_block() {
  local file="$1" block="$2"
  local wrapped="$GITHUB_RULES_START"$'\n\n'"$block"$'\n\n'"$GITHUB_RULES_END"

  if [[ ! -f "$file" ]]; then
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$wrapped" >"$file"
    log_success "created: $file"
    return 0
  fi

  if grep -qF "$GITHUB_RULES_START" "$file" && grep -qF "$GITHUB_RULES_END" "$file"; then
    local block_file tmp
    block_file="$(mktemp)"
    tmp="$(mktemp)"
    printf '%s\n' "$wrapped" >"$block_file"

    # awk's -v can't hold a literal embedded newline, so the replacement
    # text is streamed in via getline from a temp file instead of passed
    # as a -v string directly.
    awk -v start="$GITHUB_RULES_START" -v end="$GITHUB_RULES_END" -v blockfile="$block_file" '
      $0 == start {
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        skip = 1
        next
      }
      $0 == end { skip = 0; next }
      skip { next }
      { print }
    ' "$file" >"$tmp"

    if diff -q "$tmp" "$file" >/dev/null 2>&1; then
      log_success "up to date: $file"
      rm -f "$tmp" "$block_file"
    else
      mv "$tmp" "$file"
      rm -f "$block_file"
      log_success "updated block in: $file"
    fi
  else
    printf '\n%s\n' "$wrapped" >>"$file"
    log_success "appended block to: $file"
  fi
}
```

Run (scratch temp file, not any real project):
```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
source bin/lib/common.sh
source bin/lib/github_rules.sh

tmp_agents="$(mktemp -d)/AGENTS.md"

echo "== 1: file doesn't exist yet =="
github_rules::_upsert_block "$tmp_agents" "first version"
cat "$tmp_agents"

echo "== 2: same content again =="
github_rules::_upsert_block "$tmp_agents" "first version"

echo "== 3: different content, markers present =="
github_rules::_upsert_block "$tmp_agents" "second version"
cat "$tmp_agents"

echo "== 4: existing file with unrelated content, no markers =="
other="$(mktemp -d)/AGENTS.md"
printf '# Some project\n\nUnrelated existing content.\n' >"$other"
github_rules::_upsert_block "$other" "appended version"
cat "$other"
```
Expected: step 1 creates the file with the wrapped block; step 2 logs `up to date:` with no change; step 3 logs `updated block in:` and the file now shows "second version"; step 4 logs `appended block to:` and the file shows the original unrelated content followed by the new marked block.

- [ ] **Step 8: Add `github_rules::run` (the entry point)**

Append:
```bash

# github_rules::run [--owner LOGIN] [--project NUMBER]
# Entry point for `ai-env-setup add-github-issue-rules`. Discovers the
# current directory's GitHub Projects board (or uses the given flags) and
# writes/refreshes the board-specific block in ./AGENTS.md.
github_rules::run() {
  local owner_flag="" project_flag=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --owner)
        owner_flag="$2"
        shift 2
        ;;
      --project)
        project_flag="$2"
        shift 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  github_rules::_check_gh

  local owner project block
  owner="$(github_rules::_resolve_owner "$owner_flag")"
  project="$(github_rules::_resolve_project "$owner" "$project_flag")"

  log_info "using project $project (owner $owner)"

  block="$(github_rules::_render_block "$owner" "$project")"
  github_rules::_upsert_block "$(pwd)/AGENTS.md" "$block"
}
```

- [ ] **Step 9: Full end-to-end run of the module, in a scratch directory**

```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
source bin/lib/common.sh
source bin/lib/github_rules.sh

scratch="$(mktemp -d)"
(cd "$scratch" && github_rules::run --owner danielpassos --project 1)
cat "$scratch/AGENTS.md"
rm -rf "$scratch"
```
Expected: `AGENTS.md` is created in `$scratch` containing the full marked block (same content verified in Step 6), with no interactive prompt (both flags given, so `gum choose` is never invoked).

- [ ] **Step 10: Commit**

```bash
git add bin/lib/github_rules.sh
git commit -m "Add bin/lib/github_rules.sh - discovers and renders per-project GitHub issue board rules"
```

---

## Task 3: Wire the subcommand dispatch and document it

**Files:**
- Modify: `bin/setup.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `github_rules::run` from Task 2.
- Produces: the actual `ai-env-setup add-github-issue-rules` command end users run.

- [ ] **Step 1: Source the new module in `bin/setup.sh`**

In `bin/setup.sh`, add the source line alongside the others:

```bash
# shellcheck source=lib/mcp.sh
source "$script_dir/lib/mcp.sh"
# shellcheck source=lib/github_rules.sh
source "$script_dir/lib/github_rules.sh"
```

- [ ] **Step 2: Add the dispatch short-circuit to `main()`**

Change:
```bash
main() {
  ensure_macos

  log_info "ai-env-setup running from $AI_ENV_SETUP_HOME"
```

To:
```bash
main() {
  if [[ "${1:-}" == "add-github-issue-rules" ]]; then
    shift
    github_rules::run "$@"
    exit $?
  fi

  ensure_macos

  log_info "ai-env-setup running from $AI_ENV_SETUP_HOME"
```

- [ ] **Step 3: Verify the dispatch, without touching this repo's own AGENTS.md**

```bash
scratch="$(mktemp -d)"
(cd "$scratch" && /Users/danielpassos/Develoment/Projects/personal/ai-env-setup/bin/setup.sh add-github-issue-rules --owner danielpassos --project 1)
cat "$scratch/AGENTS.md"
rm -rf "$scratch"
```
Expected: same `AGENTS.md` content as Task 2 Step 9, confirming `bin/setup.sh add-github-issue-rules ...` reaches `github_rules::run` without running `ensure_macos`/brew/tool-selection first (no Homebrew/tool-selection log lines should appear before the board-wiring output).

- [ ] **Step 4: Document the subcommand in `README.md`**

Add a new section after `## Update` (before `## Layout`):

```markdown
## Adding board-specific GitHub issue rules to a project

`ai-env-setup add-github-issue-rules` is different from the rest of this
tool: it's scoped to a single target project, not this machine. Run it from
inside that project's own repo:

```sh
ai-env-setup add-github-issue-rules
```

It resolves the repo's GitHub owner via `gh repo view`, lists that owner's
GitHub Projects (v2) boards and asks which one this repo uses, fetches that
board's real Status/Priority/Size field and option IDs via `gh project
field-list`, and writes/refreshes a marked block in that project's own
`AGENTS.md` - never in this repo. Re-running it re-fetches live and
replaces only that marked block, so board changes (a renamed column, a new
priority option) never go stale. Pass `--owner <login>` and/or `--project
<number>` to skip the auto-detection/picker, e.g. for scripting.

Requires `gh` to be installed and authenticated with the `project` token
scope (`gh auth refresh -s project` if it's missing).

The formatting/writing-style rules that don't depend on a board at all
(heredoc escaping, no hard-wrapping issue bodies, the issue body shape) are
not part of this - they're already universal, and live in
`rules/github-issue-style.md` like every other file in `rules/`.
```

- [ ] **Step 5: Commit**

```bash
git add bin/setup.sh README.md
git commit -m "Wire add-github-issue-rules subcommand dispatch and document it"
```

---

## Task 4: End-to-end verification and idempotency checks

**Files:** none (verification only).

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: nothing new — confirms the full chain works together, including the interactive picker path this plan's automated steps couldn't exercise.

- [ ] **Step 1: Confirm `rules/github-issue-style.md` is distributed like the other four**

```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
AI_ENV_SETUP_TOOLS=claude,codex ./bin/setup.sh
ls ~/.claude/rules/github-issue-style.md
grep -c '^## ' ~/.codex/AGENTS.md
```
Expected: the symlink exists; the Codex `AGENTS.md` header count is now `5` (was `4` before this plan — confirmed in the prior plan's Task 5).

- [ ] **Step 2: Non-interactive full run, scratch directory**

```bash
scratch="$(mktemp -d)"
(cd "$scratch" && /Users/danielpassos/Develoment/Projects/personal/ai-env-setup/bin/setup.sh add-github-issue-rules --owner danielpassos --project 1)
head -n1 "$scratch/AGENTS.md"
grep -c '^## GitHub Issue board wiring' "$scratch/AGENTS.md"
```
Expected: first line is the start marker; exactly one `## GitHub Issue board wiring` heading.

- [ ] **Step 3: Idempotency on re-run, same scratch directory**

```bash
(cd "$scratch" && /Users/danielpassos/Develoment/Projects/personal/ai-env-setup/bin/setup.sh add-github-issue-rules --owner danielpassos --project 1) | grep "up to date"
```
Expected: `up to date: <scratch>/AGENTS.md` — no `updated block in:` line.

- [ ] **Step 4: Unrelated content preserved on re-run**

```bash
printf '\n## Unrelated section\n\nSome content the tool must never touch.\n' >>"$scratch/AGENTS.md"
(cd "$scratch" && /Users/danielpassos/Develoment/Projects/personal/ai-env-setup/bin/setup.sh add-github-issue-rules --owner danielpassos --project 1)
grep -q "Some content the tool must never touch" "$scratch/AGENTS.md" && echo "OK: unrelated content preserved"
```
Expected: `OK: unrelated content preserved`.

- [ ] **Step 5: Owner auto-detection against this repo's real remote, output still confined to scratch**

```bash
auto_scratch="$(mktemp -d)"
cd "$auto_scratch"
git init -q
git remote add origin git@github.com:danielpassos/ai-env-setup.git
/Users/danielpassos/Develoment/Projects/personal/ai-env-setup/bin/setup.sh add-github-issue-rules --project 1
cat AGENTS.md | head -n5
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
rm -rf "$auto_scratch"
```
Expected: succeeds without `--owner`, using `gh repo view` to resolve `danielpassos` from the fake `origin` remote pointing at the real, `gh`-accessible `ai-env-setup` repo; `AGENTS.md` is written only inside `$auto_scratch`, never touching this repo's real `AGENTS.md` (confirm separately: `git status --short` in the real repo shows no `AGENTS.md` change).

- [ ] **Step 6: Interactive picker path, manually, once**

This step needs a real terminal (the picker opens `/dev/tty` directly, same constraint already documented in this repo's own `AGENTS.md` for `gum choose`) - run it yourself, not via an automated tool call:

```sh
cd "$(mktemp -d)"
/Users/danielpassos/Develoment/Projects/personal/ai-env-setup/bin/setup.sh add-github-issue-rules --owner danielpassos
```
Expected: a `gum choose` prompt listing your 3 real projects (`Moorea (.../projects/4)`, `@danielpassos's untitled project (.../projects/3)`, `Moorea (.../projects/1)`), each independently selectable despite the duplicate title; picking one produces the same kind of `AGENTS.md` block as the non-interactive runs above.

- [ ] **Step 7: Final status check**

```bash
cd /Users/danielpassos/Develoment/Projects/personal/ai-env-setup
git status --short
git log --oneline -8
```
Expected: working tree clean except any unrelated pre-existing changes (e.g. `manifest/skills.yaml`); this plan's commits present in history on top of the prior global-rules-library commits.
