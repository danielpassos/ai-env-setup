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

  # Options are passed to gum as "label:id" pairs (--label-delimiter) so it
  # displays the friendly name but hands back the stable manifest id
  # directly - no need to round-trip through name-matching afterwards.
  local all_ids=() all_options=() id line
  while IFS= read -r line; do all_ids+=("$line"); done < <(tools::all_ids)
  for id in "${all_ids[@]}"; do
    all_options+=("$(tools::name "$id"):$id")
  done

  # Not using gum's --selected to pre-check the previous pick: in gum 2.0.0
  # a preselected item left untouched is silently dropped from the output
  # instead of being returned, which corrupted the selection. Surface the
  # previous pick as a hint in the header instead, and let the user re-tick
  # it explicitly.
  local previous=() previous_names=()
  while IFS= read -r line; do previous+=("$line"); done < <(tools::_previous_selection)
  if [[ "${#previous[@]}" -gt 0 ]]; then
    for id in "${previous[@]}"; do
      previous_names+=("$(tools::name "$id")")
    done
  fi
  # gum's toggle key is 'x', not the space bar most checkbox UIs use - and
  # it's easy to miss that in the small footer hint, so spell it out.
  local header="Which AI tools should ai-env-setup configure? (x to toggle, enter to confirm)"
  if [[ "${#previous_names[@]}" -gt 0 ]]; then
    header+=" (previously: $(
      IFS=,
      echo "${previous_names[*]}"
    ))"
  fi

  local raw_ids=()
  while IFS= read -r line; do raw_ids+=("$line"); done < <(gum choose --no-limit \
    --header "$header" \
    --label-delimiter=":" \
    "${all_options[@]}")

  # Defensive: only trust values gum returns that are actually known ids.
  local chosen_ids=()
  if [[ "${#raw_ids[@]}" -gt 0 ]]; then
    for id in "${raw_ids[@]}"; do
      for i in "${all_ids[@]}"; do
        [[ "$id" == "$i" ]] && chosen_ids+=("$id")
      done
    done
  fi

  if [[ "${#chosen_ids[@]}" -eq 0 ]]; then
    log_warn "no tools selected, nothing to install/configure"
    tools::_save_selection
    return 0
  fi

  tools::_save_selection "${chosen_ids[@]}"
  printf '%s\n' "${chosen_ids[@]}"
}
