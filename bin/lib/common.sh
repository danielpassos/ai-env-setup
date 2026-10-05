#!/usr/bin/env bash
# Shared helpers: logging, symlinking, and sanity checks used by every lib module.

AI_ENV_SETUP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

readonly AI_ENV_SETUP_HOME

_c_reset=$'\033[0m'
_c_blue=$'\033[34m'
_c_green=$'\033[32m'
_c_yellow=$'\033[33m'
_c_red=$'\033[31m'

# All logging goes to stderr, never stdout - several functions (tools::select
# in particular) use stdout as their actual return channel, and a log line
# leaking into a captured `< <(...)` read would silently corrupt the result.
log_info()    { printf '%s[info]%s  %s\n'  "$_c_blue"   "$_c_reset" "$*" >&2; }
log_success() { printf '%s[ ok ]%s  %s\n'  "$_c_green"  "$_c_reset" "$*" >&2; }
log_warn()    { printf '%s[warn]%s  %s\n'  "$_c_yellow" "$_c_reset" "$*" >&2; }
log_error()   { printf '%s[fail]%s  %s\n'  "$_c_red"    "$_c_reset" "$*" >&2; }

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# run_quiet CMD... - runs a command, capturing its combined stdout+stderr.
# On success the output is discarded, so only our own log lines show. On
# failure the captured output is dumped (so the real error is visible)
# before the original exit status is returned.
run_quiet() {
  local out status=0
  out="$("$@" 2>&1)" || status=$?
  [[ "$status" -ne 0 ]] && printf '%s\n' "$out" >&2
  return "$status"
}

ensure_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "ai-env-setup only supports macOS"
}

# expand_path "~/.codex" -> "/Users/you/.codex"
expand_path() {
  local path="$1"
  printf '%s\n' "${path/#\~/$HOME}"
}

# picker::_save_selection STATE_FILE ID... - persists a picker's selection
# (possibly empty) as that state file's next-run default.
picker::_save_selection() {
  local state_file="$1"
  shift
  mkdir -p "$(dirname "$state_file")"
  # printf with zero args still runs its format string once, writing a
  # stray blank line for an empty selection - truncate instead when there's
  # nothing to write.
  if [[ "$#" -eq 0 ]]; then
    : >"$state_file"
  else
    printf '%s\n' "$@" >"$state_file"
  fi
}

# picker::_previous_selection STATE_FILE -> previously saved ids, one per line
picker::_previous_selection() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0
  cat "$state_file"
}

# picker::_removed NEW_ID... -- OLD_ID... -> prints, one per line, every
# OLD_ID that isn't among NEW_ID - i.e. what a picker's caller deselected
# this run (present in the previous selection, dropped from the new one).
# Callers capture the previous selection (picker::_previous_selection)
# *before* calling picker::select, since that call overwrites the state
# file with the new one. Takes both lists as one arg list split on a
# literal "--" since bash 3.2 has no clean way to pass two arrays in.
picker::_removed() {
  local new_ids=() old_ids=() target=new arg
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
      target=old
      continue
    fi
    if [[ "$target" == "new" ]]; then
      new_ids+=("$arg")
    else
      old_ids+=("$arg")
    fi
  done

  [[ "${#old_ids[@]}" -eq 0 ]] && return 0

  local old_id new_id kept
  for old_id in "${old_ids[@]}"; do
    kept=0
    if [[ "${#new_ids[@]}" -gt 0 ]]; then
      for new_id in "${new_ids[@]}"; do
        [[ "$new_id" == "$old_id" ]] && kept=1 && break
      done
    fi
    [[ "$kept" -eq 0 ]] && printf '%s\n' "$old_id"
  done
}

# picker::select STATE_FILE PROMPT < "label:id" lines (one per option) on
# stdin -> prints the chosen ids, one per line, and persists them to
# STATE_FILE as next run's default. Shared by every interactive
# multi-select in this repo (tools, skills, plugins, mcp).
#
# The previous selection (STATE_FILE) comes up already ticked, so you only
# toggle what's new or changed and confirm. The full option list always
# stays visible.
#
# Respects AI_ENV_SETUP_ALL as a non-interactive override: when set,
# everything is selected without prompting (or requiring gum at all) -
# consistent across every category, unlike a per-category flag/env var.
#
# Preselection goes through gum's --selected, which matches the *displayed*
# label, so gum is NOT given --label-delimiter (combined with it, a
# preselected-but-untouched item silently vanishes from the output in some
# gum versions, and --selected given an id never matches anything). Instead
# gum returns the label text and it is mapped back to an id by exact match
# against a label->id table built here. For that to be a safe 1:1 mapping:
#   - the label is everything before the LAST ":" of each input line, so a
#     colon inside a label can't truncate it;
#   - "," is replaced by ";" in displayed labels (--selected splits on
#     commas, so a comma in a label makes it impossible to preselect);
#   - a label that collides with an earlier one gets " [id]" appended.
picker::select() {
  local state_file="$1" prompt="$2"

  local all_ids=() all_labels=() line id label j
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    id="${line##*:}"
    label="${line%:*}"
    label="${label//,/;}"
    if [[ "${#all_labels[@]}" -gt 0 ]]; then
      for j in "${all_labels[@]}"; do
        [[ "$j" == "$label" ]] && label="$label [$id]" && break
      done
    fi
    all_ids+=("$id")
    all_labels+=("$label")
  done

  if [[ "${#all_ids[@]}" -eq 0 ]]; then
    log_warn "nothing to choose from"
    return 0
  fi

  if [[ -n "${AI_ENV_SETUP_ALL:-}" ]]; then
    log_info "AI_ENV_SETUP_ALL set: selecting everything ($prompt)"
    picker::_save_selection "$state_file" "${all_ids[@]}"
    printf '%s\n' "${all_ids[@]}"
    return 0
  fi

  require_cmd gum

  # One --selected flag per previously-chosen id that still exists in the
  # manifest (an id since removed from it has no row to tick).
  local selected_args=() k
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    for ((k = 0; k < ${#all_ids[@]}; k++)); do
      [[ "${all_ids[$k]}" == "$line" ]] && selected_args+=(--selected "${all_labels[$k]}")
    done
  done < <(picker::_previous_selection "$state_file")

  # gum's toggle key is 'x', not the space bar most checkbox UIs use - and
  # it's easy to miss that in the small footer hint, so spell it out.
  local header="$prompt (x to toggle, enter to confirm)"

  local gum_args=(--no-limit --header "$header")
  [[ "${#selected_args[@]}" -gt 0 ]] && gum_args+=("${selected_args[@]}")

  local raw=()
  while IFS= read -r line; do raw+=("$line"); done < <(gum choose "${gum_args[@]}" "${all_labels[@]}")

  # Defensive: only trust values gum returns that are exactly a known label.
  local chosen_ids=()
  if [[ "${#raw[@]}" -gt 0 ]]; then
    for line in "${raw[@]}"; do
      for ((k = 0; k < ${#all_ids[@]}; k++)); do
        [[ "$line" == "${all_labels[$k]}" ]] && chosen_ids+=("${all_ids[$k]}")
      done
    done
  fi

  if [[ "${#chosen_ids[@]}" -eq 0 ]]; then
    log_warn "nothing selected"
    picker::_save_selection "$state_file"
    return 0
  fi

  picker::_save_selection "$state_file" "${chosen_ids[@]}"
  printf '%s\n' "${chosen_ids[@]}"
}

# backup_and_symlink SOURCE TARGET
# Idempotently makes TARGET a symlink to SOURCE. If TARGET already exists as
# something else, it's moved aside to TARGET.bak once (an existing .bak is
# never overwritten, so first-run backups are never lost).
backup_and_symlink() {
  local source="$1" target="$2"

  [[ -e "$source" ]] || die "symlink source does not exist: $source"

  if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
    log_success "up to date: $target"
    return 0
  fi

  mkdir -p "$(dirname "$target")"

  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -e "$target.bak" ]]; then
      log_warn "$target already backed up, leaving $target.bak as-is"
    else
      mv "$target" "$target.bak"
      log_warn "backed up existing $target -> $target.bak"
    fi
  fi

  ln -s "$source" "$target"
  log_success "linked: $target -> $source"
}

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
