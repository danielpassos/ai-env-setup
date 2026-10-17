#!/usr/bin/env bash
# Integration checks use real yq/state logic and never install anything.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export HOME="$test_dir/home"
mkdir -p "$HOME" "$test_dir/manifest/skills"
AI_ENV_SETUP_HOME="$test_dir"
source "$repo/bin/lib/synced.sh"
source "$repo/bin/lib/skills.sh"
log_info() { :; }
log_success() { :; }
log_warn() { :; }
picker::_previous_selection() { [[ ! -f "$1" ]] || cat "$1"; }
tools::skills_agent() { printf '%s\n' "$1"; }
# Losing a category, changing source ids, or rehashing by file location breaks this.
cat > "$test_dir/manifest/skills/z.yaml" <<'YAML'
packages:
  - source: example/z
    name: Last
YAML
cat > "$test_dir/manifest/skills/a.yaml" <<'YAML'
packages:
  - source: example/a
    skills: [one]
YAML
SKILLS_MANIFEST_DATA="$(skills::_load_manifest)"
[[ "$(skills::_query '.packages[].source')" == $'example/a\nexample/z' ]]
old_hash="$(synced::hash_entry "$test_dir/manifest/skills/z.yaml" '.packages[0]')"
[[ "$(synced::hash_entry - '.packages[1]' <<<"$SKILLS_MANIFEST_DATA")" == "$old_hash" ]]
mkdir -p "$SYNCED_STATE_DIR"
printf 'example/z\n' > "$SKILLS_STATE_FILE"
synced::record skills example/z codex "$old_hash"
# A wrongly changed hash/identity would reach this external-install boundary.
npx() { touch "$test_dir/unexpected-install"; return 99; }
skills::sync codex
[[ ! -e "$test_dir/unexpected-install" ]]
[[ "$(cat "$SKILLS_STATE_FILE")" == example/z ]]
[[ "$(wc -l < "$SYNCED_STATE_FILE" | tr -d ' ')" == 1 ]]
# The real selection operation must offer both categories, retain source ids,
# and pass the same state path to the existing picker boundary.
picker::select() {
  [[ "$1" == "$SKILLS_STATE_FILE" ]]
  cat > "$test_dir/options"
  cat "$1"
}
picker::_removed() { :; }
[[ "$(skills::select)" == example/z ]]
[[ "$(cat "$test_dir/options")" == $'example/a:example/a\nLast:example/z' ]]
cat > "$test_dir/manifest/skills/ux.yaml" <<'YAML'
packages:
  - source: example/a
    skills: [two]
YAML
SKILLS_MANIFEST_DATA="$(skills::_load_manifest)"
[[ "$(skills::_query '.packages | length')" == 2 ]]
[[ "$(skills::_query '.packages[] | select(.source == "example/a") | .skills[]')" == $'one\ntwo' ]]
# Conflicting metadata must never silently choose one fragment.
cat > "$test_dir/manifest/skills/ux.yaml" <<'YAML'
packages:
  - source: example/a
    name: Conflicting
    skills: [two]
YAML
if skills::_load_manifest > /dev/null 2>&1; then
  printf 'conflicting package fragments accepted\n' >&2; exit 1
fi
rm "$test_dir/manifest/skills/ux.yaml"
cp "$test_dir/manifest/skills/z.yaml" "$test_dir/manifest/skills/duplicate.yaml"
if skills::_load_manifest > /dev/null 2> "$test_dir/error"; then
  printf 'duplicate sources were accepted\n' >&2; exit 1
fi
rg -q 'duplicate.*example/z' "$test_dir/error"
rm "$test_dir/manifest/skills/duplicate.yaml"
printf 'packages: [\n' > "$test_dir/manifest/skills/broken.yaml"
if skills::_load_manifest > /dev/null 2>&1; then
  printf 'invalid YAML was accepted\n' >&2; exit 1
fi
rm "$test_dir/manifest/skills/broken.yaml" "$test_dir/manifest/skills/a.yaml" "$test_dir/manifest/skills/z.yaml"
SKILLS_MANIFEST_DATA="$(skills::_load_manifest)"
[[ "$(skills::_query '.packages | length')" == 0 ]]
skills::select
skills::sync
printf 'skill manifest checks passed\n'
