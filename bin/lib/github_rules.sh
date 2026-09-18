#!/usr/bin/env bash
# ai-env-setup add-github-issue-rules - discovers a target repo's GitHub
# Projects (v2) board via `gh` and writes the board-specific rules (with
# real, freshly-fetched IDs) into that project's own AGENTS.md. Scoped to
# the current directory; does not touch this repo's own manifest-driven
# distribution (see bin/lib/links.sh / manifest/tools.yaml for that).

GITHUB_RULES_START='<!-- ai-env-setup:github-issues:start -->'
GITHUB_RULES_END='<!-- ai-env-setup:github-issues:end -->'

readonly GITHUB_RULES_START GITHUB_RULES_END

# github_rules::_check_gh - fails fast with a clear message if `gh` isn't
# installed, authenticated, or missing the `project` token scope required
# for every `gh project ...` call this module makes.
github_rules::_check_gh() {
  require_cmd gh
  require_cmd yq

  local gh_status
  gh_status="$(gh auth status 2>&1)" || die "gh is not authenticated - run 'gh auth login' first"

  printf '%s' "$gh_status" | grep -q "'project'" \
    || die "gh's token is missing the 'project' scope - run 'gh auth refresh -s project'"
}

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
