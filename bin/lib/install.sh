#!/usr/bin/env bash
# Installs the CLI for a selected tool, per its `install` block in
# manifest/tools.yaml (method: npm | brew_cask | brew_formula | none).

tools::install() {
  local id="$1"
  local method
  method="$(tools::field_or_empty "$id" '.install.method')"

  if [[ -z "$method" || "$method" == "none" ]]; then
    log_info "$(tools::name "$id"): no install method declared, skipping install"
    return 0
  fi

  local package version
  package="$(tools::field_or_empty "$id" '.install.package')"
  version="$(tools::field_or_empty "$id" '.install.version')"
  [[ -n "$version" ]] || version="latest"

  case "$method" in
  npm) install::npm "$package" "$version" ;;
  brew_cask) install::brew "$package" --cask ;;
  brew_formula) install::brew "$package" ;;
  *) die "$(tools::name "$id"): unknown install method '$method'" ;;
  esac
}

install::npm() {
  local package="$1" version="$2"

  if ! command -v npm >/dev/null 2>&1; then
    log_info "npm not found, installing node via brew first"
    install::brew node
  fi

  log_info "syncing npm package: $package@$version"
  run_quiet npm install --global "${package}@${version}" || die "failed to install $package via npm"
  log_success "installed: $package@$version"
}

install::brew() {
  local package="$1" cask_flag="${2:-}"

  if brew list $cask_flag "$package" >/dev/null 2>&1; then
    log_info "already installed via brew: $package, checking for updates"
    run_quiet brew upgrade $cask_flag "$package" || true
  else
    log_info "installing via brew: $package"
    run_quiet brew install $cask_flag "$package" || die "failed to install $package via brew"
  fi

  log_success "up to date: $package"
}
