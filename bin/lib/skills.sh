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

# skills::_uninstall SOURCE - removes every currently-installed skill that
# came from this package source, from every agent it's linked into. Looks
# up the exact skill names via `skills list -g --json` (which records each
# skill's origin `source`) rather than relying on the manifest's optional
# `skills:` list, so this works even for packages that installed "whatever
# the repo offers" without ai-env-setup ever recording individual names.
skills::_uninstall() {
  local source="$1"

  # Forget the sync records first: whether or not the removal below
  # succeeds, re-ticking this package later must sync it from scratch.
  synced::drop skills "$source"

  # Written to a real file rather than captured via $(...): piping a large
  # `skills list` straight into command substitution truncates it at
  # exactly 64KB (macOS's default pipe buffer size) - a Node process_exit
  # flushing bug in the `skills` CLI, not something to work around with a
  # bigger buffer.
  local list_file
  list_file="$(mktemp)"
  npx --yes skills list -g --json >"$list_file" 2>/dev/null

  local names=() line
  while IFS= read -r line; do
    [[ -n "$line" ]] && names+=("$line")
  done < <(yq e ".[] | select(.source == \"$source\") | .name" -p=json "$list_file" 2>/dev/null)

  rm -f "$list_file"

  if [[ "${#names[@]}" -eq 0 ]]; then
    log_info "$source: nothing installed to remove"
    return 0
  fi

  log_info "removing deselected skill package: $source (${names[*]})"
  if run_quiet npx --yes skills remove "${names[@]}" --global -y; then
    log_success "removed: $source"
  else
    log_warn "$source: failed to remove some skills (see output above)"
  fi
}

# skills::select -> prints the chosen package sources, one per line, and
# persists them to SKILLS_STATE_FILE as next run's default (same mechanics
# as tools::select, via the shared picker::select helper). The picker label
# is "name — description" (falling back to the bare `source` when a
# package doesn't declare `name`/`description`) - the id underneath is
# always `source`, so a `source` given as a full URL (colons in the scheme)
# would still confuse picker::select's ":"-delimited parsing.
#
# Also uninstalls (skills::_uninstall) any package that was selected last
# run but isn't anymore - including one removed from the manifest entirely,
# since it can no longer appear as an option here either way.
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

  local i source name description label all_options=()
  for ((i = 0; i < count; i++)); do
    source="$(yq e ".packages[$i].source" "$SKILLS_MANIFEST")"

    name="$(yq e ".packages[$i].name" "$SKILLS_MANIFEST")"
    [[ "$name" == "null" ]] && name="$source"

    description="$(yq e ".packages[$i].description" "$SKILLS_MANIFEST")"
    label="$name"
    [[ "$description" != "null" ]] && label="$name — $description"

    all_options+=("$label:$source")
  done

  local previous=() line
  while IFS= read -r line; do [[ -n "$line" ]] && previous+=("$line"); done \
    < <(picker::_previous_selection "$SKILLS_STATE_FILE")

  local chosen=()
  while IFS= read -r line; do chosen+=("$line"); done \
    < <(picker::select "$SKILLS_STATE_FILE" "Which skill packages should ai-env-setup install?" \
      < <(printf '%s\n' "${all_options[@]}"))

  # bash 3.2's `set -u` throws "unbound variable" on "${arr[@]}" for a
  # zero-length array even when properly declared via arr=() - so every
  # array that might be empty here is guarded before expansion (see
  # AGENTS.md). removed_args always has at least the literal "--", so it's
  # always safe to expand.
  local removed_args=()
  [[ "${#chosen[@]}" -gt 0 ]] && removed_args+=("${chosen[@]}")
  removed_args+=("--")
  [[ "${#previous[@]}" -gt 0 ]] && removed_args+=("${previous[@]}")

  local removed=()
  while IFS= read -r line; do [[ -n "$line" ]] && removed+=("$line"); done \
    < <(picker::_removed "${removed_args[@]}")

  if [[ "${#removed[@]}" -gt 0 ]]; then
    for source in "${removed[@]}"; do
      skills::_uninstall "$source"
    done
  fi

  [[ "${#chosen[@]}" -gt 0 ]] && printf '%s\n' "${chosen[@]}"
  return 0
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
  local agent dup entry_hash pending_agents
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

    # Records are per (package, agent): only the agents without an
    # up-to-date record go into this run's `skills add` call, so a new
    # package, an edited entry, or a newly added tool syncs just what's
    # missing. Dedupe agents too (two tool ids could share one agent).
    entry_hash="$(synced::hash_entry "$SKILLS_MANIFEST" ".packages[$i]")"
    pending_agents=()
    for agent in "${agents_list[@]}"; do
      if [[ "${#pending_agents[@]}" -gt 0 ]]; then
        dup=0
        for tool_id in "${pending_agents[@]}"; do
          [[ "$tool_id" == "$agent" ]] && dup=1
        done
        [[ "$dup" -eq 1 ]] && continue
      fi
      if synced::is_current skills "$source" "$agent" "$entry_hash"; then
        log_info "up to date, skipping: $source ($agent)"
      else
        pending_agents+=("$agent")
      fi
    done

    [[ "${#pending_agents[@]}" -eq 0 ]] && continue

    log_info "syncing skill package: $source"

    args=(add "$source" --global --yes)
    [[ "${#skills_list[@]}" -gt 0 ]] && args+=(--skill "${skills_list[@]}")
    args+=(--agent "${pending_agents[@]}")

    local out status=0
    out="$(npx --yes skills "${args[@]}" 2>&1)" || status=$?

    if [[ "$status" -ne 0 ]] || grep -q "Failed to install" <<<"$out"; then
      printf '%s\n' "$out" >&2
      log_warn "$source: some skills failed to install (see output above)"
    else
      for agent in "${pending_agents[@]}"; do
        synced::record skills "$source" "$agent" "$entry_hash"
      done
      log_success "synced: $source"
    fi
  done
}
