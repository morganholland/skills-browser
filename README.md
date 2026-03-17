# Skill Browser

A terminal-first discovery tool for agent skills across multiple editors. Browse, search, filter, and explore all installed skills from Claude Code, Codex, Cursor, OpenCode, and Pi, including sub-skills inside compound skills.

## Why

Claude Code skills accumulate fast. Between global installs, project-local skills, compound skills with nested sub-commands, and the Shopify Agent Hub, it becomes impossible to remember what you have or what triggers them. The built-in `skills list` is a flat dump with no descriptions or search. Skill Browser gives you:

- Full-text search across names, descriptions, sub-skills, and trigger phrases
- Category, scope, and source filtering
- Compound skill expansion (sub-skills listed inline under parent)
- Natural language trigger extraction (what phrases activate each skill)
- Source tracking: Community (Agent Hub) vs Manual (hand-installed)
- Detailed views with requirements, provides, and trigger commands
- Both a CLI and an optional web interface

## Quick Start

```bash
# Add to your shell profile (~/.zshrc, ~/.bashrc)
alias sb="/path/to/skill-browser-cli.sh"

# List all skills
sb

# Search (any unknown command is treated as a search)
sb morning
sb search bigquery

# Show detail for a specific skill
sb show pm-toolkit

# Group by category
sb cats

# Filter by scope, category, or source
sb list local
sb list workflow
sb list community

# Regenerate the index
sb refresh

# Open the web UI locally
sb web
```

## What Each Column Shows

The list view shows five columns per skill:

| Column | What it shows |
|--------|---------------|
| **Command** | The `/slash-command` to trigger the skill |
| **Category** | core, creation, workflow, self-improvement, or utility (color-coded) |
| **Editor** | Which editor(s) the skill is installed in + scope (e.g. `claude/local`, `codex,cursor/global`) |
| **Source** | Community (installed from Agent Hub via `skills get`) or Manual (hand-installed/untracked) |
| **Description** | First 2 lines of the skill description, wrapped to fit terminal |

Below the main row, you'll see:
- **triggers:** Natural language phrases extracted from the description that will activate the skill
- **Sub-skills** (for compound skills): Indented tree of sub-commands with descriptions

## Installation

### Requirements

- bash 4+ (macOS ships bash 3; zsh works fine as the invoking shell)
- python3 (for JSON processing)
- Claude Code with skills installed
- (Optional) Shopify `skills` CLI for source/trust detection

### Setup

1. Copy the three files to a directory:

```
skill-browser/
  generate-skill-index.sh       # Index generator
  skill-browser-cli.sh          # CLI entry point
  skill-browser-template.html   # Web UI template (optional)
```

2. Make them executable:

```bash
chmod +x generate-skill-index.sh skill-browser-cli.sh
```

3. Add a shell alias:

```bash
# In ~/.zshrc or ~/.bashrc
alias sb="/path/to/skill-browser-cli.sh"
```

4. Run it:

```bash
sb
```

The first run auto-generates the index. Subsequent runs reuse the cached index (auto-refreshes after 7 days, or run `sb refresh` manually).

### Optional: Claude Code slash command

To trigger via `/skill-browser` inside Claude Code:

```bash
mkdir -p .claude/skills/skill-browser
# Copy SKILL.md from skills/skill-browser/SKILL.md
```

## How It Works

```
detect_editors()
    |-- Checks for Claude Code, Codex, Cursor, OpenCode, Pi
    |-- Detection: directory exists (~/.claude/, ~/.cursor/, etc.) OR binary on PATH
    '-- Outputs editors.json (1-hour TTL)

generate-skill-index.sh
    |
    |-- Reads editors.json for all detected editors
    |-- For each editor, scans global + project skill directories:
    |     Claude Code: ~/.claude/skills/  + .claude/skills/
    |     Codex:       ~/.agents/skills/  + .agents/skills/
    |     Cursor:      ~/.cursor/rules/   + .cursor/rules/
    |     OpenCode:    ~/.config/opencode/skills/ + .opencode/skills/
    |     Pi:          ~/.pi/agent/skills/ + .pi/skills/
    |-- Parses SKILL.md (all editors) + .mdc files (Cursor only)
    |-- Adds "editor" and "editors" fields to each skill
    |-- Deduplicates: skills in multiple editors get editors: ["claude","codex"]
    |
    |-- Outputs ~/.cache/skill-browser/skill-index.json
    '-- Builds  ~/.cache/skill-browser/index.html (if template exists)

skill-browser-cli.sh
    |
    |-- Auto-generates index if missing or stale (>7 days)
    |-- Calls `skills list` to build a trust/source cache (1-hour TTL)
    |-- Reads skill-index.json + editors.json
    '-- Renders colored terminal output via embedded Python
```

### Multi-Editor Support

SKILL.md is a cross-editor standard. The browser auto-detects which editors are installed and scans all of them:

| Editor | Global skills | Project skills | Detection |
|--------|--------------|----------------|-----------|
| Claude Code | `~/.claude/skills/` | `.claude/skills/` | `~/.claude/` exists |
| Codex | `~/.agents/skills/` | `.agents/skills/` | `~/.agents/` or `codex` binary |
| Cursor | `~/.cursor/rules/` | `.cursor/rules/` | `~/.cursor/` exists |
| OpenCode | `~/.config/opencode/skills/` | `.opencode/skills/` | `~/.config/opencode/` or `opencode` binary |
| Pi | `~/.pi/agent/skills/` | `.pi/skills/` | `~/.pi/` exists |

The "Editor" column shows which editor(s) each skill belongs to (e.g. `claude/local`, `codex,cursor/global`). Use the `f` key to filter by editor. When installing from the Explore tab, skills are installed to Claude Code by default, or use `--editor` to target other editors.

On machines with only Claude Code, the behavior is unchanged from previous versions.

### Project Detection

The generator auto-detects your Claude Code project by walking up from the current directory looking for a `.claude/skills/` folder. Override with:

```bash
SKILL_BROWSER_PROJECT_DIR=/path/to/project sb refresh
```

If no project is found, only global skills are indexed.

### Source Detection

If the Shopify `skills` CLI is installed, the browser calls `skills list` to determine each skill's provenance:

- **Community**: Installed from the Shopify Agent Hub via `skills get`. Tracked, updatable.
- **Manual**: Installed by hand, symlinked, or otherwise untracked by the skills CLI.

The trust cache is stored at `/tmp/skill-browser/trust-cache.json` with a 1-hour TTL. If the `skills` CLI is not available, all skills show as "Manual".

### Trigger Extraction

The CLI parses each skill's description looking for natural language trigger phrases. It recognizes patterns like:

- "Triggers on patterns like X, Y, Z"
- "Use when the user says X, Y, or Z"

These are displayed on a `triggers:` line below each skill. This is especially useful for Claude Code itself, so it can match user intent to the right skill.

## Sharing with Others

### What works today

The CLI and index generator are fully portable. Anyone with Claude Code can:

1. Copy the three script files to a directory
2. `chmod +x` them
3. Add the `sb` alias
4. Run `sb` from inside any Claude Code project

It auto-detects their project root and scans their installed skills. No configuration needed. If they have the Shopify `skills` CLI, source detection works automatically. If not, everything still works (source just shows "Manual" for all).

### Packaging for distribution

```bash
mkdir skill-browser-dist
cp generate-skill-index.sh skill-browser-dist/
cp skill-browser-cli.sh skill-browser-dist/
cp skill-browser-template.html skill-browser-dist/  # optional, for web UI
```

Share the folder. Recipients add the alias and they're done.

### What needs adjustment for non-Shopify users

- **Web UI deployment**: `quick deploy` is Shopify-internal. Others use `sb web` to open the HTML locally, or deploy to their own static hosting.
- **Source detection**: The `skills` CLI is Shopify's Agent Hub client. Without it, source shows "Manual" for all skills. The core browsing experience is unaffected.

### Recommended SKILL.md frontmatter

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

## CLI Reference

| Command | Description |
|---------|-------------|
| `sb` | List all skills with descriptions, triggers, source, and sub-skills |
| `sb search <query>` | Full-text search across names, descriptions, sub-skills |
| `sb show <name>` | Detailed view: full description, triggers, requirements, sub-skills |
| `sb cats` | Group skills by category with colored headers |
| `sb list local` | Show only project-local skills |
| `sb list global` | Show only globally installed skills |
| `sb list <category>` | Filter by: core, creation, workflow, self-improvement, utility |
| `sb list community` | Show only Agent Hub skills |
| `sb list manual` | Show only hand-installed skills |
| `sb install <name>` | Install a skill from Agent Hub (Claude Code by default) |
| `sb install <name> --editor cursor` | Install to a specific editor's skill directory |
| `sb install <name> --editor all` | Install to all detected editors |
| `sb refresh` | Regenerate the JSON index and trust cache |
| `sb web` | Open the HTML browser locally |
| `sb help` | Show help |
| `sb <anything else>` | Treated as a search query |

### Search

Search is case-insensitive and checks: skill name, description, trigger command, argument hint, provides tags, sub-skill names, sub-skill descriptions, and sub-skill commands. Name matches are ranked above description-only matches.

### Fuzzy Show

`sb show` does exact match first, then substring match. One substring match shows that skill directly. Multiple matches list them for disambiguation:

```
$ sb show roadmap
Multiple matches:
  /roadmap-add-item      Add a new feature or item to a project roadmap...
  /roadmap-build-item    Implement a roadmap feature by following its pl...
  /roadmap-clarify-item  Research and clarify a roadmap item's planning...
  /roadmap-refine-item   Visually refine and polish an already-built roa...
  /roadmap-status        View the current status of all roadmap items or...
```

## File Locations (this vault)

```
3 - Resources/scripts/
  generate-skill-index.sh          # Index generator
  skill-browser-cli.sh             # CLI
  skill-browser-template.html      # Web UI template

skills/skill-browser/SKILL.md      # Claude Code slash command
```

## JSON Index Schema

```json
{
  "generatedAt": "2026-03-15T20:27:25Z",
  "totalSkills": 55,
  "localCount": 27,
  "globalCount": 28,
  "bothCount": 0,
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
      "lineCount": 263
    }
  ]
}
```

### Explore List JSON Schema

`sb explore-list --json` includes a `compatible_editors` field:

```json
{
  "name": "skill-name",
  "type": "skill",
  "compatible_editors": ["claude", "codex", "cursor", "opencode", "pi"]
}
```

Plugins are `compatible_editors: ["claude"]` only. Skills (SKILL.md) are compatible with all editors.
