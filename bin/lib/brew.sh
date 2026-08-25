#!/usr/bin/env bash
# Ensures Homebrew itself is present, then applies the Brewfile.

brew::ensure_installed() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  log_info "Homebrew not found, installing..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  require_cmd brew
}

brew::bundle() {
  local brewfile="$AI_ENV_SETUP_HOME/Brewfile"
  [[ -f "$brewfile" ]] || die "Brewfile not found at $brewfile"

  log_info "applying Brewfile (this also installs yq, used by later steps)"
  run_quiet brew bundle --file="$brewfile" -q || die "brew bundle failed"
  log_success "brew bundle complete"
}
