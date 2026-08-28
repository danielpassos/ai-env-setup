#!/usr/bin/env bash
# Main entrypoint. Safe to re-run any time - each step only touches what has
# drifted from its manifest. Run directly, or via the `ai-env-setup` command
# once self_link_path has put it on your PATH.
set -euo pipefail

# realpath (not just dirname) so this still finds lib/ when invoked through
# the self_link_path symlink at ~/.local/bin/ai-env-setup - BASH_SOURCE is
# the symlink path itself, and dirname alone doesn't follow it.
script_dir="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
# shellcheck source=lib/brew.sh
source "$script_dir/lib/brew.sh"
# shellcheck source=lib/tools.sh
source "$script_dir/lib/tools.sh"
# shellcheck source=lib/install.sh
source "$script_dir/lib/install.sh"
# shellcheck source=lib/links.sh
source "$script_dir/lib/links.sh"
# shellcheck source=lib/skills.sh
source "$script_dir/lib/skills.sh"
# shellcheck source=lib/plugins.sh
source "$script_dir/lib/plugins.sh"
# shellcheck source=lib/mcp.sh
source "$script_dir/lib/mcp.sh"

self_link_path() {
  local bin_dir="$HOME/.local/bin"
  local link="$bin_dir/ai-env-setup"

  mkdir -p "$bin_dir"
  backup_and_symlink "$script_dir/setup.sh" "$link"

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) log_warn "$bin_dir is not on your PATH - add it to run 'ai-env-setup' directly" ;;
  esac
}

main() {
  ensure_macos

  log_info "ai-env-setup running from $AI_ENV_SETUP_HOME"

  brew::ensure_installed
  brew::bundle

  local selected=() line
  while IFS= read -r line; do selected+=("$line"); done < <(tools::select)

  if [[ "${#selected[@]}" -eq 0 ]]; then
    log_warn "no tools selected - skipping install/config steps"
  else
    local id
    for id in "${selected[@]}"; do
      log_info "== $(tools::name "$id") =="
      tools::install "$id"
      tools::sync_links "$id"
    done
  fi

  if [[ "${#selected[@]}" -gt 0 ]]; then
    skills::sync "${selected[@]}"
    plugins::sync "${selected[@]}"
    mcp::sync "${selected[@]}"
  else
    skills::sync
    plugins::sync
    mcp::sync
  fi

  self_link_path

  log_success "all done"
}

main "$@"
