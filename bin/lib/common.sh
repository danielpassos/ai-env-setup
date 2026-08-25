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

ensure_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "ai-env-setup only supports macOS"
}

# expand_path "~/.codex" -> "/Users/you/.codex"
expand_path() {
  local path="$1"
  printf '%s\n' "${path/#\~/$HOME}"
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
