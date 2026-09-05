#!/usr/bin/env bash
# Installs Claude Code plugins listed in manifest/plugins.yaml, via
# `claude plugin marketplace add` + `claude plugin install`. Distinct from
# bin/lib/skills.sh's `npx skills add` path - some packages are only ever
# published as a Claude Code plugin marketplace, with no generic
# skill-copy equivalent. Both commands are idempotent (a re-add/re-install
# is a no-op success), so this is safe on every re-run.

PLUGINS_MANIFEST="$AI_ENV_SETUP_HOME/manifest/plugins.yaml"
PLUGINS_STATE_FILE="$HOME/.config/ai-env-setup/selected-plugins"

readonly PLUGINS_MANIFEST PLUGINS_STATE_FILE

# plugins::select -> prints the chosen "plugin@marketplace" ids, one per
# line, and persists them to PLUGINS_STATE_FILE as next run's default (same
# mechanics as tools::select/skills::select, via picker::select). Uses
# "plugin@marketplace" rather than the bare plugin name since that's this
# repo's own uniqueness key for a package (matches what `claude plugin
# install` takes), in case two marketplaces ever ship a same-named plugin.
#
# plugins::sync reads this same state file to know what to actually sync,
# so this must run before it in the same invocation (see bin/setup.sh).
plugins::select() {
  if [[ ! -f "$PLUGINS_MANIFEST" ]]; then
    return 0
  fi

  local count
  count="$(yq e '.packages | length' "$PLUGINS_MANIFEST")"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local i marketplace plugin id all_options=()
  for ((i = 0; i < count; i++)); do
    marketplace="$(yq e ".packages[$i].marketplace" "$PLUGINS_MANIFEST")"
    plugin="$(yq e ".packages[$i].plugin" "$PLUGINS_MANIFEST")"
    id="$plugin@$marketplace"
    all_options+=("$id:$id")
  done

  picker::select "$PLUGINS_STATE_FILE" "Which Claude Code plugins should ai-env-setup install?" \
    < <(printf '%s\n' "${all_options[@]}")
}

plugins::_is_selected() {
  local id="$1" selected
  while IFS= read -r selected; do
    [[ "$selected" == "$id" ]] && return 0
  done < <(picker::_previous_selection "$PLUGINS_STATE_FILE")
  return 1
}

# plugins::sync SELECTED_TOOL_ID... - selected tool ids from tools::select.
# No-ops unless "claude" is among them: plugin marketplaces are a Claude
# Code concept with no equivalent for other tools, so there's nothing to
# scope this to besides "was claude selected this run". Only syncs plugins
# selected via plugins::select.
plugins::sync() {
  local selected_ids=("$@") id claude_selected=0

  if [[ "${#selected_ids[@]}" -gt 0 ]]; then
    for id in "${selected_ids[@]}"; do
      [[ "$id" == "claude" ]] && claude_selected=1
    done
  fi

  if [[ "$claude_selected" -eq 0 ]]; then
    log_info "claude not selected, skipping plugins"
    return 0
  fi

  if [[ ! -f "$PLUGINS_MANIFEST" ]]; then
    log_info "no plugins manifest, skipping"
    return 0
  fi

  if ! command -v claude >/dev/null 2>&1; then
    log_warn "claude CLI not found, skipping plugins"
    return 0
  fi

  local count
  count="$(yq e '.packages | length' "$PLUGINS_MANIFEST")"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    log_info "no plugins declared, skipping"
    return 0
  fi

  if [[ ! -f "$PLUGINS_STATE_FILE" ]]; then
    log_warn "no plugins selected (run plugins::select first), skipping"
    return 0
  fi

  local i marketplace_source marketplace plugin
  for ((i = 0; i < count; i++)); do
    marketplace_source="$(yq e ".packages[$i].marketplace_source" "$PLUGINS_MANIFEST")"
    marketplace="$(yq e ".packages[$i].marketplace" "$PLUGINS_MANIFEST")"
    plugin="$(yq e ".packages[$i].plugin" "$PLUGINS_MANIFEST")"

    if ! plugins::_is_selected "$plugin@$marketplace"; then
      log_info "not selected, skipping: $plugin@$marketplace"
      continue
    fi

    log_info "syncing plugin: $plugin@$marketplace"

    if ! run_quiet claude plugin marketplace add "$marketplace_source"; then
      log_warn "$plugin: failed to add marketplace $marketplace_source, skipping"
      continue
    fi

    if run_quiet claude plugin install "$plugin@$marketplace" -y; then
      log_success "synced: $plugin@$marketplace"
    else
      log_warn "$plugin@$marketplace: failed to install (see output above)"
    fi
  done
}
