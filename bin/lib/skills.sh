#!/usr/bin/env bash
# Installs external skill packages (via `npx skills add`, https://skills.sh)
# listed in manifest/skills.yaml. A package's declared `only` (this repo's
# tool ids) or `agents` (the CLI's own agent ids) list takes precedence when
# set; otherwise it defaults to whichever tools were selected in this run,
# so a bare package entry never reaches past the tools ai-env-setup actually
# manages into every agent the `skills` CLI happens to know about.

SKILLS_MANIFEST="$AI_ENV_SETUP_HOME/manifest/skills.yaml"
SKILLS_STATE_FILE="$HOME/.config/ai-env-setup/selected-skills"

readonly SKILLS_MANIFEST SKILLS_STATE_FILE

skills::_read_list() {
  local index="$1" field="$2"
  yq e ".packages[$index].${field} // [] | .[]" "$SKILLS_MANIFEST" 2>/dev/null
}

# skills::select -> prints the chosen package sources, one per line, and
# persists them to SKILLS_STATE_FILE as next run's default (same mechanics
# as tools::select, via the shared picker::select helper). Labels and ids
# are both the package's `source` since packages have no separate display
# name - fine for the "owner/repo" sources every package uses today, but a
# `source` given as a full URL (colons in the scheme) would confuse
# picker::select's ":"-delimited parsing.
#
# skills::sync reads this same state file to know what to actually sync, so
# this must run before it in the same invocation (see bin/setup.sh).
skills::select() {
  if [[ ! -f "$SKILLS_MANIFEST" ]]; then
    return 0
  fi

  local count
  count="$(yq e '.packages | length' "$SKILLS_MANIFEST")"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local i source all_options=()
  for ((i = 0; i < count; i++)); do
    source="$(yq e ".packages[$i].source" "$SKILLS_MANIFEST")"
    all_options+=("$source:$source")
  done

  picker::select "$SKILLS_STATE_FILE" "Which skill packages should ai-env-setup install?" \
    < <(printf '%s\n' "${all_options[@]}")
}

skills::_is_selected() {
  local source="$1" selected
  while IFS= read -r selected; do
    [[ "$selected" == "$source" ]] && return 0
  done < <(picker::_previous_selection "$SKILLS_STATE_FILE")
  return 1
}

# skills::sync SELECTED_TOOL_ID... - selected tool ids from tools::select,
# used as the default agent scope for any package that doesn't declare its
# own `only`/`agents`. Only syncs packages selected via skills::select.
skills::sync() {
  local selected_ids=("$@")

  if [[ ! -f "$SKILLS_MANIFEST" ]]; then
    log_info "no skills manifest, skipping"
    return 0
  fi

  local count
  count="$(yq e '.packages | length' "$SKILLS_MANIFEST")"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    log_info "no skill packages declared, skipping"
    return 0
  fi

  if [[ ! -f "$SKILLS_STATE_FILE" ]]; then
    log_warn "no skill packages selected (run skills::select first), skipping"
    return 0
  fi

  if ! command -v npx >/dev/null 2>&1; then
    log_info "npx not found, installing node via brew first"
    install::brew node
  fi

  local i source line skills_list only_list agents_list tool_id args
  for ((i = 0; i < count; i++)); do
    source="$(yq e ".packages[$i].source" "$SKILLS_MANIFEST")"

    if ! skills::_is_selected "$source"; then
      log_info "not selected, skipping: $source"
      continue
    fi

    skills_list=()
    while IFS= read -r line; do [[ -n "$line" ]] && skills_list+=("$line"); done \
      < <(skills::_read_list "$i" "skills")

    only_list=()
    while IFS= read -r line; do [[ -n "$line" ]] && only_list+=("$line"); done \
      < <(skills::_read_list "$i" "only")

    agents_list=()
    while IFS= read -r line; do [[ -n "$line" ]] && agents_list+=("$line"); done \
      < <(skills::_read_list "$i" "agents")

    if [[ "${#only_list[@]}" -gt 0 ]]; then
      [[ "${#agents_list[@]}" -gt 0 ]] && log_warn "$source: both 'only' and 'agents' set, using 'only'"
      agents_list=()
      for tool_id in "${only_list[@]}"; do
        agents_list+=("$(tools::skills_agent "$tool_id")")
      done
    elif [[ "${#agents_list[@]}" -eq 0 ]]; then
      if [[ "${#selected_ids[@]}" -eq 0 ]]; then
        log_warn "$source: no 'only'/'agents' set and no tools selected this run, skipping"
        continue
      fi
      for tool_id in "${selected_ids[@]}"; do
        agents_list+=("$(tools::skills_agent "$tool_id")")
      done
    fi

    log_info "syncing skill package: $source"

    args=(add "$source" --global --yes)
    [[ "${#skills_list[@]}" -gt 0 ]] && args+=(--skill "${skills_list[@]}")
    [[ "${#agents_list[@]}" -gt 0 ]] && args+=(--agent "${agents_list[@]}")

    local out status=0
    out="$(npx --yes skills "${args[@]}" 2>&1)" || status=$?

    if [[ "$status" -ne 0 ]] || grep -q "Failed to install" <<<"$out"; then
      printf '%s\n' "$out" >&2
      log_warn "$source: some skills failed to install (see output above)"
    else
      log_success "synced: $source"
    fi
  done
}
