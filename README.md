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
5. installs the Claude Code plugins listed in `manifest/plugins.yaml`, via
   `claude plugin marketplace add` + `claude plugin install` (only when
   `claude` is among the selected tools)
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
(`manifest/skills.yaml`), Claude Code plugins (`manifest/plugins.yaml`), and
MCP servers (`manifest/mcp.yaml`) to install/configure - each remembers your
last pick as next run's default the same way the tools picker does.

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

Requires `gh` to be installed and authenticated with the `project` token
scope (`gh auth refresh -s project` if it's missing).

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
  plugins.yaml                 # Claude Code plugins pulled in via `claude plugin install`
  mcp.yaml                     # remote MCP servers configured per-tool
skills/<name>/               # my own skills, shared - any tool's manifest entry can link them in
rules/<topic>.md              # universal, tool-agnostic rules shared across every project - see "Adding a universal rule"
config/
  claude/                     # config specific to Claude Code, mirrored into ~/.claude/
    CLAUDE.md
  codex/                       # same idea for Codex, currently install-only (no links yet)
  cursor/                       # stub - Cursor isn't installed/configured yet
bin/
  setup.sh                     # main entrypoint
  lib/
    common.sh                   # logging, symlink+backup helper, path expansion
    brew.sh                      # bootstraps Homebrew, applies Brewfile
    tools.sh                     # reads manifest/tools.yaml, drives the tool selector
    install.sh                    # installs a selected tool's CLI (npm / brew_cask / brew_formula)
    links.sh                      # symlinks a selected tool's declared links into its home dir
    skills.sh                      # installs manifest/skills.yaml via `npx skills add`
    plugins.sh                      # installs manifest/plugins.yaml via `claude plugin install`
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

## Adding a Claude Code plugin

Some packages are only ever published as a Claude Code plugin marketplace,
with no generic `skills add` equivalent - add those to
`manifest/plugins.yaml` instead. Unlike `manifest/skills.yaml`, this is
inherently Claude-Code-only (plugin marketplaces are a Claude Code concept),
so there's no `only`/`agents` field to widen scope to other tools:

```yaml
packages:
  - marketplace_source: "multica-ai/andrej-karpathy-skills"
    marketplace: "karpathy-skills"    # from the repo's .claude-plugin/marketplace.json
    plugin: "andrej-karpathy-skills"  # from that file's plugins[].name
```

This runs `claude plugin marketplace add <marketplace_source>` then
`claude plugin install <plugin>@<marketplace> -y` for every entry, but only
when `claude` is among the tools selected this run - both commands are
idempotent, so re-running is a no-op success. `marketplace` isn't guessed
from `marketplace_source`; read it from the target repo's own
`.claude-plugin/marketplace.json` since it doesn't have to match the repo
name.

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
