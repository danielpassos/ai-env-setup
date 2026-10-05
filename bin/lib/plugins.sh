#!/usr/bin/env bash
# Installs plugins listed in manifest/plugins.yaml, via each agent's own
# plugin CLI: `claude plugin marketplace add` + `claude plugin install`, and
# `codex plugin marketplace add` + `codex plugin add`. Distinct from
# bin/lib/skills.sh's `npx skills add` path - some packages are only ever
# published as a plugin marketplace, with no generic skill-copy equivalent.
# Each package's optional `agents` field (claude/codex, default claude)
# picks which agents get it. All commands are idempotent (a re-add/
# re-install is a no-op success), so this is safe on every re-run.

PLUGINS_MANIFEST="$AI_ENV_SETUP_HOME/manifest/plugins.yaml"
PLUGINS_STATE_FILE="$HOME/.config/ai-env-setup/selected-plugins"

readonly PLUGINS_MANIFEST PLUGINS_STATE_FILE

# plugins::_uninstall PLUGIN@MARKETPLACE - uninstalls a plugin that was
# deselected. The state file only stores ids, so a package dropped from the
# manifest no longer has its `agents` list available - instead, try every
# agent whose CLI exists and tolerate failure quietly (the usual cause is
# just "wasn't installed for this agent"). Both CLIs address installed
# plugins the same "plugin@marketplace" way. Leaves the marketplace itself
# registered - other plugins may still use it.
plugins::_uninstall() {
  local id="$1" agent found=0

  synced::drop plugins "$id"

  log_info "removing deselected plugin: $id"
  for agent in claude codex; do
    command -v "$agent" >/dev/null 2>&1 || continue
    found=1
    if [[ "$agent" == "claude" ]]; then
      run_quiet claude plugin uninstall "$id" -y >/dev/null 2>&1 || true
    else
      run_quiet codex plugin remove "$id" >/dev/null 2>&1 || true
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    log_warn "no claude/codex CLI found, can't remove $id"
  else
    log_success "removed: $id"
  fi
}

# plugins::select -> prints the chosen "plugin@marketplace" ids, one per
# line, and persists them to PLUGINS_STATE_FILE as next run's default (same
# mechanics as tools::select/skills::select, via picker::select). The id
# underneath is always "plugin@marketplace" rather than the bare plugin
# name since that's this repo's own uniqueness key for a package (matches
# what `claude plugin install` takes), in case two marketplaces ever ship a
# same-named plugin - the picker label is "name — description" instead
# (falling back to the bare plugin name when a package doesn't declare
# `name`/`description`).
#
# Also uninstalls (plugins::_uninstall) any plugin that was selected last
# run but isn't anymore - including one removed from the manifest entirely,
# since it can no longer appear as an option here either way.
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

  local i marketplace plugin id name description label all_options=()
  for ((i = 0; i < count; i++)); do
    marketplace="$(yq e ".packages[$i].marketplace" "$PLUGINS_MANIFEST")"
    plugin="$(yq e ".packages[$i].plugin" "$PLUGINS_MANIFEST")"
    id="$plugin@$marketplace"

    name="$(yq e ".packages[$i].name" "$PLUGINS_MANIFEST")"
    [[ "$name" == "null" ]] && name="$plugin"

    description="$(yq e ".packages[$i].description" "$PLUGINS_MANIFEST")"
    label="$name"
    [[ "$description" != "null" ]] && label="$name — $description"

    all_options+=("$label:$id")
  done

  local previous=() line
  while IFS= read -r line; do [[ -n "$line" ]] && previous+=("$line"); done \
    < <(picker::_previous_selection "$PLUGINS_STATE_FILE")

  local chosen=()
  while IFS= read -r line; do chosen+=("$line"); done \
    < <(picker::select "$PLUGINS_STATE_FILE" "Which plugins should ai-env-setup install?" \
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
    for id in "${removed[@]}"; do
      plugins::_uninstall "$id"
    done
  fi

  [[ "${#chosen[@]}" -gt 0 ]] && printf '%s\n' "${chosen[@]}"
  return 0
}

plugins::_is_selected() {
  local id="$1" selected
  while IFS= read -r selected; do
    [[ "$selected" == "$id" ]] && return 0
  done < <(picker::_previous_selection "$PLUGINS_STATE_FILE")
  return 1
}

# plugins::_install_for AGENT SOURCE MARKETPLACE PLUGIN - installs one
# plugin for one agent. Returns non-zero on failure (after warning), so the
# caller can carry on with the other agents.
plugins::_install_for() {
  local agent="$1" source="$2" marketplace="$3" plugin="$4"

  if ! run_quiet "$agent" plugin marketplace add "$source"; then
    log_warn "$plugin ($agent): failed to add marketplace $source, skipping"
    return 1
  fi

  if [[ "$agent" == "claude" ]]; then
    run_quiet claude plugin install "$plugin@$marketplace" -y || {
      log_warn "$plugin@$marketplace ($agent): failed to install (see output above)"
      return 1
    }
  else
    run_quiet codex plugin add "$plugin@$marketplace" || {
      log_warn "$plugin@$marketplace ($agent): failed to install (see output above)"
      return 1
    }
  fi
  log_success "synced: $plugin@$marketplace ($agent)"
}

# plugins::sync SELECTED_TOOL_ID... - selected tool ids from tools::select.
# Each package installs for the agents in its `agents` list (default
# claude) that are ALSO among the tools selected this run and whose CLI is
# on PATH. Only syncs plugins selected via plugins::select.
plugins::sync() {
  local selected_ids=("$@") id claude_selected=0 codex_selected=0

  if [[ "${#selected_ids[@]}" -gt 0 ]]; then
    for id in "${selected_ids[@]}"; do
      [[ "$id" == "claude" ]] && claude_selected=1
      [[ "$id" == "codex" ]] && codex_selected=1
    done
  fi

  if [[ "$claude_selected" -eq 0 && "$codex_selected" -eq 0 ]]; then
    log_info "neither claude nor codex selected, skipping plugins"
    return 0
  fi

  if [[ ! -f "$PLUGINS_MANIFEST" ]]; then
    log_info "no plugins manifest, skipping"
    return 0
  fi

  # Per-agent availability: selected this run AND CLI present.
  local claude_ok=0 codex_ok=0
  if [[ "$claude_selected" -eq 1 ]]; then
    if command -v claude >/dev/null 2>&1; then
      claude_ok=1
    else
      log_warn "claude CLI not found, skipping claude plugins"
    fi
  fi
  if [[ "$codex_selected" -eq 1 ]]; then
    if command -v codex >/dev/null 2>&1; then
      codex_ok=1
    else
      log_warn "codex CLI not found, skipping codex plugins"
    fi
  fi

  if [[ "$claude_ok" -eq 0 && "$codex_ok" -eq 0 ]]; then
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

  local i marketplace_source marketplace plugin line agent targets entry_hash announced
  for ((i = 0; i < count; i++)); do
    marketplace_source="$(yq e ".packages[$i].marketplace_source" "$PLUGINS_MANIFEST")"
    marketplace="$(yq e ".packages[$i].marketplace" "$PLUGINS_MANIFEST")"
    plugin="$(yq e ".packages[$i].plugin" "$PLUGINS_MANIFEST")"

    if ! plugins::_is_selected "$plugin@$marketplace"; then
      log_info "not selected, skipping: $plugin@$marketplace"
      continue
    fi

    # `agents` defaults to [claude] when omitted. Empty list guarded below.
    targets=()
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != "null" ]] && targets+=("$line")
    done < <(yq e ".packages[$i].agents // [] | .[]" "$PLUGINS_MANIFEST")
    [[ "${#targets[@]}" -eq 0 ]] && targets=(claude)

    # Records are per (plugin, agent): an agent with an up-to-date record
    # (same manifest entry as last successful sync) is skipped.
    entry_hash="$(synced::hash_entry "$PLUGINS_MANIFEST" ".packages[$i]")"
    announced=0

    for agent in "${targets[@]}"; do
      case "$agent" in
        claude) [[ "$claude_ok" -eq 1 ]] || continue ;;
        codex) [[ "$codex_ok" -eq 1 ]] || continue ;;
        *)
          log_warn "$plugin: unknown agent '$agent' (expected claude/codex), skipping it"
          continue
          ;;
      esac

      if synced::is_current plugins "$plugin@$marketplace" "$agent" "$entry_hash"; then
        log_info "up to date, skipping: $plugin@$marketplace ($agent)"
        continue
      fi

      if [[ "$announced" -eq 0 ]]; then
        log_info "syncing plugin: $plugin@$marketplace"
        announced=1
      fi
      if plugins::_install_for "$agent" "$marketplace_source" "$marketplace" "$plugin"; then
        synced::record plugins "$plugin@$marketplace" "$agent" "$entry_hash"
      fi
    done
  done
}
