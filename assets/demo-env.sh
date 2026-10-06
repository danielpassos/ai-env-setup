#!/usr/bin/env bash
# Builds the throwaway sandbox that assets/demo.tape records in:
#   assets/demo-env.sh && vhs assets/demo.tape
# HOME is /tmp/h, brew/npx/claude/codex are stubs, so the real machine is
# never touched. Needs: vhs, gifsicle (optional, to shrink the GIF), yq, gum.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
D=/tmp/h
rm -rf "$D"
mkdir -p "$D/bin" "$D/.state" "$D/.ai-env-setup"
git -C "$repo" ls-files | grep -v '^assets/' | (cd "$repo" && tar -cf - -T -) | tar -xf - -C "$D/.ai-env-setup"
for c in npx claude codex; do
  printf '#!/usr/bin/env bash\nsleep 0.1\nexit 0\n' > "$D/bin/$c"
done
cat > "$D/bin/brew" <<'STUB'
#!/usr/bin/env bash
sleep 0.15
M=/tmp/h/.state
case "$1" in
  list) [[ -e "$M/${*: -1}" ]] ;;
  install) touch "$M/${*: -1}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$D"/bin/*
cat > "$D/run.sh" <<'RUN'
export HOME=/tmp/h PATH=/tmp/h/.local/bin:/tmp/h/bin:/usr/bin:/bin:/opt/homebrew/bin PS1="$ "
cd "$HOME"
mkdir -p ~/.local/bin && ln -sf /private/tmp/h/.ai-env-setup/bin/setup.sh ~/.local/bin/ai-env-setup
clear
RUN
