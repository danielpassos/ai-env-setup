#!/usr/bin/env bash
# Tracks which manifest entries have already been synced, so a re-run only
# does the expensive per-item work (skills CLI, plugin CLIs, MCP config) for
# entries that are new, edited, or newly applicable to another tool.
#
# State file: ~/.config/ai-env-setup/synced, one record per line, tab-
# separated (plain text, bash 3.2 friendly):
#
#   <category>\t<id>\t<tool>\t<hash>
#
# - category: skills | plugins | mcp
# - id: the same id the category's picker uses (skills: `source`; plugins:
#   "plugin@marketplace"; mcp: server id)
# - tool: the target actually synced - the `skills` CLI agent id for skills
#   (e.g. claude-code), claude/codex for plugins, claude/codex/cursor for MCP
# - hash: sha256 of that manifest entry dumped by yq as compact JSON, so any
#   edit to the entry (url, only, agents, ...) changes it and re-syncs
#
# A record is only written after a successful sync, and dropped when the
# item is deselected/uninstalled. `--resync` / AI_ENV_SETUP_RESYNC=1 ignores
# the file for that run (everything syncs and is re-recorded).
#
# One-time migration (first run after this file was introduced): see
# synced::begin.

SYNCED_STATE_DIR="$HOME/.config/ai-env-setup"
SYNCED_STATE_FILE="$SYNCED_STATE_DIR/synced"

# Set by synced::begin only on the migration run: a temp dir holding a copy
# of the selected-* files as they were BEFORE this run's pickers rewrote
# them. Empty otherwise.
SYNCED_SEED_DIR=""

# synced::begin - call once from setup.sh, before any picker runs.
#
# If the synced file doesn't exist yet but a previous run's selected-tools
# file does, snapshot the previous selection files and treat each
# (category, item, tool) pair the previous run would have synced as already
# synced ("assumed synced": recorded with the CURRENT manifest hash the
# first time it's checked, no CLI call). Anything not in that snapshot -
# items added to the manifest since, items you newly tick, tools you newly
# add, and codex for plugins (plugins used to be claude-only) - syncs
# normally. Limits: an entry that was edited in the manifest between the
# last real run and this one is assumed synced too (use --resync once to
# force it). The synced file is created empty here so the migration happens
# exactly once even if every sync this run fails.
synced::begin() {
  SYNCED_SEED_DIR=""
  [[ -f "$SYNCED_STATE_FILE" ]] && return 0

  mkdir -p "$SYNCED_STATE_DIR"

  if [[ -z "${AI_ENV_SETUP_RESYNC:-}" && -f "$SYNCED_STATE_DIR/selected-tools" ]]; then
    SYNCED_SEED_DIR="$(mktemp -d)"
    local f
    for f in selected-tools selected-skills selected-plugins selected-mcp; do
      if [[ -f "$SYNCED_STATE_DIR/$f" ]]; then
        cp "$SYNCED_STATE_DIR/$f" "$SYNCED_SEED_DIR/$f"
      fi
    done
    log_info "no sync records yet: assuming your previous selection is already synced (--resync to redo)"
  fi

  : >"$SYNCED_STATE_FILE"
}

# synced::end - call once at the end of setup.sh; cleans up the seed snapshot.
synced::end() {
  if [[ -n "$SYNCED_SEED_DIR" ]]; then
    rm -rf "$SYNCED_SEED_DIR"
  fi
  SYNCED_SEED_DIR=""
  return 0
}

# synced::hash_entry MANIFEST YQ_PATH -> sha256 of that entry as compact JSON
synced::hash_entry() {
  yq e -o=json -I=0 "$2" "$1" | shasum -a 256 | cut -d' ' -f1
}

synced::_has_line() {
  [[ -f "$SYNCED_STATE_FILE" ]] || return 1
  grep -Fxq -- "$1" "$SYNCED_STATE_FILE"
}

# synced::_has_key CATEGORY ID TOOL - any record at all (any hash)
synced::_has_key() {
  [[ -f "$SYNCED_STATE_FILE" ]] || return 1
  grep -Fq -- "$(printf '%s\t%s\t%s\t' "$1" "$2" "$3")" "$SYNCED_STATE_FILE"
}

# synced::_seeded CATEGORY ID TOOL - was this pair part of the previous run?
synced::_seeded() {
  local category="$1" id="$2" tool="$3" line found=0
  [[ -n "$SYNCED_SEED_DIR" ]] || return 1

  # Previous tool selection: the tool must have been selected back then.
  # Skills are keyed by `skills` CLI agent id, so translate each previously
  # selected tool id before comparing.
  local tools_file="$SYNCED_SEED_DIR/selected-tools" tool_matched=0
  [[ -f "$tools_file" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$category" == "skills" ]]; then
      [[ "$(tools::skills_agent "$line")" == "$tool" ]] && tool_matched=1
    else
      [[ "$line" == "$tool" ]] && tool_matched=1
    fi
  done <"$tools_file"
  [[ "$tool_matched" -eq 1 ]] || return 1

  # Plugins were claude-only before codex support - don't assume codex.
  [[ "$category" == "plugins" && "$tool" != "claude" ]] && return 1

  local sel_file="$SYNCED_SEED_DIR/selected-$category"
  [[ -f "$sel_file" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == "$id" ]] && found=1
  done <"$sel_file"
  [[ "$found" -eq 1 ]]
}

# synced::is_current CATEGORY ID TOOL HASH - succeeds when this pair doesn't
# need syncing: its recorded hash equals HASH, or (migration run only) it
# was part of the previous selection. Always fails under --resync.
synced::is_current() {
  local category="$1" id="$2" tool="$3" hash="$4"
  [[ -n "${AI_ENV_SETUP_RESYNC:-}" ]] && return 1

  synced::_has_line "$(printf '%s\t%s\t%s\t%s' "$category" "$id" "$tool" "$hash")" && return 0

  if ! synced::_has_key "$category" "$id" "$tool" && synced::_seeded "$category" "$id" "$tool"; then
    synced::record "$category" "$id" "$tool" "$hash"
    return 0
  fi
  return 1
}

# synced::_remove CATEGORY ID [TOOL] - drops matching records (every tool
# when TOOL is omitted).
synced::_remove() {
  [[ -f "$SYNCED_STATE_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  SC="$1" SI="$2" ST="${3:-}" awk -F'\t' \
    '!($1 == ENVIRON["SC"] && $2 == ENVIRON["SI"] && (ENVIRON["ST"] == "" || $3 == ENVIRON["ST"]))' \
    "$SYNCED_STATE_FILE" >"$tmp"
  mv "$tmp" "$SYNCED_STATE_FILE"
}

# synced::record CATEGORY ID TOOL HASH - call only after a successful sync.
synced::record() {
  mkdir -p "$SYNCED_STATE_DIR"
  synced::_remove "$1" "$2" "$3"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$SYNCED_STATE_FILE"
}

# synced::drop CATEGORY ID - forget every tool's record for an item (it was
# deselected/uninstalled), so ticking it again later syncs it afresh.
synced::drop() {
  synced::_remove "$1" "$2"
}
