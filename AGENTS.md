# ai-env-setup

Personal macOS tool that installs/configures AI CLIs (Claude Code, Codex,
Cursor) identically across machines. Entry point is `bin/setup.sh`, which
sources `bin/lib/*.sh` and is safe to re-run anytime - every step only
touches what's drifted from its manifest. Adding a tool or an external skill
package is a `manifest/*.yaml` edit, not a code change - see README.md for
the schema.

## Recommending skills/tools in this repo

When suggesting a skill package, CLI, or config, evaluate it against a
**clean machine install**, not against what's already active in the current
session. This repo's whole point is reproducing an identical setup on a
fresh machine via `bin/setup.sh` - if a skill only shows up because it
happens to be preinstalled on the machine you're currently running on (e.g.
a Claude Code plugin pulled from `~/.claude/plugins/cache/...` via
`/plugin marketplace`, not this repo's `manifest/skills.yaml`), it will NOT
exist after a clean install and isn't a real recommendation for this repo -
say so explicitly rather than presenting it as available.

Also weigh whether a recommendation works **for every AI tool this repo
manages** (Claude Code, Codex, Cursor, and whichever "universal" agents are
selected - see `manifest/tools.yaml`), not just Claude Code. A package only
installable as a plugin, or scoped with `only`/`agents` to a single tool,
is a narrower recommendation than one that installs cleanly via
`manifest/skills.yaml` for whatever tools the user selects - flag that
narrowing instead of glossing over it.

## Non-obvious gotchas (hard-won this repo's history)

- **macOS's `/bin/bash` is 3.2**, not 4+ (Apple won't ship GPLv3). Under
  `set -u` (used throughout this repo), expanding an *empty* array with
  `"${arr[@]}"` or `"${arr[*]}"` throws `unbound variable` - this has broken
  the interactive tool picker multiple times. Always guard with
  `[[ "${#arr[@]}" -gt 0 ]]` before expanding an array that might be empty;
  never assume bash 4+ semantics (no associative arrays either).

- **`gum choose` quirks**, used by `picker::select` in `bin/lib/common.sh`
  (shared by the tool/skills/plugins/MCP pickers):
  - In `--no-limit` mode the toggle key is **`x`**, not the space bar most
    checkbox UIs use. Easy to miss in the small footer hint - the prompt
    header spells it out explicitly for this reason.
  - Preselecting the previous pick works with `--selected <label>` (one flag
    per item) **as long as `--label-delimiter` is NOT used**. Verified with
    a pty harness on gum 2.0.2: untouched preselected items are returned,
    toggling one off removes it, toggling a new one on adds it, zero
    selections works. Combined with `--label-delimiter`, `--selected <id>`
    never matches (nothing is ticked), and gum 2.0.0 reportedly dropped
    preselected-but-untouched items from the output (2.0.2 returned them
    with `--selected <label>`, but don't depend on it). So `picker::select`
    passes plain labels, and maps the returned label back to an id by exact
    match against a label->id table it builds. To keep that mapping 1:1: the
    label is everything before the *last* `:` of the input line; `,` in a
    label is replaced by `;` (`--selected` splits on commas, so a comma in a
    label can never be preselected); a duplicate label gets ` [id]`
    appended. Don't reintroduce `--label-delimiter` or substring matching.
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

## Plugins (`manifest/plugins.yaml`)

Installed via each agent's own CLI (`claude plugin ...`, `codex plugin ...`),
not the `skills` CLI. Every package sets `agents` (`claude`/`codex`)
explicitly - the code falls back to `[claude]` if omitted, but don't rely on
it. An agent is synced only if also selected that run and its CLI exists. The state file stores just `plugin@marketplace` ids, so
deselect/removal (`plugins::_uninstall`) tries every present CLI and
ignores "not installed" failures. `codex plugin add` has no `-y` flag.

## Sync records (`~/.config/ai-env-setup/synced`)

`bin/lib/synced.sh`. Tab-separated lines `category<TAB>id<TAB>tool<TAB>hash`
(category skills/plugins/mcp; tool = `skills` CLI agent id for skills,
claude/codex for plugins, claude/codex/cursor for MCP; hash = sha256 of the
manifest entry as compact JSON via `yq`). `skills::sync`, `plugins::sync`,
and `mcp::sync` skip a pair with a matching record (`synced::is_current`)
and call `synced::record` only after that pair's sync succeeded - so every
`mcp::_sync_*` / `plugins::_install_for` must return non-zero on failure,
and `skills::sync` records nothing for a call whose output contains
`Failed to install`. Skills are one `skills add` call per package but
records are per agent, and only the agents without a current record are
passed to `--agent`, so adding a tool syncs just that tool. The `_uninstall`
paths call `synced::drop`. `--resync` / `AI_ENV_SETUP_RESYNC=1` makes
`synced::is_current` always fail. Cheap steps are deliberately not tracked.

Migration (state machine in `synced::begin`, called in `bin/setup.sh`
before any picker; seed = `~/.config/ai-env-setup/synced-seed/`): seed
exists -> migration pending, reuse it as-is; no seed + `synced` exists ->
done; neither + previous `selected-tools` exists -> snapshot the previous
`selected-*` files into the seed (built in a temp dir, then renamed); neither
and no `selected-tools` -> fresh machine, nothing seeded. `synced` is always
created by `begin`, so an aborted fresh run isn't mistaken for a previous
selection. Pairs in the seed (item previously selected AND tool previously
selected; plugins only for claude) with no real record are recorded as
synced on first check without calling a CLI; everything else syncs normally.
Only `synced::end` (end of `main`, after the sync phase) removes the seed, so
cancel/`die`/`set -e` mid-run leave it for the next run, and the first run's
overwritten `selected-*` are never re-snapshotted. `synced::drop` also removes
the item from a pending seed. `--resync` ignores the seed but still keeps it
until the run completes.

`codex mcp add` on an OAuth server runs the login flow and blocks until the
browser authorization completes (output is captured, so it looks hung).
Cancelling there skips every later MCP server - it is not a recording bug;
`already exists` from claude/codex is already treated as success.

## Testing without the interactive picker

`AI_ENV_SETUP_TOOLS=claude,codex ./bin/setup.sh` bypasses `gum choose`
entirely (see `tools::select` in `bin/lib/tools.sh`) - use this for any
non-interactive end-to-end verification. It also writes to
`~/.config/ai-env-setup/selected-tools`, the same state file the real
interactive picker reads/writes - clean that up after testing if it wasn't
already reflecting the user's actual preference. The same goes for the
`synced` records. For stubbed end-to-end tests, use a temp `HOME` and fake
`claude`/`codex`/`npx`/`brew` on `PATH` instead of touching the real one.
