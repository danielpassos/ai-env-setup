# ai-env-setup

Personal macOS tool that installs/configures AI CLIs (Claude Code, Codex,
Cursor) identically across machines. Entry point is `bin/setup.sh`, which
sources `bin/lib/*.sh` and is safe to re-run anytime - every step only
touches what's drifted from its manifest. Adding a tool or an external skill
package is a `manifest/*.yaml` edit, not a code change - see README.md for
the schema.

## Non-obvious gotchas (hard-won this repo's history)

- **macOS's `/bin/bash` is 3.2**, not 4+ (Apple won't ship GPLv3). Under
  `set -u` (used throughout this repo), expanding an *empty* array with
  `"${arr[@]}"` or `"${arr[*]}"` throws `unbound variable` - this has broken
  the interactive tool picker multiple times. Always guard with
  `[[ "${#arr[@]}" -gt 0 ]]` before expanding an array that might be empty;
  never assume bash 4+ semantics (no associative arrays either).

- **`gum choose` (v2.0.0) quirks**, used for the interactive tool picker in
  `bin/lib/tools.sh`:
  - In `--no-limit` mode the toggle key is **`x`**, not the space bar most
    checkbox UIs use. Easy to miss in the small footer hint - the prompt
    header spells it out explicitly for this reason.
  - `--selected` (preselecting previously-chosen items) is broken when
    combined with `--label-delimiter`: an item preselected but left
    untouched by the user silently drops out of the final output instead of
    being returned, corrupting the result. Don't rely on `--selected` for
    preselection here - the picker instead shows the previous pick as a text
    hint in the header and lets the user re-tick it.
  - `--label-delimiter=":"` lets options be passed as `"label:value"` pairs
    so gum returns a stable id directly instead of round-tripping a display
    name back to an id via string matching (fragile, was a real bug).
  - Testing the picker non-interactively is hard - `gum choose` needs a real
    controlling terminal (opens `/dev/tty` directly for its TUI, independent
    of stdin/stdout redirection). A Python `pty.fork()` harness with a
    manually-set window size (`TIOCSWINSZ`) and small delays between
    keystrokes is what worked for verifying picker behavior in this repo's
    development; `expect` alone tended to hang.

- **The `skills` CLI** (`npx skills add`, https://skills.sh, driven by
  `bin/lib/skills.sh` from `manifest/skills.yaml`) treats agents in two
  groups: "universal" agents (Codex, Gemini CLI, Antigravity, etc.) read
  skills directly from a shared store at `~/.agents/skills/<name>`; a
  smaller set (Claude Code, Junie, Pi) get a full **copy** placed into their
  own directory (e.g. `~/.claude/skills/<name>`) - despite the CLI's install
  summary calling this "symlink →", it is not an OS symlink. The only real
  OS symlinks under `~/.claude/skills/` or `~/.codex/skills/` are this
  repo's own hand-authored skills (`skills/`), linked in by
  `bin/lib/links.sh` via `manifest/tools.yaml`.
  - If a `manifest/skills.yaml` package omits `only`/`agents`,
    `bin/lib/skills.sh` scopes the install to whichever tools were selected
    *in that run* - never to every agent the `skills` CLI happens to know
    about (~77 on a well-used machine). This was itself a bug fix; don't
    remove the fallback-to-empty-and-skip behavior when nothing's selected.
  - `~/.agents` may itself be a symlink into a cloud-synced folder (observed
    pointing into Dropbox on the primary dev machine) and has been seen to
    intermittently vanish mid-session. Don't assume `~/.agents/skills`
    is always present or stable.

- **Verbosity**: `run_quiet()` in `bin/lib/common.sh` captures a command's
  combined output and only prints it on non-zero exit, so successful runs
  show just this repo's own `[info]/[ok]` lines. The `skills` CLI is a
  special case - it can exit 0 while individual per-agent installs failed
  (e.g. an agent that "does not support global skill installation"), so
  `bin/lib/skills.sh` also greps captured output for `"Failed to install"`
  rather than trusting the exit code alone.

## Testing without the interactive picker

`AI_ENV_SETUP_TOOLS=claude,codex ./bin/setup.sh` bypasses `gum choose`
entirely (see `tools::select` in `bin/lib/tools.sh`) - use this for any
non-interactive end-to-end verification. It also writes to
`~/.config/ai-env-setup/selected-tools`, the same state file the real
interactive picker reads/writes - clean that up after testing if it wasn't
already reflecting the user's actual preference.
