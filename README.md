# ai-env-setup

Keeps my AI tooling installed and configured identically across my Macs.
Safe to re-run any time.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/danielpassos/ai-env-setup/main/install.sh | bash
```

This clones the repo to `~/.ai-env-setup` and runs `bin/setup.sh`, which:

1. installs Homebrew if missing, then `brew bundle` on `Brewfile`
   (this installs `yq` and `gum`, which the steps below depend on)
2. asks which AI tools to configure, via a checkbox prompt - your picks are
   remembered and pre-checked next time
3. for each selected tool: installs its CLI (npm or brew, per
   `manifest/tools.yaml`) and symlinks its declared config/skills into its
   home directory
4. installs the skill packages listed in `manifest/skills.yaml`, via
   `npx skills add`
5. installs the plugins listed in `manifest/plugins.yaml`, via each agent's
   `plugin marketplace add` + install command (Claude Code by default,
   Codex too when a package opts in; only for selected tools)
6. configures the remote MCP servers listed in `manifest/mcp.yaml` for each
   selected tool
7. links itself onto your `PATH` as `ai-env-setup`

## Update

Once installed, just run:

```sh
ai-env-setup
```

It pulls the latest repo state and re-applies everything. Each step only
touches what's drifted from its manifest.

To skip the interactive prompt (e.g. in a script), set
`AI_ENV_SETUP_TOOLS=codex,cursor ai-env-setup` (comma-separated ids from
`manifest/tools.yaml`).

Besides tools, `ai-env-setup` also asks which skill packages
(`manifest/skills.yaml`), plugins (`manifest/plugins.yaml`), and
MCP servers (`manifest/mcp.yaml`) to install/configure. Every picker shows the
full list with your previous pick already ticked: press `x` to toggle an
entry, `enter` to confirm. So after adding something to a manifest you only
tick the new entry and confirm. Anything you untick is uninstalled.

Already-synced work is skipped too. After each successful sync of a skill
package, plugin, or MCP server for a given tool (`claude`, `codex`, ...),
`ai-env-setup` records a hash of that manifest entry in
`~/.config/ai-env-setup/synced`. A re-run logs `up to date, skipping` for a
pair whose entry is unchanged and only syncs new entries, edited entries
(any change to the entry, description included, changes the hash), and
tools you've newly added. Failed syncs are never recorded, so they retry
next run. Deselecting an item drops its records. Cheap steps (brew bundle,
tool install, link/rule syncing) always run.

To ignore the records and re-sync everything (e.g. after removing something
by hand), run `ai-env-setup --resync` (or set `AI_ENV_SETUP_RESYNC=1`).

The first run after upgrading to this behavior has no `synced` file, so it
assumes whatever was in your previous selection is already synced (plugins
only for `claude`, since codex plugins are newer) and records it without
calling any CLI. Entries you hadn't selected before, or that were added to
the manifest since your last run, sync normally. If you had edited an entry
in the manifest between your last real run and that first run, use
`--resync` once.

To select everything instead of picking, set `AI_ENV_SETUP_ALL=1` - it
bypasses every interactive picker (tools, skills, plugins, MCP) and selects
all available options without needing `gum` installed. `AI_ENV_SETUP_TOOLS`
still wins over it for tools if both are set.

## Adding board-specific GitHub issue rules to a project

`ai-env-setup add-github-issue-rules` is different from the rest of this
tool: it's scoped to a single target project, not this machine. Run it from
inside that project's own repo:

```sh
ai-env-setup add-github-issue-rules
```

It resolves the repo's GitHub owner via `gh repo view`, lists that owner's
GitHub Projects (v2) boards and asks which one this repo uses, fetches that
board's real Status/Priority/Size field and option IDs via `gh project
field-list`, and writes/refreshes a marked block in that project's own
`AGENTS.md` - never in this repo. Re-running it re-fetches live and
replaces only that marked block, so board changes (a renamed column, a new
priority option) never go stale. Pass `--owner <login>` and/or `--project
<number>` to skip the auto-detection/picker, e.g. for scripting.

Since Claude Code reads `CLAUDE.md`, not `AGENTS.md`, it also creates a
`CLAUDE.md` with an `@AGENTS.md` import if the target project doesn't have
one yet - otherwise the rules it just wrote would be invisible to Claude
Code. An existing `CLAUDE.md` is never overwritten; if it doesn't already
import `AGENTS.md`, you'll get a warning instead so you can add the import
yourself.

Requires `gh` to be installed and authenticated with the `project` token
scope (`gh auth refresh -s project` if it's missing).

The generated text's wording lives entirely in `bin/lib/templates/*.md`
(`github-issue-rules.md` for the overall skeleton, `field-id-line.md` for
each Status/Priority/Size bullet, `two-step-pattern.md` for the `gh`
command example) - edit those files to reword output, not
`bin/lib/github_rules.sh`. The script only fetches values live from `gh`,
decides which optional templates apply to this board, and fills in each
template's `{{PLACEHOLDER}}` tokens.

The formatting/writing-style rules that don't depend on a board at all
(heredoc escaping, no hard-wrapping issue bodies, the issue body shape) are
not part of this - they're already universal, and live in
`rules/github-issue-style.md` like every other file in `rules/`.

## Layout

```
Brewfile                    # ai-env-setup's own deps: yq, gum (not the AI tools themselves)
manifest/
  tools.yaml                 # the registry: every AI tool ai-env-setup knows about
  skills.yaml                 # skill packages pulled in via `npx skills add`
  plugins.yaml                 # Claude Code / Codex plugins pulled in via each CLI's `plugin` command
  mcp.yaml                     # remote MCP servers configured per-tool
skills/<name>/               # my own skills, shared - any tool's manifest entry can link them in
rules/<topic>.md              # universal, tool-agnostic rules shared across every project - see "Adding a universal rule"
config/<id>/                 # per-tool config not covered by skills/ or rules/ (currently unused - no tool needs one)
bin/
  setup.sh                     # main entrypoint
  lib/
    common.sh                   # logging, symlink+backup helper, path expansion
    brew.sh                      # bootstraps Homebrew, applies Brewfile
    tools.sh                     # reads manifest/tools.yaml, drives the tool selector
    install.sh                    # installs a selected tool's CLI (npm / brew_cask / brew_formula)
    links.sh                      # symlinks a selected tool's declared links into its home dir
    skills.sh                      # installs manifest/skills.yaml via `npx skills add`
    plugins.sh                      # installs manifest/plugins.yaml via `claude`/`codex plugin`
    mcp.sh                           # configures manifest/mcp.yaml per-tool
install.sh                    # curl-pipeable bootstrap (clone + hand off to setup.sh)
```

## Adding an AI tool

Add an entry to `manifest/tools.yaml` - no code changes needed:

```yaml
- id: my-tool
  name: "My Tool"
  home: "~/.my-tool"
  install:
    method: npm          # npm | brew_cask | brew_formula | none
    package: "my-tool-cli"
    version: latest
  links:
    - source: "config/my-tool/AGENTS.md"   # path relative to the repo root
      target: "AGENTS.md"                    # path relative to home
    - source: "skills"                        # the shared skills library
      target: "skills"
      expand: true                              # symlink each child individually, not the whole dir
```

`source` is always relative to the repo root, so it can point at a
tool-specific file under `config/<id>/`, or at a shared root path like
`skills/` that more than one tool links in. `install: null` and `links: []`
are valid - useful for a stub entry you haven't fully wired up yet (see
`cursor` in the current manifest).

## Adding a skill

Create `skills/<name>/SKILL.md`, then add it to whichever tool's `links` list
should pick it up (via the `skills` -> `skills`, `expand: true` entry - see
`manifest/tools.yaml` for tools that already have one). Any tool that later
gains its own skills concept can link the same `skills/` directory in.

## Adding a universal rule

`rules/<topic>.md` holds a behavioral rule that's genuinely universal - true
for every project, not tied to one project's IDs or conventions, and worded
without any one tool's specific syntax (no literal tool-call snippets, no
"the Edit tool" style references). Each file is one topic.

Link it into whichever tools should receive it, in `manifest/tools.yaml`:

- A tool with a directory-of-topics instructions mechanism (like Claude
  Code's `~/.claude/rules/`) uses `expand: true`, same as `skills/` - each
  file becomes its own symlink.
- A tool with a single global instructions file (like Codex CLI's
  `~/.codex/AGENTS.md`) uses `concat: true` - every file under `rules/` is
  concatenated into one generated file, marked at the top as
  generated-do-not-edit. Hand-editing that generated file gets it backed up
  to `<target>.bak` on the next run rather than silently overwritten.

Project-specific content (fixed IDs, a project's own commit-scope list,
etc.) does **not** belong in `rules/` - keep that in the project's own
`AGENTS.md`/`CLAUDE.md` instead.

## Adding an external skill package

Someone else's published skill package (e.g. `vercel-labs/agent-skills`) is
different from a skill you author yourself - add it to
`manifest/skills.yaml` instead of the `skills/` directory:

```yaml
packages:
  - source: "vercel-labs/agent-skills"
    # skills: ["vercel-optimize"]  # optional - install only these skill(s)
    # only: ["claude"]              # optional - install only for these tools (this repo's ids)
```

This runs `npx skills add <source> --global --yes [--skill ...] [--agent ...]`
for every entry on each `ai-env-setup` run - see https://skills.sh. `only`
takes this repo's own tool ids from `manifest/tools.yaml` and translates them
to the `skills` CLI's agent ids under the hood (e.g. `claude` -> `claude-code`,
via each tool's `skills_agent` field) - use it unless you need to target an
agent this repo doesn't otherwise manage, in which case `agents` takes the
CLI's own agent ids directly (pass a bogus `--agent` value to
`npx skills add --help` to see the full accepted list).

## Adding a plugin

Some packages are only ever published as a plugin marketplace, with no
generic `skills add` equivalent - add those to `manifest/plugins.yaml`
instead. Plugins install through each agent's own CLI rather than the
`skills` CLI, so scope is the `agents` field (`claude` and/or `codex`)
rather than `only`. Always set it explicitly on every entry (the sync falls
back to `["claude"]` if omitted, but don't rely on that):

```yaml
packages:
  - agents: ["claude", "codex"]
    marketplace_source: "latent-spaces/brag"
    marketplace: "brag"               # from the repo's .claude-plugin/marketplace.json
    plugin: "brag"                    # from that file's plugins[].name
```

For each agent in `agents` that is also among the tools selected this run
(and whose CLI is installed), this runs `claude plugin marketplace add
<marketplace_source>` then `claude plugin install <plugin>@<marketplace>
-y`, or `codex plugin marketplace add <marketplace_source>` then `codex
plugin add <plugin>@<marketplace>`. All of these are idempotent, so
re-running is a no-op success; a failure for one agent doesn't skip the
other. Only list `codex` for a plugin that ships a Codex manifest.
`marketplace` isn't guessed from `marketplace_source`; read it from the
target repo's own `.claude-plugin/marketplace.json` since it doesn't have to
match the repo name. Deselecting a plugin in the picker tries to uninstall
it from every agent whose CLI is present.

## Adding an MCP server

Add a remote (hosted HTTP) MCP server to `manifest/mcp.yaml`:

```yaml
servers:
  - id: notion
    url: "https://mcp.notion.com/mcp"
    # only: ["claude"]  # optional - only configure for these tools (this repo's ids)
```

Only hosted HTTP endpoints are supported - there's no schema here for a
local/stdio server. `only` works like `manifest/skills.yaml`'s: omit it and
the server is configured for whichever tools you selected this run instead
of every tool.

Each selected tool gets the entry written a different way:

- **Claude Code**: `claude mcp add --transport http --scope user <id> <url>`
- **Codex CLI**: `codex mcp add <id> --url <url>`
- **Cursor**: no MCP CLI exists, so `bin/lib/mcp.sh` writes
  `.mcpServers.<id>.url` into `~/.cursor/mcp.json` directly via `yq`

A tool id with no case in `bin/lib/mcp.sh`'s dispatch (i.e. not one of the
three above) is skipped with a warning rather than failing the run.

If the server requires OAuth (as both `notion` and `atlassian` do), this
only writes the config entry - it can't complete the login for you. Claude
Code and Cursor prompt for it on first use inside the tool; Codex CLI needs
one manual `codex mcp login <id>` after the entry exists.
