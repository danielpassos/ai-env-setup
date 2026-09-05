#!/usr/bin/env bash
# Configures remote MCP servers (manifest/mcp.yaml) for each selected tool.
# Each entry is a hosted HTTP endpoint - this only writes the client-side
# config pointing at it; OAuth login (where the server requires one) still
# has to happen once, interactively, inside each tool.
#
# claude/codex have their own `mcp add` subcommand, so those write through
# the tool's own CLI (consistent with how tools::install lets each tool
# manage its own install). Cursor has no such CLI, so its entry is written
# directly into ~/.cursor/mcp.json via yq.

MCP_MANIFEST="$AI_ENV_SETUP_HOME/manifest/mcp.yaml"
MCP_STATE_FILE="$HOME/.config/ai-env-setup/selected-mcp"

readonly MCP_MANIFEST MCP_STATE_FILE

mcp::_read_list() {
  local index="$1" field="$2"
  yq e ".servers[$index].${field} // [] | .[]" "$MCP_MANIFEST" 2>/dev/null
}

# mcp::_uninstall_claude/_codex/_cursor ID - each tolerates the server
# never having been configured there (not just "CLI missing"): a deselected
# server was likely only ever synced to some of the three, and re-removing
# an absent one must stay a quiet no-op, not a warning.
mcp::_uninstall_claude() {
  local id="$1"
  command -v claude >/dev/null 2>&1 || return 0

  local out status=0
  out="$(claude mcp remove "$id" 2>&1)" || status=$?

  if [[ "$status" -eq 0 ]]; then
    log_success "claude: removed MCP server $id"
  elif grep -qi "no mcp server named" <<<"$out"; then
    : # never configured there, nothing to do
  else
    printf '%s\n' "$out" >&2
    log_warn "claude: failed to remove MCP server $id (see output above)"
  fi
}

mcp::_uninstall_codex() {
  local id="$1"
  command -v codex >/dev/null 2>&1 || return 0

  local out status=0
  out="$(codex mcp remove "$id" 2>&1)" || status=$?

  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    log_warn "codex: failed to remove MCP server $id (see output above)"
  elif grep -qi "no mcp server named" <<<"$out"; then
    : # never configured there, nothing to do
  else
    log_success "codex: removed MCP server $id"
  fi
}

mcp::_uninstall_cursor() {
  local id="$1"
  local file="$HOME/.cursor/mcp.json"

  [[ -f "$file" ]] || return 0

  if MCP_SYNC_ID="$id" yq -i -o=json 'del(.mcpServers[strenv(MCP_SYNC_ID)])' "$file"; then
    log_success "cursor: removed MCP server $id"
  else
    log_warn "cursor: failed to update $file removing MCP server $id"
  fi
}

# mcp::_uninstall ID - removes a deselected server from all three tool
# integrations. Unlike mcp::sync's per-server `target_ids`, this doesn't
# know (or need to know) which tools it was actually synced to - each
# _uninstall_* is a safe no-op wherever the server was never configured.
mcp::_uninstall() {
  local id="$1"
  log_info "removing deselected MCP server: $id"
  mcp::_uninstall_claude "$id"
  mcp::_uninstall_codex "$id"
  mcp::_uninstall_cursor "$id"
}

# mcp::select -> prints the chosen server ids, one per line, and persists
# them to MCP_STATE_FILE as next run's default (same mechanics as
# tools::select/skills::select/plugins::select, via picker::select).
#
# Also uninstalls (mcp::_uninstall) any server that was selected last run
# but isn't anymore - including one removed from the manifest entirely,
# since it can no longer appear as an option here either way.
#
# mcp::sync reads this same state file to know what to actually sync, so
# this must run before it in the same invocation (see bin/setup.sh).
mcp::select() {
  if [[ ! -f "$MCP_MANIFEST" ]]; then
    return 0
  fi

  local count
  count="$(yq e '.servers | length' "$MCP_MANIFEST")"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local i id all_options=()
  for ((i = 0; i < count; i++)); do
    id="$(yq e ".servers[$i].id" "$MCP_MANIFEST")"
    all_options+=("$id:$id")
  done

  local previous=() line
  while IFS= read -r line; do [[ -n "$line" ]] && previous+=("$line"); done \
    < <(picker::_previous_selection "$MCP_STATE_FILE")

  local chosen=()
  while IFS= read -r line; do chosen+=("$line"); done \
    < <(picker::select "$MCP_STATE_FILE" "Which MCP servers should ai-env-setup configure?" \
      < <(printf '%s\n' "${all_options[@]}"))

  local removed=()
  while IFS= read -r line; do [[ -n "$line" ]] && removed+=("$line"); done \
    < <(picker::_removed "${chosen[@]}" -- "${previous[@]}")

  for id in "${removed[@]}"; do
    mcp::_uninstall "$id"
  done

  printf '%s\n' "${chosen[@]}"
}

mcp::_is_selected() {
  local id="$1" selected
  while IFS= read -r selected; do
    [[ "$selected" == "$id" ]] && return 0
  done < <(picker::_previous_selection "$MCP_STATE_FILE")
  return 1
}

mcp::_sync_claude() {
  local id="$1" url="$2"

  if ! command -v claude >/dev/null 2>&1; then
    log_warn "claude: CLI not found, skipping MCP server $id"
    return 0
  fi

  local out status=0
  out="$(claude mcp add --transport http --scope user "$id" "$url" 2>&1)" || status=$?

  if [[ "$status" -eq 0 ]]; then
    log_success "claude: configured MCP server $id"
  elif grep -qi "already exists" <<<"$out"; then
    log_success "claude: up to date: $id"
  else
    printf '%s\n' "$out" >&2
    log_warn "claude: failed to configure MCP server $id (see output above)"
  fi
}

mcp::_sync_codex() {
  local id="$1" url="$2"

  if ! command -v codex >/dev/null 2>&1; then
    log_warn "codex: CLI not found, skipping MCP server $id"
    return 0
  fi

  local out status=0
  out="$(codex mcp add "$id" --url "$url" 2>&1)" || status=$?

  if [[ "$status" -eq 0 ]]; then
    log_success "codex: configured MCP server $id"
  elif grep -qi "already exists" <<<"$out"; then
    log_success "codex: up to date: $id"
  else
    printf '%s\n' "$out" >&2
    log_warn "codex: failed to configure MCP server $id (see output above)"
  fi
}

mcp::_sync_cursor() {
  local id="$1" url="$2"
  local file="$HOME/.cursor/mcp.json"

  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || printf '{}\n' >"$file"

  if MCP_SYNC_ID="$id" MCP_SYNC_URL="$url" \
    yq -i -o=json '.mcpServers[strenv(MCP_SYNC_ID)].url = strenv(MCP_SYNC_URL)' "$file"; then
    log_success "cursor: configured MCP server $id"
  else
    log_warn "cursor: failed to write $file for MCP server $id"
  fi
}

# mcp::sync SELECTED_TOOL_ID... - selected tool ids from tools::select, used
# as the default target for any server that doesn't declare its own `only`.
# Only syncs servers selected via mcp::select.
mcp::sync() {
  local selected_ids=("$@")

  if [[ ! -f "$MCP_MANIFEST" ]]; then
    log_info "no MCP manifest, skipping"
    return 0
  fi

  local count
  count="$(yq e '.servers | length' "$MCP_MANIFEST")"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    log_info "no MCP servers declared, skipping"
    return 0
  fi

  if [[ ! -f "$MCP_STATE_FILE" ]]; then
    log_warn "no MCP servers selected (run mcp::select first), skipping"
    return 0
  fi

  local i id url only_list line tool_id target_ids
  for ((i = 0; i < count; i++)); do
    id="$(yq e ".servers[$i].id" "$MCP_MANIFEST")"
    url="$(yq e ".servers[$i].url" "$MCP_MANIFEST")"

    if ! mcp::_is_selected "$id"; then
      log_info "not selected, skipping: $id"
      continue
    fi

    only_list=()
    while IFS= read -r line; do [[ -n "$line" ]] && only_list+=("$line"); done \
      < <(mcp::_read_list "$i" "only")

    if [[ "${#only_list[@]}" -gt 0 ]]; then
      target_ids=("${only_list[@]}")
    elif [[ "${#selected_ids[@]}" -gt 0 ]]; then
      target_ids=("${selected_ids[@]}")
    else
      log_warn "$id: no 'only' set and no tools selected this run, skipping"
      continue
    fi

    log_info "syncing MCP server: $id"

    for tool_id in "${target_ids[@]}"; do
      case "$tool_id" in
        claude) mcp::_sync_claude "$id" "$url" ;;
        codex) mcp::_sync_codex "$id" "$url" ;;
        cursor) mcp::_sync_cursor "$id" "$url" ;;
        *) log_warn "$id: tool '$tool_id' has no MCP support wired up, skipping" ;;
      esac
    done
  done
}
