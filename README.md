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
5. links itself onto your `PATH` as `ai-env-setup`

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

## Layout

```
Brewfile                    # ai-env-setup's own deps: yq, gum (not the AI tools themselves)
manifest/
  tools.yaml                 # the registry: every AI tool ai-env-setup knows about
  skills.yaml                 # skill packages pulled in via `npx skills add`
skills/<name>/               # my own skills, shared - any tool's manifest entry can link them in
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
