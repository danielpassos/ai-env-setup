#!/usr/bin/env bash
# Bootstrap entrypoint - this is the one meant for:
#   curl -fsSL https://raw.githubusercontent.com/danielpassos/ai-env-setup/main/install.sh | bash
#
# Clones (or updates) ai-env-setup into ~/.ai-env-setup and hands off to
# bin/setup.sh, which does the actual, idempotent work.
set -euo pipefail

REPO_URL="${AI_ENV_SETUP_REPO:-https://github.com/danielpassos/ai-env-setup.git}"
INSTALL_DIR="${AI_ENV_SETUP_HOME:-$HOME/.ai-env-setup}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ai-env-setup only supports macOS" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required. Run 'xcode-select --install' and re-run this script." >&2
  exit 1
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "ai-env-setup already present at $INSTALL_DIR, updating..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  echo "cloning ai-env-setup into $INSTALL_DIR..."
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

exec "$INSTALL_DIR/bin/setup.sh"
