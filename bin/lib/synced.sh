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
# synced::begin. It is driven by a durable seed directory, not by the
# synced file's existence, so an aborted first run can't lose it.

SYNCED_STATE_DIR="$HOME/.config/ai-env-setup"
SYNCED_STATE_FILE="$SYNCED_STATE_DIR/synced"

# Durable migration snapshot. Its EXISTENCE means "migration pending": it is
# created once (before any picker rewrites selected-*) and removed only by
# synced::end, i.e. when a run gets through the whole sync phase. An aborted
# run (Ctrl-C, die, set -e, crashed CLI) leaves it behind and the next run
# reuses it instead of re-snapshotting the already-overwritten selected-*.
SYNCED_SEED_PATH="$SYNCED_STATE_DIR/synced-seed"

# Set by synced::begin to SYNCED_SEED_PATH while migration is pending, else
# empty. synced::_seeded reads the snapshot from here.
SYNCED_SEED_DIR=""

# synced::begin - call once from setup.sh, before any picker runs.
#
# State machine (seed = $SYNCED_SEED_PATH, synced = $SYNCED_STATE_FILE):
#
#   seed exists                  -> migration pending (a prior run aborted):
#                                   reuse the seed as-is, whatever the synced
#                                   file holds.
#   no seed, synced exists       -> migration done (or never needed): nothing.
#   no seed, no synced, previous -> start migration: snapshot the previous
#   selected-tools exists           selected-* files into the seed.
#   neither, no selected-tools   -> fresh machine: nothing is seeded.
#
# The synced file is always created here (after the seed, when there is one),
# so it also marks "fresh machine run already started": otherwise an aborted
# fresh run would leave selected-* behind and the next run would mistake the
# fresh run's picks for a previous, already-installed selection.
#
# While the seed exists, every (category, item, tool) pair of the previous
# selection (item AND tool were selected, plugins only for claude) that has
# no real record yet is treated as "assumed synced": recorded with the
# CURRENT manifest hash the first time it's checked, no CLI call. Anything
# else - items added since, items newly ticked (even in an aborted run), tools
# newly added, codex for plugins (plugins used to be claude-only) - syncs
# normally. Limits: an entry edited in the manifest between the last real run
# and the migration is assumed synced too (use --resync once to force it).
# --resync ignores the seed for that run but still snapshots/keeps it, so a
# resync that completes finalizes the migration and one that aborts doesn't
# lose it.
synced::begin() {
  SYNCED_SEED_DIR=""
  mkdir -p "$SYNCED_STATE_DIR"

  if [[ -d "$SYNCED_SEED_PATH" ]]; then
    log_info "resuming interrupted first run: previous selection still assumed synced (--resync to redo)"
  elif [[ ! -f "$SYNCED_STATE_FILE" && -f "$SYNCED_STATE_DIR/selected-tools" ]]; then
    # Build in a temp dir, then rename, so an interrupt can't leave a
    # half-copied seed that a later run would trust.
    local tmp f
    tmp="$(mktemp -d "$SYNCED_STATE_DIR/.synced-seed.XXXXXX")"
    for f in selected-tools selected-skills selected-plugins selected-mcp; do
      if [[ -f "$SYNCED_STATE_DIR/$f" ]]; then
        cp "$SYNCED_STATE_DIR/$f" "$tmp/$f"
      fi
    done
    mv "$tmp" "$SYNCED_SEED_PATH"
    log_info "no sync records yet: assuming your previous selection is already synced (--resync to redo)"
  fi

  [[ -d "$SYNCED_SEED_PATH" ]] && SYNCED_SEED_DIR="$SYNCED_SEED_PATH"
  [[ -f "$SYNCED_STATE_FILE" ]] || : >"$SYNCED_STATE_FILE"
  return 0
}

# synced::end - call once, only after the sync phase ran to completion:
# finalizes the migration by deleting the seed. (Individual sync failures
# don't abort the run and are never recorded, so they retry next run anyway.)
synced::end() {
  rm -rf "$SYNCED_SEED_PATH"
  SYNCED_SEED_DIR=""
  [[ -f "$SYNCED_STATE_FILE" ]] || : >"$SYNCED_STATE_FILE"
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

  # Also forget it in a pending seed, so re-ticking an item that was just
  # uninstalled (in an aborted run) isn't assumed to still be installed.
  local sel="$SYNCED_SEED_PATH/selected-$1" tmp
  if [[ -f "$sel" ]]; then
    tmp="$(mktemp)"
    grep -Fxv -- "$2" "$sel" >"$tmp" || true
    mv "$tmp" "$sel"
  fi
}
