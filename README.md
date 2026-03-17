# Skill Browser

A terminal-first tool for discovering, browsing, and installing agent skills across multiple editors. Search your installed skills from Claude Code, Codex, Cursor, OpenCode, and Pi. Explore remote marketplaces to find new ones. Install with a single command.

## Why

Agent skills accumulate fast. Between global installs, project-local skills, compound skills with nested sub-commands, and multiple marketplaces, it becomes impossible to remember what you have or find what you need. The built-in `skills list` is a flat dump with no descriptions or search. Skill Browser gives you:

- **Installed tab**: Browse everything you have, across all editors, with full-text search
- **Explore tab**: Discover new skills from 4 built-in marketplaces (+ your own custom repos)
- **One-command install**: `sb install <name>` or press `i` in the TUI, targeting any editor
- Category, editor, and source filtering
- Compound skill expansion (sub-skills listed inline)
- Natural language trigger extraction (what phrases activate each skill)
- Both a TUI and an optional web interface

## Quick Start

```bash
# Add to your shell profile (~/.zshrc, ~/.bashrc)
alias sb="/path/to/skill-browser-cli.sh"

# Browse installed skills (TUI)
sb

# Explore remote marketplaces for new skills
sb explore

# Search across installed + remote
sb search bigquery

# Install a skill you found
sb install polaris
sb install polaris --editor all    # install to all detected editors
sb install polaris --editor cursor # install to Cursor only

# Show detail for a specific skill
sb show pm-toolkit

# List available marketplaces
sb repos

# Add your own marketplace
sb add-repo myuser/my-skills
sb add-repo myuser/my-skills --path skills  # if skills are in a subdirectory

# Regenerate the index
sb refresh
```

## Discovering New Skills

The Explore tab (`sb explore` or press `Tab` in the TUI) lets you search and browse skills from remote GitHub repos and the Agent Hub. Press `Enter` on any skill to load its full SKILL.md. Press `i` to install it.

### Included Marketplaces

| Marketplace | Type | What's in it |
|-------------|------|-------------|
| [anthropics/skills](https://github.com/anthropics/skills) | Skills | Anthropic's official skill collection |
| [obra/superpowers](https://github.com/obra/superpowers) | Skills | Community superpowers (design, engineering, writing) |
| [levnikolaevich/claude-code-skills](https://github.com/levnikolaevich/claude-code-skills) | Skills | Community-contributed skills |
| [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | Plugins | Official and external Claude Code plugins |
| Shopify Agent Hub | Skills | Shopify-internal skills (requires `skills` CLI) |

Remote data is cached for 4 hours. Press `R` in the Explore tab or run `sb fetch-remote` to refresh.

### Adding Your Own Marketplace

Any GitHub repo that contains SKILL.md files in subdirectories works as a marketplace.

```bash
# Add a skill repo (each subdirectory should contain a SKILL.md)
sb add-repo myuser/my-skills

# If skills live in a subdirectory (e.g. repo/skills/foo/SKILL.md)
sb add-repo myuser/my-skills --path skills

# Add a plugin repo
sb add-repo myuser/my-plugins --plugins plugins

# See all repos (built-in + custom)
sb repos

# Remove a custom repo
sb remove-repo myuser/my-skills
```

Custom repos are stored in `~/.cache/skill-browser/custom-repos.txt` (one per line, `owner/repo:path` format). After adding a repo, run `sb fetch-remote` to pull its skills into the Explore tab.

**Expected repo structure for skills:**
```
my-skills/
  skill-one/
    SKILL.md
  skill-two/
    SKILL.md
```

**Expected repo structure for plugins:**
```
my-plugins/
  plugins/
    plugin-one/
      .claude-plugin/plugin.json
    plugin-two/
      .claude-plugin/plugin.json
```

### CLI vs TUI

| Method | How |
|--------|-----|
| TUI browse | `sb explore`, then `i` to install |
| TUI search | `sb explore`, then `/` and type a query |
| CLI list | `sb explore-list` or `sb explore-list --json` |
| CLI install | `sb install <name>` |
| CLI detail | `sb remote-show <name>` |

## Multi-Editor Support

SKILL.md is a cross-editor standard. The browser auto-detects which editors are installed and scans all of them:

| Editor | Global skills | Project skills | Detection |
|--------|--------------|----------------|-----------|
| Claude Code | `~/.claude/skills/` | `.claude/skills/` | `~/.claude/` exists |
| Codex | `~/.agents/skills/` | `.agents/skills/` | `~/.agents/` or `codex` binary |
| Cursor | `~/.cursor/rules/` | `.cursor/rules/` | `~/.cursor/` exists |
| OpenCode | `~/.config/opencode/skills/` | `.opencode/skills/` | `~/.config/opencode/` or `opencode` binary |
| Pi | `~/.pi/agent/skills/` | `.pi/skills/` | `~/.pi/` exists |

The "Editor" column shows which editor(s) each skill belongs to (e.g. `claude/local`, `codex,cursor/global`). Use the `f` key to filter by editor. When installing, skills go to Claude Code by default, or use `--editor` to target others.

On machines with only Claude Code, behavior is identical to a single-editor setup.

## What Each Column Shows

### Installed Tab

| Column | What it shows |
|--------|---------------|
| **Command** | The `/slash-command` to trigger the skill |
| **Type** | Smart tag inferred from name + description (Product, Engineering, Design, Data, etc.) |
| **Editor** | Which editor(s) + scope (e.g. `claude/local`, `codex,cursor/global`) |
| **Source** | Community (Agent Hub) or Manual (hand-installed) |
| **Description** | Truncated skill description |

### Explore Tab

| Column | What it shows |
|--------|---------------|
| **Name** | Skill or plugin name |
| **Repo** | Source marketplace (anthropics, obra, hub, etc.) |
| **Status** | Whether it's already installed locally |
| **Description** | Truncated description |

## Installation

### Requirements

- bash 4+ (macOS ships bash 3; zsh works fine as the invoking shell)
- python3 (for JSON processing)
- `gh` CLI (for fetching remote skills from GitHub)
- (Optional) Shopify `skills` CLI for Agent Hub access and source detection

### Setup

1. Clone or copy the files:

```bash
git clone https://github.com/morganholland/skills-browser.git
```

2. Make executable:

```bash
chmod +x skills-browser/generate-skill-index.sh skills-browser/skill-browser-cli.sh
```

3. Add a shell alias:

```bash
# In ~/.zshrc or ~/.bashrc
alias sb="/path/to/skills-browser/skill-browser-cli.sh"
```

4. Run it:

```bash
sb
```

The first run auto-generates the index and fetches remote skills. Subsequent runs reuse caches (index: 7-day TTL, remote: 4-hour TTL, editors: 1-hour TTL).

## How It Works

```
detect_editors()
    |-- Checks for Claude Code, Codex, Cursor, OpenCode, Pi
    |-- Detection: directory exists OR binary on PATH
    '-- Outputs editors.json (1-hour TTL)

generate-skill-index.sh
    |-- Reads editors.json
    |-- For each editor, scans global + project skill directories
    |-- Parses SKILL.md (all editors) + .mdc files (Cursor only)
    |-- Adds "editor" and "editors" fields per skill
    |-- Deduplicates across editors
    '-- Outputs skill-index.json + index.html

skill-browser-cli.sh
    |-- Loads skill-index.json + editors.json + remote caches
    |-- Fetches remote skills from GitHub repos + Agent Hub
    '-- Renders interactive TUI via embedded Python
```

### Project Detection

Auto-detects your project by walking up from CWD looking for a `.claude/skills/` folder. Override with:

```bash
SKILL_BROWSER_PROJECT_DIR=/path/to/project sb refresh
```

### Source Detection

If the `skills` CLI is available, the browser calls `skills list` to determine provenance:

- **Community**: Installed from Agent Hub. Tracked, updatable.
- **Manual**: Hand-installed, symlinked, or untracked.

Without the CLI, all skills show as "Manual". Core browsing is unaffected.

### Trigger Extraction

Parses each skill's description for natural language trigger phrases:

- "Triggers on patterns like X, Y, Z"
- "Use when the user says X, Y, or Z"

Displayed on a `triggers:` line below each skill in the detail view.

## CLI Reference

| Command | Description |
|---------|-------------|
| `sb` | Interactive TUI browser |
| `sb explore` | Launch on the Explore tab |
| `sb search <query>` | Pre-filled search in TUI |
| `sb show <name>` | Detail view for an installed skill |
| `sb cats` | Group installed skills by category |
| `sb install <name>` | Install a skill (Claude Code by default) |
| `sb install <name> --editor <e>` | Install to a specific editor (claude, codex, cursor, opencode, pi, all) |
| `sb explore-list [--json] [--type skills\|plugins] [--repo <owner>] [query]` | List remote skills (pipeable) |
| `sb remote-show <name>` | Detail view for a remote skill |
| `sb repos` | List all skill/plugin repos |
| `sb add-repo <owner/repo> [--path dir] [--plugins dir]` | Add a custom marketplace repo |
| `sb remove-repo <owner/repo>` | Remove a custom repo |
| `sb refresh` | Regenerate local index + trust cache |
| `sb fetch-remote` | Refresh remote skill/plugin cache |
| `sb web` | Open the HTML browser locally |
| `sb help` | Show help |

### TUI Keys

| Key | Action |
|-----|--------|
| `j`/`k` or arrows | Navigate |
| `Enter` | Detail view (Installed) or load full SKILL.md (Explore) |
| `/` | Search |
| `f` | Cycle filter (all, skills, plugins, then detected editors) |
| `s` | Toggle sort (type, name) - Installed tab only |
| `i` | Install selected skill - Explore tab only |
| `R` | Refresh remote cache - Explore tab only |
| `Tab` | Switch between Installed and Explore tabs |
| `q` | Quit |
| Mouse scroll | Navigate list or scroll detail panel |

## JSON Schema

### Skill Index (`skill-index.json`)

```json
{
  "generatedAt": "2026-03-16T01:00:00Z",
  "totalSkills": 123,
  "localCount": 27,
  "globalCount": 28,
  "bothCount": 0,
  "pluginCount": 68,
  "skills": [
    {
      "id": "signal-scanner",
      "name": "signal-scanner",
      "description": "Crawl Slack activity from strategic leaders...",
      "category": "workflow",
      "scope": "local",
      "editor": "claude",
      "editors": ["claude", "codex"],
      "provides": ["slack-intelligence"],
      "requires": { "mcps": ["playground-slack-mcp"], "bins": [], "skills": [] },
      "argumentHint": "[handle]",
      "isCompound": false,
      "subSkills": [],
      "triggerCommand": "/signal-scanner",
      "lineCount": 263,
      "skillPath": "/path/to/SKILL.md"
    }
  ]
}
```

### Explore List (`sb explore-list --json`)

```json
[
  {
    "name": "skill-name",
    "type": "skill",
    "repo": "anthropics/skills",
    "owner": "anthropics",
    "description": "What this skill does",
    "url": "https://github.com/anthropics/skills/tree/main/skills/skill-name",
    "installed": false,
    "compatible_editors": ["claude", "codex", "cursor", "opencode", "pi"]
  }
]
```

Plugins have `compatible_editors: ["claude"]`. Skills (SKILL.md) are compatible with all editors.

## Recommended SKILL.md Frontmatter

For best results in the browser, skill authors should include:

```yaml
---
name: my-skill
description: "What this does. Use when the user says 'trigger phrase one', 'trigger phrase two'."
category: core|creation|workflow|self-improvement|utility
provides:
  - capability-tag
requires:
  mcps:
    - some-mcp-server
  bins:
    - some-cli-tool
argument-hint: "[optional] <required>"
---
```
