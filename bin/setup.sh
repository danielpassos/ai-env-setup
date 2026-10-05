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
# shellcheck source=lib/synced.sh
source "$script_dir/lib/synced.sh"
# shellcheck source=lib/skills.sh
source "$script_dir/lib/skills.sh"
# shellcheck source=lib/plugins.sh
source "$script_dir/lib/plugins.sh"
# shellcheck source=lib/mcp.sh
source "$script_dir/lib/mcp.sh"
# shellcheck source=lib/github_rules.sh
source "$script_dir/lib/github_rules.sh"

usage() {
  cat <<'EOF'
ai-env-setup - keeps AI tooling installed and configured identically
across machines. Safe to re-run any time.

USAGE:
  ai-env-setup [--resync]
  ai-env-setup [-h|--help]
  ai-env-setup add-github-issue-rules [--owner <login>] [--project <number>]

With no arguments, runs the full setup flow: installs Homebrew deps, lets
you pick which AI tools/skills/plugins/MCP servers to configure (your last
picks come up already ticked - toggle what changed with x, enter to
confirm), and applies manifest/*.yaml to this machine.

Skill packages, plugins and MCP servers that are already synced (same
manifest entry, same target tool as last time) are skipped, tracked in
~/.config/ai-env-setup/synced. New, edited, or newly-applicable entries
sync as normal.

OPTIONS:
  --resync                            Ignore the synced records and re-sync
                                       every selected skill package, plugin
                                       and MCP server (e.g. after removing
                                       something by hand). Same as
                                       AI_ENV_SETUP_RESYNC=1.

ENVIRONMENT VARIABLES (bypass the interactive pickers):
  AI_ENV_SETUP_TOOLS=<id>[,<id>...]   Skip the tool picker; select these
                                       tool ids from manifest/tools.yaml
                                       (e.g. claude,codex).
  AI_ENV_SETUP_ALL=1                  Select everything in every picker
                                       (tools, skills, plugins, MCP) with
                                       no gum/TTY required.
  AI_ENV_SETUP_RESYNC=1               Same as --resync.

SUBCOMMANDS:
  add-github-issue-rules [--owner <login>] [--project <number>]
      Run from inside a target project's own repo (not this one). Discovers
      that repo's real GitHub Projects (v2) board via `gh` and writes a
      freshly-fetched, board-specific rules block into that project's own
      AGENTS.md. --owner/--project skip the auto-detection/interactive
      picker. Requires `gh`, authenticated with the 'project' token scope.

See README.md in this repo for the full manifest schema and more detail.
EOF
}

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
  # Leading flags first (only --resync today), then an optional subcommand.
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --resync)
        export AI_ENV_SETUP_RESYNC=1
        shift
        ;;
      add-github-issue-rules)
        shift
        github_rules::run "$@"
        exit $?
        ;;
      *)
        die "unknown command: $1 (see 'ai-env-setup --help')"
        ;;
    esac
  done

  ensure_macos

  log_info "ai-env-setup running from $AI_ENV_SETUP_HOME"

  brew::ensure_installed
  brew::bundle

  # Must run before any picker: on the one-time migration run it snapshots
  # the previous selection that the pickers are about to overwrite.
  synced::begin

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

    skills::select >/dev/null
    plugins::select >/dev/null
    mcp::select >/dev/null

    skills::sync "${selected[@]}"
    plugins::sync "${selected[@]}"
    mcp::sync "${selected[@]}"
  fi

  synced::end
  self_link_path

  log_success "all done"
}

main "$@"
