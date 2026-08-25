#!/usr/bin/env bash
# Registry + interactive selector for the AI tools ai-env-setup can manage.
# Adding a tool = adding an entry to manifest/tools.yaml. No code changes.

TOOLS_MANIFEST="$AI_ENV_SETUP_HOME/manifest/tools.yaml"
TOOLS_STATE_DIR="$HOME/.config/ai-env-setup"
TOOLS_STATE_FILE="$TOOLS_STATE_DIR/selected-tools"

readonly TOOLS_MANIFEST TOOLS_STATE_DIR TOOLS_STATE_FILE

tools::_require_manifest() {
  [[ -f "$TOOLS_MANIFEST" ]] || die "tools manifest not found at $TOOLS_MANIFEST"
}

tools::all_ids() {
  tools::_require_manifest
  yq e '.tools[].id' "$TOOLS_MANIFEST"
}

# tools::field ID '.some.yq.path' -> raw yq output for that tool's entry
tools::field() {
  local id="$1" path="$2"
  tools::_require_manifest
  yq e ".tools[] | select(.id == \"$id\") | $path" "$TOOLS_MANIFEST"
}

# Same as tools::field, but normalizes yq's literal "null" string to "".
tools::field_or_empty() {
  local value
  value="$(tools::field "$1" "$2")"
  [[ "$value" == "null" ]] && printf '' || printf '%s' "$value"
}

tools::name() { tools::field_or_empty "$1" '.name'; }
tools::home() { expand_path "$(tools::field_or_empty "$1" '.home')"; }

# This tool's agent id in the `skills` CLI - falls back to the tool's own id
# when no override is declared (true for every tool so far except claude).
tools::skills_agent() {
  local id="$1" override
  override="$(tools::field_or_empty "$id" '.skills_agent')"
  [[ -n "$override" ]] && printf '%s' "$override" || printf '%s' "$id"
}

tools::_save_selection() {
  mkdir -p "$TOOLS_STATE_DIR"
  printf '%s\n' "$@" >"$TOOLS_STATE_FILE"
}

tools::_previous_selection() {
  [[ -f "$TOOLS_STATE_FILE" ]] || return 0
  cat "$TOOLS_STATE_FILE"
}

# tools::select -> prints the chosen tool ids, one per line, and persists
# them as next run's default. Respects AI_ENV_SETUP_TOOLS as a non-interactive
# override (comma-separated ids), e.g. `AI_ENV_SETUP_TOOLS=codex,cursor`.
tools::select() {
  if [[ -n "${AI_ENV_SETUP_TOOLS:-}" ]]; then
    local override_ids=()
    IFS=',' read -ra override_ids <<<"$AI_ENV_SETUP_TOOLS"
    log_info "AI_ENV_SETUP_TOOLS override: ${override_ids[*]}"
    tools::_save_selection "${override_ids[@]}"
    printf '%s\n' "${override_ids[@]}"
    return 0
  fi

  require_cmd gum

  local all_ids=() all_names=() id line
  while IFS= read -r line; do all_ids+=("$line"); done < <(tools::all_ids)
  for id in "${all_ids[@]}"; do
    all_names+=("$(tools::name "$id")")
  done

  local previous=() preselect=()
  while IFS= read -r line; do previous+=("$line"); done < <(tools::_previous_selection)
  for id in "${previous[@]}"; do
    preselect+=("$(tools::name "$id")")
  done
  local preselect_csv
  preselect_csv="$(
    IFS=,
    echo "${preselect[*]}"
  )"

  local chosen_names=()
  while IFS= read -r line; do chosen_names+=("$line"); done < <(gum choose --no-limit \
    --header "Which AI tools should ai-env-setup configure?" \
    --selected="$preselect_csv" \
    "${all_names[@]}")

  if [[ "${#chosen_names[@]}" -eq 0 ]]; then
    log_warn "no tools selected, nothing to install/configure"
    tools::_save_selection
    return 0
  fi

  local chosen_ids=() name
  for name in "${chosen_names[@]}"; do
    for id in "${all_ids[@]}"; do
      [[ "$(tools::name "$id")" == "$name" ]] && chosen_ids+=("$id")
    done
  done

  tools::_save_selection "${chosen_ids[@]}"
  printf '%s\n' "${chosen_ids[@]}"
}
