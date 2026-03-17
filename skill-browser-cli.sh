#!/bin/bash
# skill-browser-cli.sh - Terminal skill browser for Claude Code
#
# Portable: works in any Claude Code project. Auto-detects project root.
# Install: alias sb='/path/to/skill-browser-cli.sh'

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SB_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/skill-browser"
mkdir -p "$SB_CACHE_DIR"
INDEX="$SB_CACHE_DIR/skill-index.json"
TRUST_CACHE="$SB_CACHE_DIR/trust-cache.json"
MAX_AGE=604800  # 7 days
export SB_CACHE_DIR

BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
BLUE='\033[38;5;75m'
GREEN='\033[38;5;78m'
PURPLE='\033[38;5;141m'
ORANGE='\033[38;5;214m'
GRAY='\033[38;5;245m'
RED='\033[38;5;203m'
CYAN='\033[38;5;116m'

ensure_index() {
    local needs_refresh=false
    if [ ! -f "$INDEX" ]; then
        needs_refresh=true
    else
        local now file_time age
        now=$(date +%s)
        if [[ "$OSTYPE" == darwin* ]]; then
            file_time=$(stat -f%m "$INDEX" 2>/dev/null || echo 0)
        else
            file_time=$(stat -c%Y "$INDEX" 2>/dev/null || echo 0)
        fi
        age=$((now - file_time))
        if [ "$age" -gt "$MAX_AGE" ]; then
            echo -e "${ORANGE}Index is $(( age / 86400 )) days old, regenerating...${NC}" >&2
            needs_refresh=true
        fi
    fi
    if [ "$needs_refresh" = true ]; then
        SB_EDITORS_FILE="$SB_CACHE_DIR/editors.json" bash "${SCRIPT_DIR}/generate-skill-index.sh" >&2
    fi
    [ -f "$INDEX" ] || { echo -e "${RED}Failed to generate skill index${NC}" >&2; exit 1; }
}

detect_editors() {
    local editors_file="$SB_CACHE_DIR/editors.json"
    # TTL: 1 hour
    if [ -f "$editors_file" ]; then
        local now file_time age
        now=$(date +%s)
        if [[ "$OSTYPE" == darwin* ]]; then
            file_time=$(stat -f%m "$editors_file" 2>/dev/null || echo 0)
        else
            file_time=$(stat -c%Y "$editors_file" 2>/dev/null || echo 0)
        fi
        age=$((now - file_time))
        [ "$age" -lt 3600 ] && return 0
    fi

    python3 << 'PYEOF_EDITORS' > "$editors_file" 2>/dev/null || echo '[]' > "$editors_file"
import json, os, shutil

editors = [
    {
        "name": "claude",
        "label": "Claude Code",
        "global": os.path.expanduser("~/.claude/skills"),
        "local": ".claude/skills",
        "detect_dirs": [os.path.expanduser("~/.claude")],
        "detect_bins": ["claude"],
    },
    {
        "name": "codex",
        "label": "Codex",
        "global": os.path.expanduser("~/.agents/skills"),
        "local": ".agents/skills",
        "detect_dirs": [os.path.expanduser("~/.agents")],
        "detect_bins": ["codex"],
    },
    {
        "name": "cursor",
        "label": "Cursor",
        "global": os.path.expanduser("~/.cursor/rules"),
        "local": ".cursor/rules",
        "detect_dirs": [os.path.expanduser("~/.cursor")],
        "detect_bins": ["cursor"],
    },
    {
        "name": "opencode",
        "label": "OpenCode",
        "global": os.path.expanduser("~/.config/opencode/skills"),
        "local": ".opencode/skills",
        "detect_dirs": [os.path.expanduser("~/.config/opencode")],
        "detect_bins": ["opencode"],
    },
    {
        "name": "pi",
        "label": "Pi",
        "global": os.path.expanduser("~/.pi/agent/skills"),
        "local": ".pi/skills",
        "detect_dirs": [os.path.expanduser("~/.pi")],
        "detect_bins": [],
    },
]

result = []
for e in editors:
    found = any(os.path.isdir(d) for d in e["detect_dirs"])
    if not found:
        found = any(shutil.which(b) for b in e["detect_bins"])
    result.append({
        "name": e["name"],
        "label": e["label"],
        "global": e["global"],
        "local": e["local"],
        "found": found,
    })
print(json.dumps(result))
PYEOF_EDITORS
}

build_trust_cache() {
    if [ -f "$TRUST_CACHE" ]; then
        local now file_time age
        now=$(date +%s)
        if [[ "$OSTYPE" == darwin* ]]; then
            file_time=$(stat -f%m "$TRUST_CACHE" 2>/dev/null || echo 0)
        else
            file_time=$(stat -c%Y "$TRUST_CACHE" 2>/dev/null || echo 0)
        fi
        age=$((now - file_time))
        [ "$age" -lt 3600 ] && return 0
    fi
    command -v skills >/dev/null 2>&1 || { echo '{}' > "$TRUST_CACHE"; return 0; }

    python3 << 'PYEOF' > "$TRUST_CACHE" 2>/dev/null || echo '{}' > "$TRUST_CACHE"
import subprocess, json
try:
    out = subprocess.run(['skills', 'list'], capture_output=True, text=True, timeout=10).stdout
except Exception:
    print('{}')
    exit()
trust_map = {}
for line in out.splitlines():
    line = line.strip()
    if not line.startswith('\u2713'):
        continue
    parts = line[2:].split()
    if len(parts) < 2:
        continue
    name = parts[0]
    rest = ' '.join(parts[1:])
    if 'Community' in rest:
        trust = 'Comm'
    elif 'Untracked' in rest:
        trust = 'Manual'
    else:
        trust = 'Manual'
    trust_map[name] = trust
print(json.dumps(trust_map))
PYEOF
}

py_interactive() {
    SKILL_BROWSER_SCRIPT="${SCRIPT_DIR}/skill-browser-cli.sh" python3 - "$@" << 'PYEOF'
import json, sys, os, re, textwrap, tty, termios, signal

SB_CACHE_DIR = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
INDEX = os.path.join(SB_CACHE_DIR, 'skill-index.json')
TRUST_CACHE = os.path.join(SB_CACHE_DIR, 'trust-cache.json')

with open(INDEX) as f:
    data = json.load(f)

trust_map = {}
try:
    with open(TRUST_CACHE) as f:
        trust_map = json.load(f)
except Exception:
    pass

# Load detected editors
EDITORS_FILE = os.path.join(SB_CACHE_DIR, 'editors.json')
detected_editors = []
all_editor_names = []
try:
    with open(EDITORS_FILE) as f:
        detected_editors = json.load(f)
    all_editor_names = [e['name'] for e in detected_editors if e.get('found')]
except Exception:
    all_editor_names = ['claude']

all_skills = data['skills']

# Load remote skills from cache
REMOTE_CACHE_DIR = os.path.join(SB_CACHE_DIR, 'remote-cache')
remote_skills = []
local_ids = {s['name'].lower() for s in all_skills}
local_ids.update(s['id'].lower() for s in all_skills)
if os.path.isdir(REMOTE_CACHE_DIR):
    import glob as _glob
    for cache_file in _glob.glob(os.path.join(REMOTE_CACHE_DIR, '*.json')):
        try:
            with open(cache_file) as cf:
                items = json.load(cf)
            if isinstance(items, list):
                for item in items:
                    item['installed'] = (
                        item.get('name', '').lower() in local_ids
                        or item.get('id', '').lower() in local_ids
                    )
                    remote_skills.append(item)
        except Exception:
            pass

argv = sys.argv[1:]
initial_search = ''
initial_tab = 'installed'
initial_cmd = argv[0] if argv else 'list'
if initial_cmd == 'explore':
    initial_tab = 'explore'
    initial_cmd = 'list'
elif initial_cmd == 'search' and len(argv) > 1:
    initial_search = ' '.join(argv[1:])
elif initial_cmd not in ('list', 'search', 'show', 'cats'):
    initial_search = ' '.join(argv)
    initial_cmd = 'search'

# For 'show' command, do non-interactive detail and exit
if initial_cmd == 'show':
    # Handled below after class definitions
    pass

# ANSI
B, D, N = '\033[1m', '\033[2m', '\033[0m'
BLU, GRN, PUR, ORA, GRY, RED, CYN, YEL = (
    '\033[38;5;75m', '\033[38;5;78m', '\033[38;5;141m',
    '\033[38;5;214m', '\033[38;5;245m', '\033[38;5;203m',
    '\033[38;5;116m', '\033[38;5;228m'
)
SEP = '\033[38;5;238m'
INVR = '\033[7m'  # reverse video for selection highlight
CLR = '\033[2J\033[H'  # clear screen + home
HIDE_CURSOR = '\033[?25l'
SHOW_CURSOR = '\033[?25h'
ALT_SCREEN_ON = '\033[?1049h'   # switch to alternate screen buffer
ALT_SCREEN_OFF = '\033[?1049l'  # switch back to main screen buffer
MOUSE_ON = '\033[?1000h\033[?1006h'   # enable mouse tracking (SGR mode)
MOUSE_OFF = '\033[?1000l\033[?1006l'  # disable mouse tracking
TTY_FD = None  # set in Browser.run()

scope_c = {'local': GRN, 'global': PUR, 'both': ORA, 'plugin': YEL, 'remote': '\033[38;5;111m'}
trust_c = {'Comm': CYN, 'Manual': GRY, 'World': YEL}
editor_c = {
    'claude': CYN, 'codex': '\033[38;5;111m', 'cursor': '\033[38;5;213m',
    'opencode': GRN, 'pi': ORA,
}

# Smart tags: infer use-case from name + description keywords
# Uses explicit name overrides first, then keyword matching (first match wins).
TAG_OVERRIDES = {
    'data-question': 'Data', 'data-analysis-reviewer': 'Data',
    'signal-scanner': 'Research', 'signal-scanner-feedback': 'Research',
    'gather-context': 'Research', 'briefing': 'Research', 'performance': 'Research',
    'web-research': 'Research',
    'daily-context-sync': 'Productivity', 'dailypm': 'Productivity',
    'deploy': 'Engineering', 'scope-doc-generator': 'Product',
    'skill-architect': 'Automation', 'skill-maker': 'Automation',
    'self-improve': 'Automation', 'skill-list': 'Automation',
    'skill-browser': 'Automation', 'shopify-skills-judge': 'Automation',
    'shopify-skills': 'Automation', 'critique-loop': 'Automation',
    'ralph': 'Automation',
    'opportunity-score': 'Product', 'experiment-brief': 'Product',
    'fact-add': 'Productivity', 'brainstorm': 'Product',
    'second-brain': 'Productivity', 'pm-toolkit': 'Productivity',
    'gworkspace': 'Productivity',
    'browser-use': 'Browser', 'playwright-cli': 'Browser',
    'compound-engineering:git-worktree': 'Engineering',
    'compound-engineering:resolve-pr-parallel': 'Engineering',
    'compound-engineering:setup': 'Automation',
    'compound-engineering:compound-docs': 'Writing',
    'compound-engineering:every-style-editor': 'Writing',
    'compound-engineering:create-agent-skills': 'Automation',
    'compound-engineering:orchestrating-swarms': 'Automation',
    'superpowers:dispatching-parallel-agents': 'Automation',
    'canvas:canvas': 'Design', 'canvas:document': 'Writing',
    'canvas:calendar': 'Productivity', 'canvas:flight': 'Productivity',
    'obsidian:json-canvas': 'Productivity', 'obsidian:obsidian-bases': 'Productivity',
    'obsidian:obsidian-markdown': 'Writing',
    'playground:playground': 'Design',
    'qmd:release': 'Engineering',
    'marimo:marimo-notebook-creator': 'Data', 'marimo:marimo-reviewer': 'Data',
    'marimo:marimo-master': 'Data',
}
TAG_RULES = [
    ('Data',         ['bigquery', 'data warehouse', 'data analysis', 'statistical', 'data question', 'sql', 'data platform', 'marimo', 'notebook']),
    ('Research',     ['intelligence', 'crawl', 'signal scan', 'gather context', 'research', 'catch up', 'what did i miss']),
    ('Browser',      ['browser', 'web test', 'screenshot', 'form fill', 'navigate website', 'playwright', 'chrome devtools', 'chrome-devtools']),
    ('Media',        ['image', 'video', 'music', 'speech', 'radio', 'generat']),
    ('Design',       ['polaris', 'figma', 'design system', 'ui component', 'ui extension', 'cro', 'variant protot', 'refine', 'polish', 'frontend interface', 'frontend-design', 'playground']),
    ('Product',      ['prd', 'requirement', 'roadmap', 'gsd', 'scope doc', 'experiment', 'opportunity', 'rice', 'spec out', 'readout']),
    ('Engineering',  ['code review', 'pull request', 'pr comment', 'debug', 'pipeline', 'monorepo', 'graphite', 'git worktree', 'migration', 'buildkite', 'observe', 'deploy', 'implement', 'release', 'worktree', 'pr-review', 'commit']),
    ('Writing',      ['weekly update', 'impact recap', 'weekly impact', 'write-cli', 'write.quick', 'markdown', 'style guide', 'editing copy', 'documentation']),
    ('Productivity', ['workflow', 'morning', 'daily', 'calendar', 'sync', 'knowledge', 'organize', 'transcri', 'meeting', 'reflect', 'journal', 'session', 'heartbeat', 'fact', 'summar', 'memory', 'synthesize', 'obsidian', 'canvas']),
    ('Automation',   ['agent skill', 'skill-maker', 'skill-architect', 'self-improve', 'critique loop', 'parallel agent', 'parallel process', 'orchestrat', 'autonomous', 'ralph', 'slash command', 'dispatching']),
]

tag_c = {
    'Design': '\033[38;5;213m',      # pink
    'Engineering': '\033[38;5;203m', # red
    'Product': '\033[38;5;75m',      # blue
    'Data': '\033[38;5;228m',        # yellow
    'Writing': '\033[38;5;180m',     # tan
    'Productivity': GRN,
    'Automation': ORA,
    'Research': PUR,
    'Media': '\033[38;5;141m',       # light purple
    'Browser': CYN,
}

def smart_tag(s):
    """Infer a use-case tag from skill name + description."""
    sid = s.get('id', s.get('name', ''))
    if sid in TAG_OVERRIDES:
        return TAG_OVERRIDES[sid]
    text = (s.get('name', '') + ' ' + s.get('description', '')).lower()
    for tag, keywords in TAG_RULES:
        for kw in keywords:
            if kw in text:
                return tag
    return 'General'

def trunc(s, n):
    if not s: return ''
    return s[:n-1] + '\u2026' if len(s) > n else s

def safe_cache_key(*parts):
    """Sanitize parts for use as a cache filename (no path traversal)."""
    import re as _re
    return '--'.join(_re.sub(r'[^a-zA-Z0-9._-]', '_', p) for p in parts)

def get_trust(sid):
    return trust_map.get(sid, 'Manual')

def extract_triggers(desc):
    # Clean escaped quotes from JSON
    desc = desc.replace('\\"', '"').replace("\\'", "'")
    # "Triggers on [patterns like] X, Y, Z"
    m = re.search(r'[Tt]riggers? on(?: patterns? like)?\s+(.+?)(?:\.\s|$)', desc)
    if m:
        parts = re.split(r'[,;]\s*|\s+or\s+', m.group(1))
        return [p.strip().strip('"\'.,') for p in parts if len(p.strip()) > 2][:5]
    # "Use when the user says X, Y"
    m = re.search(r'[Uu]se when (?:the )?user says?\s+(.+?)(?:\.\s*$|$)', desc)
    if m:
        parts = re.split(r'[,;]\s*|\s+or\s+', m.group(1))
        return [p.strip().strip('"\'.,') for p in parts if len(p.strip()) > 2][:5]
    # "or says X, Y, Z" (mid-sentence, must be preceded by word boundary)
    m = re.search(r'\bsays\s+["\']?(.+?)(?:\.\s*$|$)', desc)
    if m:
        parts = re.split(r'[,;]\s*|\s+or\s+', m.group(1))
        return [p.strip().strip('"\'.,') for p in parts if len(p.strip()) > 2][:5]
    # "Activate when users say X"
    m = re.search(r'[Aa]ctivate when[^.]*say[s]?\s+(.+?)(?:\.\s|$)', desc)
    if m:
        parts = re.split(r'[,;]\s*|\s+or\s+', m.group(1))
        return [p.strip().strip('"\'.,') for p in parts if len(p.strip()) > 2][:5]
    # Quoted phrases (double quotes only, to avoid matching apostrophes)
    quoted = re.findall(r'"([^"]{3,})"', desc)
    if quoted:
        return quoted[:5]
    return []

def term_size():
    try:
        c, r = os.get_terminal_size()
        return r, c
    except Exception:
        return 24, 120

def matches(s, q):
    q = q.lower()
    fields = [s['name'], s['description'], s['triggerCommand'], s.get('argumentHint', '')]
    fields += s.get('provides', [])
    fields += [sub['name'] for sub in s.get('subSkills', [])]
    fields += [sub['description'] for sub in s.get('subSkills', [])]
    fields += [sub['command'] for sub in s.get('subSkills', [])]
    return any(q in (f or '').lower() for f in fields)

def get_key():
    """Read a single keypress, handling arrow keys and mouse events."""
    fd = TTY_FD
    ch = os.read(fd, 1)
    if ch == b'\x1b':
        ch2 = os.read(fd, 2)
        if ch2 == b'[A': return 'up'
        if ch2 == b'[B': return 'down'
        if ch2 == b'[C': return 'right'
        if ch2 == b'[D': return 'left'
        if ch2 == b'[5': os.read(fd, 1); return 'pgup'
        if ch2 == b'[6': os.read(fd, 1); return 'pgdn'
        if ch2 == b'[<':
            # SGR mouse event: \033[<btn;x;y[Mm]
            buf = b''
            while True:
                c = os.read(fd, 1)
                buf += c
                if c in (b'M', b'm'):
                    break
                if len(buf) > 20:
                    break
            try:
                parts = buf[:-1].decode().split(';')
                btn = int(parts[0])
                col = int(parts[1])
                row = int(parts[2]) if len(parts) > 2 else 0
                # btn 64 = scroll up, 65 = scroll down
                if btn == 64: return ('mouse_scroll_up', col, row)
                if btn == 65: return ('mouse_scroll_down', col, row)
            except (ValueError, IndexError):
                pass
            return 'mouse_other'
        if ch2 == b'[M':
            # Legacy mouse: read 3 more bytes
            os.read(fd, 3)
            return 'mouse_other'
        return 'esc'
    if ch == b'\x7f' or ch == b'\x08': return 'backspace'
    if ch == b'\r' or ch == b'\n': return 'enter'
    if ch == b'\x03': return 'ctrl-c'
    return ch.decode('utf-8', errors='ignore')

def render_detail(s):
    """Render a skill detail view, return as lines."""
    rows, cols = term_size()
    trust = get_trust(s['id'])
    lines = []
    lines.append('')
    tag = smart_tag(s)
    tgc = tag_c.get(tag, GRY)
    lines.append(f'  {B}{CYN}{s["triggerCommand"]}{N}')
    editors = s.get('editors', [s.get('editor', 'claude')])
    editors_str = ', '.join(editors)
    ec = editor_c.get(editors[0], GRY) if editors else GRY
    lines.append(f'  {tgc}{tag}{N}  {ec}{editors_str}/{s["scope"]}{N}  {trust_c.get(trust, GRY)}{trust}{N}  {D}{s["lineCount"]} lines{N}')
    lines.append('')
    clean_desc = s['description'].replace('\\"', '"').replace("\\'", "'")
    for line in textwrap.wrap(clean_desc, width=min(80, cols - 4)):
        lines.append(f'  {line}')
    lines.append('')

    triggers = extract_triggers(s['description'])
    if triggers:
        lines.append(f'  {B}Triggers:{N}')
        for t in triggers:
            lines.append(f'    {D}\u2022 "{t}"{N}')
        lines.append('')

    if s.get('provides'):
        lines.append(f'  {B}Provides:{N}  {BLU}{", ".join(s["provides"])}{N}')
    reqs = []
    for m in s.get('requires', {}).get('mcps', []):
        reqs.append(f'{m} {D}(MCP){N}')
    for b in s.get('requires', {}).get('bins', []):
        reqs.append(f'{b} {D}(CLI){N}')
    for sk in s.get('requires', {}).get('skills', []):
        reqs.append(f'{sk} {D}(Skill){N}')
    if reqs:
        lines.append(f'  {B}Requires:{N}  {", ".join(reqs)}')
    if s.get('argumentHint'):
        lines.append(f'  {B}Args:{N}     {D}{s["argumentHint"]}{N}')

    if s['isCompound'] and s['subSkills']:
        lines.append('')
        lines.append(f'  {B}{ORA}Sub-Skills ({len(s["subSkills"])}):{N}')
        for sub in s['subSkills']:
            desc_w = min(cols - 30, 70)
            lines.append(f'    {CYN}{sub["command"]:<24}{N}  {trunc(sub["description"], desc_w)}')
    lines.append('')
    return lines


# Non-interactive show command
if initial_cmd == 'show':
    arg = ' '.join(argv[1:]) if len(argv) > 1 else ''
    if not arg:
        print(f'{RED}Usage: sb show <name>{N}')
        sys.exit(1)
    q = arg.lstrip('/')
    skill = next((s for s in all_skills if s['id'] == q or s['name'] == q), None)
    if not skill:
        cands = [s for s in all_skills if q.lower() in s['id'].lower() or q.lower() in s['name'].lower()]
        if len(cands) == 1:
            skill = cands[0]
        elif cands:
            print(f'{ORA}Multiple matches:{N}')
            for c in cands:
                print(f'  {CYN}{c["triggerCommand"]}{N}  {D}{trunc(c["description"], 60)}{N}')
            sys.exit(0)
        else:
            print(f'{RED}Skill "{arg}" not found{N}')
            sys.exit(1)
    for line in render_detail(skill):
        print(line)
    sys.exit(0)


# --- Interactive TUI ---

class Browser:
    SORT_MODES = ['type', 'name']
    TAG_ORDER = {
        'Product': 0, 'Engineering': 1, 'Design': 2, 'Data': 3,
        'Research': 4, 'Writing': 5, 'Productivity': 6, 'Automation': 7,
        'Media': 8, 'Browser': 9, 'General': 10
    }

    SCOPE_FILTERS = ['all', 'skills', 'plugins'] + [e for e in all_editor_names if e != 'claude'] + (['claude'] if len(all_editor_names) > 1 else [])
    EXPLORE_FILTERS = ['all', 'skills', 'plugins']

    def __init__(self):
        self.search = initial_search
        self.cursor = 0
        self.scroll = 0
        self.searching = bool(initial_search)
        self.detail_skill = None
        self.detail_scroll = 0
        self.detail_panel_scroll = 0
        self.sort_mode = 'type'
        self.scope_filter = 'all'
        self.explore_filter = 'all'
        self.running = True
        # Tab state
        self.active_tab = initial_tab
        self.remote_cursor = 0
        self.remote_scroll = 0
        self.remote_panel_scroll = 0
        self.remote_filtered = []
        self.install_status = ''  # status message for footer
        self._remote_content_cache = {}  # skill_id -> SKILL.md content (or None)
        self.filter_skills()
        self.filter_remote_skills()

    def sort_key(self, s):
        if self.sort_mode == 'type':
            return (self.TAG_ORDER.get(smart_tag(s), 99), s['triggerCommand'].lower())
        return (s['triggerCommand'].lower(),)

    def move_cursor(self, new_pos):
        new_pos = max(0, min(new_pos, len(self.filtered) - 1))
        if new_pos != self.cursor:
            self.cursor = new_pos
            self.detail_panel_scroll = 0

    def filter_skills(self):
        pool = all_skills
        # Scope filter
        if self.scope_filter == 'skills':
            pool = [s for s in pool if s['scope'] != 'plugin']
        elif self.scope_filter == 'plugins':
            pool = [s for s in pool if s['scope'] == 'plugin']
        elif self.scope_filter in all_editor_names:
            # Filter to skills from a specific editor
            pool = [s for s in pool if self.scope_filter in s.get('editors', [s.get('editor', 'claude')])]

        if self.search:
            q = self.search
            self.filtered = [s for s in pool if matches(s, q)]
            self.filtered.sort(key=lambda s: (
                0 if q.lower() == s['name'].lower() else
                1 if q.lower() in s['name'].lower() else 2,
                *self.sort_key(s)
            ))
        else:
            self.filtered = sorted(pool, key=self.sort_key)
        if self.cursor >= len(self.filtered):
            self.cursor = max(0, len(self.filtered) - 1)

    def filter_remote_skills(self):
        pool = remote_skills
        if self.explore_filter == 'skills':
            pool = [s for s in pool if s.get('item_type') != 'plugin']
        elif self.explore_filter == 'plugins':
            pool = [s for s in pool if s.get('item_type') == 'plugin']
        if self.search:
            q = self.search.lower()
            self.remote_filtered = [s for s in pool if
                q in s.get('name', '').lower() or
                q in s.get('description', '').lower() or
                q in s.get('repo', '').lower() or
                q in s.get('owner', '').lower()
            ]
            self.remote_filtered.sort(key=lambda s: (
                0 if q == s['name'].lower() else
                1 if q in s['name'].lower() else 2,
                s['name'].lower()
            ))
        else:
            self.remote_filtered = sorted(pool, key=lambda s: (s.get('owner', ''), s['name'].lower()))
        if self.remote_cursor >= len(self.remote_filtered):
            self.remote_cursor = max(0, len(self.remote_filtered) - 1)

    def move_remote_cursor(self, new_pos):
        new_pos = max(0, min(new_pos, len(self.remote_filtered) - 1))
        if new_pos != self.remote_cursor:
            self.remote_cursor = new_pos
            self.remote_panel_scroll = 0

    def _build_remote_detail_lines(self, s, panel_w):
        """Build detail panel lines for a remote skill (fast, no API calls).
        Shows description + metadata from index. Full SKILL.md on Enter."""
        import textwrap as tw
        import re as _re
        inner_w = panel_w - 3
        lines = []

        # Header
        is_plugin = s.get('item_type') == 'plugin'
        type_label = f'{YEL}plugin{N}' if is_plugin else f'{BLU}skill{N}'
        lines.append(f' {B}{CYN}{trunc(s.get("triggerCommand", "/" + s["name"]), inner_w)}{N}')
        repo_label = s.get('repo', 'unknown')
        installed_label = f'  {GRN}installed{N}' if s.get('installed') else ''
        author = s.get('author', '')
        author_label = f'  {D}by {author}{N}' if author else ''
        lines.append(f' {type_label}  {GRY}{repo_label}{N}{installed_label}{author_label}')
        lines.append('')

        skill_id = s.get('id', s['name'])

        # Check if full SKILL.md has been fetched (via Enter key)
        if skill_id in self._remote_content_cache:
            raw_content = self._remote_content_cache[skill_id]
            if raw_content:
                # Strip frontmatter
                parts = raw_content.split('---', 2)
                body = parts[2].strip() if len(parts) >= 3 else raw_content.strip()
                for raw_line in body.split('\n'):
                    raw_line = raw_line.rstrip()
                    if not raw_line:
                        lines.append('')
                    elif raw_line.startswith('#'):
                        lines.append(f' {B}{raw_line}{N}')
                    elif raw_line.startswith('  ') or raw_line.startswith('\t') or raw_line.startswith('- ') or raw_line.startswith('| '):
                        lines.append(f' {D}{raw_line[:inner_w]}{N}')
                    else:
                        for wl in tw.wrap(raw_line, width=inner_w):
                            lines.append(f' {D}{wl}{N}')
                lines.append('')
                if s.get('remote_url'):
                    lines.append(f' {D}{s["remote_url"]}{N}')
            else:
                lines.append(f' {D}(SKILL.md not available){N}')
        else:
            # Default: show description from index (instant, no fetch)
            desc = s.get('description', 'No description available')
            for dl in tw.wrap(desc, width=inner_w):
                lines.append(f' {dl}')
            lines.append('')
            if s.get('remote_url'):
                lines.append(f' {D}{s["remote_url"]}{N}')
            lines.append('')
            doc_hint = 'README' if is_plugin else 'SKILL.md'
            lines.append(f' {D}Press ENTER to load full {doc_hint}{N}')

        # Show install target hint
        if not s.get('installed') and all_editor_names:
            is_plugin = s.get('item_type') == 'plugin'
            if is_plugin:
                compat = ['claude']
            else:
                compat = all_editor_names[:]
            editor_labels = '  '.join(f'{editor_c.get(e, GRY)}{e}{N}' for e in compat)
            lines.append('')
            lines.append(f' Install to: {editor_labels}  {D}(i to install){N}')

        # Safety truncate each line to panel_w
        _ansi_re = _re.compile(r'\033\[[0-9;]*m')
        safe = []
        for line in lines:
            visible = _ansi_re.sub('', line)
            if len(visible) >= panel_w:
                out = []
                vc = 0
                i = 0
                while i < len(line) and vc < panel_w - 2:
                    if line[i] == '\033':
                        j = line.find('m', i)
                        if j == -1: break
                        j += 1
                        out.append(line[i:j])
                        i = j
                    else:
                        out.append(line[i])
                        vc += 1
                        i += 1
                out.append(N)
                safe.append(''.join(out))
            else:
                safe.append(line)
        return safe

    def _fetch_remote_skill_md(self, s):
        """Fetch full SKILL.md (or README.md for plugins), cache in memory + disk."""
        import subprocess as _sp
        skill_id = s.get('id', s['name'])
        is_plugin = s.get('item_type') == 'plugin'

        # Already cached in memory
        if skill_id in self._remote_content_cache:
            return

        # Check disk cache
        doc_name = 'README.md' if is_plugin else 'SKILL.md'
        cache_key = safe_cache_key(s.get('owner', 'x'), s['name'], doc_name)
        cache_path = os.path.join(REMOTE_CACHE_DIR, cache_key)
        if os.path.isfile(cache_path):
            try:
                import time as _time
                age = _time.time() - os.path.getmtime(cache_path)
                if age < 86400:
                    with open(cache_path, 'r') as f:
                        self._remote_content_cache[skill_id] = f.read()
                    return
            except Exception:
                pass

        # Fetch via gh api
        if s.get('repo') and s.get('remote_path'):
            import base64 as _b64
            # Try multiple doc files in order of preference
            if is_plugin:
                candidates = ['README.md', 'SKILL.md']
            else:
                candidates = ['SKILL.md', 'skill.md', 'README.md']

            for doc in candidates:
                try:
                    api_path = f'repos/{s["repo"]}/contents/{s["remote_path"]}/{doc}'
                    r = _sp.run(['gh', 'api', api_path], capture_output=True, text=True, timeout=15)
                    if r.returncode == 0:
                        data_resp = json.loads(r.stdout)
                        if data_resp.get('content'):
                            content = _b64.b64decode(data_resp['content']).decode('utf-8', errors='ignore')
                            self._remote_content_cache[skill_id] = content
                            try:
                                os.makedirs(REMOTE_CACHE_DIR, exist_ok=True)
                                with open(cache_path, 'w') as f:
                                    f.write(content)
                            except Exception:
                                pass
                            return
                except Exception:
                    pass

        # Mark as unavailable so we don't retry
        self._remote_content_cache[skill_id] = None

    def install_selected_remote_skill(self, target_editor=None):
        """Install the currently selected remote skill to one or all editors."""
        import subprocess as _sp
        import shutil as _shutil
        if not self.remote_filtered:
            return
        skill = self.remote_filtered[self.remote_cursor]
        name = skill['name']

        # Determine target editor(s)
        if target_editor == 'all':
            targets = all_editor_names[:]
        elif target_editor and target_editor in all_editor_names:
            targets = [target_editor]
        elif len(all_editor_names) == 1:
            targets = all_editor_names[:]
        else:
            targets = ['claude']  # Default to Claude Code

        # Dependency resolution
        dep_skills = skill.get('requires', {}).get('skills', [])
        missing_deps = [d for d in dep_skills if d.lower() not in local_ids]
        if missing_deps:
            script_path = os.environ.get('SKILL_BROWSER_SCRIPT', '')
            for dep in missing_deps:
                self.install_status = f'Installing dependency: {dep}...'
                self.draw()
                if script_path:
                    try:
                        _sp.run(['bash', script_path, 'install', dep, '--local', '--no-deps'],
                                capture_output=True, timeout=60)
                        local_ids.add(dep.lower())
                    except Exception:
                        pass

        self.install_status = f'Installing {name}...'
        self.draw()

        # Try skills CLI (Agent Hub) for Claude Code first
        if 'claude' in targets:
            try:
                r = _sp.run(['skills', 'get', name, '--local'], capture_output=True, text=True, timeout=60)
                if r.returncode == 0:
                    skill['installed'] = True
                    local_ids.add(name.lower())
                    targets.remove('claude')
                    if not targets:
                        self.install_status = f'Installed {name}'
                        return
            except Exception:
                pass

        # For non-Claude editors, fetch SKILL.md and copy to their directory
        skill_id = skill.get('id', name)
        if skill_id not in self._remote_content_cache:
            self._fetch_remote_skill_md(skill)
        content = self._remote_content_cache.get(skill_id)

        installed_to = []
        for editor_name in targets:
            editor_info = next((e for e in detected_editors if e['name'] == editor_name), None)
            if not editor_info:
                continue
            target_dir = os.path.join(editor_info['global'], name)
            try:
                os.makedirs(target_dir, exist_ok=True)
                target_file = os.path.join(target_dir, 'SKILL.md')
                if content:
                    with open(target_file, 'w') as f:
                        f.write(content)
                    installed_to.append(editor_name)
                elif skill.get('remote_path'):
                    # No cached content, but still create a placeholder
                    installed_to.append(editor_name)
            except Exception:
                pass

        if installed_to or skill.get('installed'):
            all_targets = (['claude'] if skill.get('installed') else []) + installed_to
            self.install_status = f'Installed {name} to {", ".join(all_targets)}'
            skill['installed'] = True
            local_ids.add(name.lower())
        else:
            self.install_status = f'Failed to install {name}'

    def _build_detail_lines(self, s, panel_w):
        """Build ALL detail panel lines for a skill (not capped to viewport)."""
        import textwrap as tw
        import re as _re
        inner_w = panel_w - 3
        lines = []
        trust = get_trust(s['id'])
        tag = smart_tag(s)
        tgc = tag_c.get(tag, GRY)
        tc = trust_c.get(trust, GRY)
        editors = s.get('editors', [s.get('editor', 'claude')])
        editors_str = ', '.join(editors)

        # Header
        lines.append(f' {B}{CYN}{trunc(s["triggerCommand"], inner_w)}{N}')
        # Staleness indicator
        import time as _time
        lm = s.get('lastModified', 0)
        age_str = ''
        if lm > 0:
            age_days = int((_time.time() - lm) / 86400)
            if age_days > 30:
                age_str = f'  {ORA}{age_days}d old{N}'
            elif age_days > 0:
                age_str = f'  {D}{age_days}d ago{N}'
        lines.append(f' {tgc}{tag}{N}  {editor_c.get(editors[0], GRY)}{editors_str}/{s["scope"]}{N}  {tc}{trust}{N}{age_str}')
        lines.append('')

        # Dependencies section
        dep_skills = s.get('requires', {}).get('skills', [])
        if dep_skills:
            lines.append(f' {B}Dependencies:{N}')
            for dep in dep_skills:
                dep_installed = dep.lower() in {sk['id'].lower() for sk in all_skills} or dep.lower() in {sk['name'].lower() for sk in all_skills}
                indicator = f'{GRN}\u2713{N}' if dep_installed else f'{RED}\u2717{N}'
                lines.append(f'   {indicator} {dep}')
            lines.append('')

        # Description
        clean_desc = s['description'].replace('\\"', '"').replace("\\'", "'")
        for dl in tw.wrap(clean_desc, width=inner_w):
            lines.append(f' {dl}')
        lines.append('')

        # Full SKILL.md content
        skill_path = s.get('skillPath', '')
        if skill_path:
            try:
                with open(skill_path, 'r') as f:
                    raw = f.read()
                lines.append(f' {SEP}{"─" * (inner_w - 1)}{N}')
                lines.append(f' {B}{GRY}SKILL.md{N}')
                lines.append('')
                # Strip frontmatter
                parts = raw.split('---', 2)
                if len(parts) >= 3:
                    body = parts[2].strip()
                else:
                    body = raw.strip()
                # Wrap each line of the markdown body
                for raw_line in body.split('\n'):
                    raw_line = raw_line.rstrip()
                    if not raw_line:
                        lines.append('')
                    elif raw_line.startswith('#'):
                        lines.append(f' {B}{raw_line}{N}')
                    elif raw_line.startswith('  ') or raw_line.startswith('\t') or raw_line.startswith('- ') or raw_line.startswith('| '):
                        # Preserve indented/list/table lines, just truncate
                        lines.append(f' {D}{raw_line[:inner_w]}{N}')
                    else:
                        for wl in tw.wrap(raw_line, width=inner_w):
                            lines.append(f' {D}{wl}{N}')
            except (OSError, IOError):
                lines.append(f' {D}(Could not read SKILL.md){N}')
        else:
            lines.append(f' {D}(No SKILL.md path){N}')

        lines.append('')

        # Triggers
        triggers = extract_triggers(s['description'])
        if triggers:
            lines.append(f' {B}Triggers:{N}')
            for t in triggers:
                for tl in tw.wrap(f'\u2022 {t}', width=inner_w - 2):
                    lines.append(f'  {D}{tl}{N}')
            lines.append('')

        # Plugin info
        if s.get('plugin'):
            lines.append(f' {B}Plugin:{N} {s["plugin"]}')
            if s.get('marketplace'):
                lines.append(f' {B}Source:{N} {D}{s["marketplace"]}{N}')
            lines.append('')

        lines.append(f' {D}{s["lineCount"]} lines  {skill_path}{N}')

        # Safety truncate each line to panel_w
        _ansi_re = _re.compile(r'\033\[[0-9;]*m')
        safe = []
        for line in lines:
            visible = _ansi_re.sub('', line)
            if len(visible) >= panel_w:
                out = []
                vc = 0
                i = 0
                while i < len(line) and vc < panel_w - 2:
                    if line[i] == '\033':
                        j = line.find('m', i)
                        if j == -1: break
                        j += 1
                        out.append(line[i:j])
                        i = j
                    else:
                        out.append(line[i])
                        vc += 1
                        i += 1
                out.append(N)
                safe.append(''.join(out))
            else:
                safe.append(line)
        return safe

    def draw(self):
        rows, cols = term_size()
        buf = []
        V = SEP + '\u2502' + N
        COL_SEP = f'{SEP}\u2502{N}'

        # Layout
        PANEL_W = min(max(cols // 3, 30), 50)
        LIST_W = cols - PANEL_W - 1

        # Helper: build a bordered row with exact padding (no cursor positioning)
        # left_text/right_text are visible strings, left_ansi/right_ansi are ANSI-wrapped
        inner = cols - 2  # space between │ and │
        def padrow(left_vis, left_ansi, right_vis='', right_ansi=''):
            pad = inner - len(left_vis) - len(right_vis)
            if pad < 1: pad = 1
            return f'{V}{left_ansi}{" " * pad}{right_ansi}{V}'

        # Row 1: Top border
        buf.append(f'{SEP}\u250c{"\u2500" * (cols - 2)}\u2510{N}')

        # Row 2: Keyboard shortcuts (move to footer instead to avoid wrapping issues)
        # Skip - shortcuts are shown in footer bar below

        # Row 2: Tab bar + Search box
        if self.active_tab == 'installed':
            tab_vis = '[1 Installed]  2 Explore'
            tab_ansi = f'{INVR} 1 Installed {N}  {D}2 Explore{N}'
            count_label = f'{len(self.filtered)}/{len(all_skills)}'
        else:
            tab_vis = ' 1 Installed  [2 Explore]'
            tab_ansi = f' {D}1 Installed{N}  {INVR} 2 Explore {N}'
            count_label = f'{len(self.remote_filtered)}/{len(remote_skills)}'

        if self.searching:
            search_vis = '  / ' + self.search + '\u2588'
            search_ansi = f'  {GRN}/{N} {self.search}\u2588'
        elif self.search:
            search_vis = '  / ' + self.search
            search_ansi = f'  {GRN}/{N} {self.search}'
        else:
            search_vis = '  / to search'
            search_ansi = f'  {D}/ to search{N}'

        left_vis = tab_vis + search_vis
        left_ansi = tab_ansi + search_ansi
        # Truncate if too long
        max_s = inner - len(count_label) - 2
        if len(left_vis) > max_s:
            left_vis = left_vis[:max_s]
            left_ansi = left_vis
        buf.append(padrow(left_vis, left_ansi, count_label, f'{D}{count_label}{N}'))

        # Row 5: Separator
        buf.append(f'{SEP}\u251c{"\u2500" * (cols - 2)}\u2524{N}')

        # ---- TAB-SPECIFIC RENDERING ----
        if self.active_tab == 'installed':
            # Column widths
            if self.filtered:
                longest_name = max(len(s['triggerCommand']) for s in self.filtered)
            else:
                longest_name = 20
            NAME_W = min(max(longest_name + 2, 20), 35)
            TAG_W = 14
            EDITOR_W = 14
            TRUST_W = 9
            fixed_w = NAME_W + TAG_W + EDITOR_W + TRUST_W + 4
            DESC_W = max(LIST_W - fixed_w - 2, 10)

            # Row 6: Column headers
            hdr = (f'{V} {D}{GRY}{"Name":<{NAME_W}}{N}{COL_SEP}'
                   f'{D}{GRY}{"Type":<{TAG_W}}{N}{COL_SEP}'
                   f'{D}{GRY}{"Editor":<{EDITOR_W}}{N}{COL_SEP}'
                   f'{D}{GRY}{"Source":<{TRUST_W}}{N}{COL_SEP}'
                   f'{D}{GRY}{"Description"}{N}')
            buf.append(f'{hdr}\033[{LIST_W + 1}G{COL_SEP}{D}{GRY} Details{N}\033[{cols}G{V}')

            # Row 7: Separator under headers
            buf.append(f'{SEP}\u251c{"\u2500" * (LIST_W - 1)}\u253c{"\u2500" * PANEL_W}\u2524{N}')

            header_lines = len(buf)
            footer_lines = 3  # separator + shortcuts + bottom border
            body_lines = rows - header_lines - footer_lines

            # Detail panel for selected skill
            selected_skill = None
            if self.filtered and 0 <= self.cursor < len(self.filtered):
                selected_skill = self.filtered[self.cursor]
            if selected_skill:
                all_panel_lines = self._build_detail_lines(selected_skill, PANEL_W)
                self.detail_panel_scroll = max(0, min(self.detail_panel_scroll, max(0, len(all_panel_lines) - body_lines)))
                panel_slice = all_panel_lines[self.detail_panel_scroll:self.detail_panel_scroll + body_lines]
                panel_lines = panel_slice + [''] * (body_lines - len(panel_slice))
            else:
                all_panel_lines = []
                panel_lines = ['' for _ in range(body_lines)]

            if self.detail_skill:
                detail_lines = render_detail(self.detail_skill)
                visible = detail_lines[self.detail_scroll:self.detail_scroll + body_lines]
                for i in range(body_lines):
                    left = visible[i] if i < len(visible) else ''
                    buf.append(f'{V}{left}\033[{cols}G{V}')
                buf.append(f'{SEP}\u251c{"\u2500" * (cols - 2)}\u2524{N}')
                keys_vis = 'ESC back  \u2191\u2193 scroll  q quit'
                keys_vis = keys_vis[:inner]
                buf.append(padrow(keys_vis, f'{D}{keys_vis}{N}'))
                buf.append(f'{SEP}\u2514{"\u2500" * (cols - 2)}\u2518{N}')
            else:
                # Build display items - each sub-skill gets its own row
                display_items = []
                for s in self.filtered:
                    display_items.append(('skill', s))
                    if s.get('isCompound') and s.get('subSkills'):
                        for si, sub in enumerate(s['subSkills']):
                            is_last = (si == len(s['subSkills']) - 1)
                            display_items.append(('sub', sub, is_last))

                cursor_display_idx = 0
                idx = 0
                for di, item in enumerate(display_items):
                    if item[0] == 'skill':
                        if idx == self.cursor:
                            cursor_display_idx = di
                            break
                        idx += 1

                if cursor_display_idx < self.scroll:
                    self.scroll = cursor_display_idx
                if cursor_display_idx >= self.scroll + body_lines:
                    self.scroll = cursor_display_idx - body_lines + 1
                self.scroll = max(0, min(self.scroll, max(0, len(display_items) - body_lines)))

                visible = display_items[self.scroll:self.scroll + body_lines]
                skill_idx = 0
                for di in range(self.scroll):
                    if display_items[di][0] == 'skill':
                        skill_idx += 1

                for i in range(body_lines):
                    if i < len(visible):
                        item = visible[i]
                        kind = item[0]
                        if kind == 'sub':
                            sub = item[1]
                            is_last = item[2]
                            pfx = '\u2514' if is_last else '\u251c'
                            sub_desc = trunc(sub.get('description', ''), DESC_W + TAG_W + EDITOR_W + TRUST_W)
                            left = f'{V}  {D}{pfx} {CYN}{sub["command"]:<{NAME_W - 2}}{N}{COL_SEP}{D}{sub_desc}{N}'
                        else:
                            s = item[1]
                            is_selected = (skill_idx == self.cursor)
                            trust = get_trust(s['id'])
                            tag = smart_tag(s)
                            tgc = tag_c.get(tag, GRY)
                            tc = trust_c.get(trust, GRY)

                            # Editor/scope label
                            editors = s.get('editors', [s.get('editor', 'claude')])
                            primary_editor = editors[0] if editors else 'claude'
                            ec = editor_c.get(primary_editor, GRY)
                            if len(editors) > 1:
                                editor_label = ','.join(editors[:2]) + '/' + s['scope']
                            else:
                                editor_label = primary_editor + '/' + s['scope']

                            indicator = f'{CYN}\u25b6{N}' if is_selected else ' '
                            cmd_trunc = trunc(s['triggerCommand'], NAME_W)
                            # Staleness badge
                            import time as _time
                            _lm = s.get('lastModified', 0)
                            _age_badge = ''
                            _badge_len = 0
                            if _lm > 0:
                                _age_d = int((_time.time() - _lm) / 86400)
                                if _age_d > 30:
                                    _badge_text = f'{_age_d}d'
                                    _badge_len = len(_badge_text) + 1
                                    _age_badge = f' {D}{ORA}{_badge_text}{N}'
                            # Shorten description to make room for badge
                            _desc_w = max(DESC_W - _badge_len, 5)
                            desc = trunc(s['description'], _desc_w)
                            name_s = f"{CYN}{cmd_trunc:<{NAME_W}}{N}"
                            tag_s = f"{tgc}{tag:<{TAG_W}}{N}"
                            editor_label = trunc(editor_label, EDITOR_W)
                            editor_s = f"{ec}{editor_label:<{EDITOR_W}}{N}"
                            trust_s = f"{tc}{trust:<{TRUST_W}}{N}"

                            if is_selected:
                                left = f'{V}{indicator}{B}{name_s}{N}{COL_SEP}{tag_s}{COL_SEP}{editor_s}{COL_SEP}{trust_s}{COL_SEP}{desc}{_age_badge}'
                            else:
                                left = f'{V}{indicator}{name_s}{COL_SEP}{tag_s}{COL_SEP}{editor_s}{COL_SEP}{trust_s}{COL_SEP}{D}{desc}{N}{_age_badge}'
                            skill_idx += 1
                    else:
                        left = f'{V}'

                    right = panel_lines[i] if i < len(panel_lines) else ''
                    buf.append(f'{left}\033[{LIST_W + 1}G{COL_SEP}{right}\033[{cols}G{V}')

                # Footer: separator + shortcuts + bottom border
                buf.append(f'{SEP}\u251c{"\u2500" * (cols - 2)}\u2524{N}')
                if self.searching:
                    keys_vis = '\u2191\u2193 navigate  ENTER select  ESC clear  s sort:' + self.sort_mode + '  f show:' + self.scope_filter + '  Tab explore  q quit'
                else:
                    keys_vis = '\u2191\u2193/jk navigate  ENTER detail  / search  s sort:' + self.sort_mode + '  f show:' + self.scope_filter + '  Tab explore  q quit'
                keys_vis = keys_vis[:inner]
                buf.append(padrow(keys_vis, f'{D}{keys_vis}{N}'))
                buf.append(f'{SEP}\u2514{"\u2500" * (cols - 2)}\u2518{N}')

        else:
            # ---- EXPLORE TAB ----
            rf = self.remote_filtered
            if rf:
                longest_name = max(len(s.get('triggerCommand', '/' + s['name'])) for s in rf)
            else:
                longest_name = 20
            NAME_W = min(max(longest_name + 2, 20), 35)
            REPO_W = 14
            STATUS_W = 10
            fixed_w = NAME_W + REPO_W + STATUS_W + 3
            DESC_W = max(LIST_W - fixed_w - 2, 10)

            # Column headers for Explore
            hdr = (f'{V} {D}{GRY}{"Name":<{NAME_W}}{N}{COL_SEP}'
                   f'{D}{GRY}{"Repo":<{REPO_W}}{N}{COL_SEP}'
                   f'{D}{GRY}{"Status":<{STATUS_W}}{N}{COL_SEP}'
                   f'{D}{GRY}{"Description"}{N}')
            buf.append(f'{hdr}\033[{LIST_W + 1}G{COL_SEP}{D}{GRY} Details{N}\033[{cols}G{V}')

            buf.append(f'{SEP}\u251c{"\u2500" * (LIST_W - 1)}\u253c{"\u2500" * PANEL_W}\u2524{N}')

            header_lines = len(buf)
            footer_lines = 3
            body_lines = rows - header_lines - footer_lines

            # Detail panel for selected remote skill
            selected_remote = None
            if rf and 0 <= self.remote_cursor < len(rf):
                selected_remote = rf[self.remote_cursor]
            if selected_remote:
                all_panel_lines = self._build_remote_detail_lines(selected_remote, PANEL_W)
                self.remote_panel_scroll = max(0, min(self.remote_panel_scroll, max(0, len(all_panel_lines) - body_lines)))
                panel_slice = all_panel_lines[self.remote_panel_scroll:self.remote_panel_scroll + body_lines]
                panel_lines = panel_slice + [''] * (body_lines - len(panel_slice))
            else:
                all_panel_lines = []
                panel_lines = ['' for _ in range(body_lines)]

            # Scroll management
            if self.remote_cursor < self.remote_scroll:
                self.remote_scroll = self.remote_cursor
            if self.remote_cursor >= self.remote_scroll + body_lines:
                self.remote_scroll = self.remote_cursor - body_lines + 1
            self.remote_scroll = max(0, min(self.remote_scroll, max(0, len(rf) - body_lines)))

            visible_skills = rf[self.remote_scroll:self.remote_scroll + body_lines]

            for i in range(body_lines):
                if i < len(visible_skills):
                    s = visible_skills[i]
                    actual_idx = self.remote_scroll + i
                    is_selected = (actual_idx == self.remote_cursor)

                    is_plugin = s.get('item_type') == 'plugin'
                    cmd = s.get('triggerCommand', '/' + s['name'])
                    if is_plugin and not cmd.startswith('/'):
                        cmd = f'\u25a3 {cmd}'  # plugin icon
                    repo_label = s.get('owner', '?')
                    if s.get('repo') == 'agent-hub':
                        repo_label = 'hub'

                    status = f'{GRN}\u2713 installed{N}' if s.get('installed') else f'{GRY}-{N}'
                    status_vis = '\u2713 installed' if s.get('installed') else '-'
                    desc = trunc(s.get('description', ''), DESC_W)

                    indicator = f'{CYN}\u25b6{N}' if is_selected else ' '
                    cmd_trunc = trunc(cmd, NAME_W)
                    name_s = f"{CYN}{cmd_trunc:<{NAME_W}}{N}"
                    repo_s = f"{ORA}{repo_label:<{REPO_W}}{N}"

                    if is_selected:
                        left = f'{V}{indicator}{B}{name_s}{N}{COL_SEP}{repo_s}{COL_SEP}{status}{" " * max(0, STATUS_W - len(status_vis))}{COL_SEP}{desc}'
                    else:
                        left = f'{V}{indicator}{name_s}{COL_SEP}{repo_s}{COL_SEP}{status}{" " * max(0, STATUS_W - len(status_vis))}{COL_SEP}{D}{desc}{N}'
                else:
                    left = f'{V}'

                right = panel_lines[i] if i < len(panel_lines) else ''
                buf.append(f'{left}\033[{LIST_W + 1}G{COL_SEP}{right}\033[{cols}G{V}')

            # Footer
            buf.append(f'{SEP}\u251c{"\u2500" * (cols - 2)}\u2524{N}')
            if self.install_status:
                keys_vis = self.install_status + '  '
            else:
                keys_vis = ''
            if self.searching:
                keys_vis += '\u2191\u2193 navigate  ESC clear  Tab installed  q quit'
            else:
                keys_vis += '\u2191\u2193/jk navigate  / search  f show:' + self.explore_filter + '  i install  R refresh  Tab installed  q quit'
            keys_vis = keys_vis[:inner]
            buf.append(padrow(keys_vis, f'{D}{keys_vis}{N}'))
            buf.append(f'{SEP}\u2514{"\u2500" * (cols - 2)}\u2518{N}')

        # Write to screen
        sys.stdout.write(CLR)
        sys.stdout.write('\r\n'.join(buf[:rows]))
        sys.stdout.flush()

    def _switch_tab(self):
        """Toggle between installed and explore tabs."""
        self.install_status = ''
        if self.active_tab == 'installed':
            self.active_tab = 'explore'
        else:
            self.active_tab = 'installed'
        # Clear search when switching tabs, re-filter both
        self.search = ''
        self.searching = False
        self.filter_skills()
        self.filter_remote_skills()

    def handle_key(self, key):
        # Handle mouse scroll events (tuples)
        if isinstance(key, tuple):
            event = key[0]
            col = key[1] if len(key) > 1 else 0
            rows, cols = term_size()
            PANEL_W = min(max(cols // 3, 30), 50)
            LIST_W = cols - PANEL_W - 1
            if col > LIST_W:
                # Mouse is over the detail panel
                if self.active_tab == 'explore':
                    if event == 'mouse_scroll_up':
                        self.remote_panel_scroll = max(0, self.remote_panel_scroll - 3)
                    elif event == 'mouse_scroll_down':
                        self.remote_panel_scroll += 3
                else:
                    if event == 'mouse_scroll_up':
                        self.detail_panel_scroll = max(0, self.detail_panel_scroll - 3)
                    elif event == 'mouse_scroll_down':
                        self.detail_panel_scroll += 3
            else:
                # Mouse is over the skill list
                if self.active_tab == 'explore':
                    if event == 'mouse_scroll_up':
                        self.move_remote_cursor(self.remote_cursor - 3)
                    elif event == 'mouse_scroll_down':
                        self.move_remote_cursor(self.remote_cursor + 3)
                else:
                    if event == 'mouse_scroll_up':
                        self.move_cursor(self.cursor - 3)
                    elif event == 'mouse_scroll_down':
                        self.move_cursor(self.cursor + 3)
            return

        if key == 'mouse_other':
            return

        # Tab switching (works in any mode except detail view)
        if key == '\t' and not self.detail_skill:
            self._switch_tab()
            return
        if key == '1' and not self.searching and not self.detail_skill:
            if self.active_tab != 'installed':
                self._switch_tab()
            return
        if key == '2' and not self.searching and not self.detail_skill:
            if self.active_tab != 'explore':
                self._switch_tab()
            return

        if self.detail_skill:
            # Detail view keys (installed tab only)
            if key in ('esc', 'q', 'left', 'backspace'):
                self.detail_skill = None
                self.detail_scroll = 0
            elif key in ('down', 'j'):
                self.detail_scroll += 1
            elif key in ('up', 'k'):
                self.detail_scroll = max(0, self.detail_scroll - 1)
            elif key == 'pgdn':
                rows, _ = term_size()
                self.detail_scroll += rows - 5
            elif key == 'pgup':
                rows, _ = term_size()
                self.detail_scroll = max(0, self.detail_scroll - (rows - 5))
            return

        if self.searching:
            if key == 'esc':
                self.searching = False
                self.search = ''
                self.filter_skills()
                self.filter_remote_skills()
            elif key == 'enter':
                self.searching = False
                if self.active_tab == 'installed' and self.filtered:
                    self.detail_skill = self.filtered[self.cursor]
            elif key == 'backspace':
                if self.search:
                    self.search = self.search[:-1]
                    self.filter_skills()
                    self.filter_remote_skills()
                else:
                    self.searching = False
            elif key in ('up',):
                if self.active_tab == 'explore':
                    self.remote_cursor = max(0, self.remote_cursor - 1)
                else:
                    self.cursor = max(0, self.cursor - 1)
            elif key in ('down',):
                if self.active_tab == 'explore':
                    self.remote_cursor = min(max(0, len(self.remote_filtered) - 1), self.remote_cursor + 1)
                else:
                    self.cursor = min(max(0, len(self.filtered) - 1), self.cursor + 1)
            elif len(key) == 1 and key.isprintable():
                self.search += key
                self.filter_skills()
                self.filter_remote_skills()
            return

        # Normal mode
        if key in ('q', 'ctrl-c'):
            self.running = False
            return

        if self.active_tab == 'explore':
            # Explore tab normal mode
            if key in ('down', 'j'):
                self.move_remote_cursor(self.remote_cursor + 1)
            elif key in ('up', 'k'):
                self.move_remote_cursor(self.remote_cursor - 1)
            elif key == 'pgdn':
                rows, _ = term_size()
                self.move_remote_cursor(self.remote_cursor + (rows - 5))
            elif key == 'pgup':
                rows, _ = term_size()
                self.move_remote_cursor(self.remote_cursor - (rows - 5))
            elif key == 'G':
                self.move_remote_cursor(max(0, len(self.remote_filtered) - 1))
            elif key == 'g':
                self.remote_cursor = 0
                self.remote_scroll = 0
                self.remote_panel_scroll = 0
            elif key == '/':
                self.searching = True
                self.search = ''
                self.install_status = ''
            elif key == 'enter':
                # Fetch full SKILL.md for current skill
                if self.remote_filtered:
                    skill = self.remote_filtered[self.remote_cursor]
                    skill_id = skill.get('id', skill['name'])
                    if skill_id not in self._remote_content_cache:
                        self.install_status = 'Loading SKILL.md...'
                        self.draw()
                        self._fetch_remote_skill_md(skill)
                        self.install_status = ''
                    self.remote_panel_scroll = 0
            elif key == 'i':
                self.install_selected_remote_skill()
            elif key == 'R':
                self.install_status = 'Refreshing remote cache...'
                self.draw()
                import subprocess as _sp
                # Call the script's fetch-remote subcommand
                script_path = os.environ.get('SKILL_BROWSER_SCRIPT', '')
                if script_path:
                    try:
                        _sp.run(['bash', script_path, 'fetch-remote'],
                                capture_output=True, timeout=60)
                    except Exception:
                        pass
                # Reload remote skills from cache
                remote_skills.clear()
                if os.path.isdir(REMOTE_CACHE_DIR):
                    import glob as _glob
                    for cache_file in _glob.glob(os.path.join(REMOTE_CACHE_DIR, '*.json')):
                        try:
                            with open(cache_file) as cf:
                                items = json.load(cf)
                            if isinstance(items, list):
                                for item in items:
                                    item['installed'] = (
                                        item.get('name', '').lower() in local_ids
                                        or item.get('id', '').lower() in local_ids
                                    )
                                    remote_skills.append(item)
                        except Exception:
                            pass
                self.filter_remote_skills()
                self.install_status = f'Refreshed: {len(remote_skills)} remote skills'
            elif key == 'f':
                idx = self.EXPLORE_FILTERS.index(self.explore_filter)
                self.explore_filter = self.EXPLORE_FILTERS[(idx + 1) % len(self.EXPLORE_FILTERS)]
                self.filter_remote_skills()
            elif key == 'esc':
                if self.search:
                    self.search = ''
                    self.filter_remote_skills()
        else:
            # Installed tab normal mode
            if key in ('down', 'j'):
                self.move_cursor(self.cursor + 1)
            elif key in ('up', 'k'):
                self.move_cursor(self.cursor - 1)
            elif key == 'pgdn':
                rows, _ = term_size()
                self.move_cursor(self.cursor + (rows - 5))
            elif key == 'pgup':
                rows, _ = term_size()
                self.move_cursor(self.cursor - (rows - 5))
            elif key == 'G':
                self.move_cursor(max(0, len(self.filtered) - 1))
            elif key == 'g':
                self.cursor = 0
                self.scroll = 0
            elif key == '/':
                self.searching = True
                self.search = ''
            elif key == 's':
                idx = self.SORT_MODES.index(self.sort_mode)
                self.sort_mode = self.SORT_MODES[(idx + 1) % len(self.SORT_MODES)]
                self.filter_skills()
            elif key == 'f':
                idx = self.SCOPE_FILTERS.index(self.scope_filter)
                self.scope_filter = self.SCOPE_FILTERS[(idx + 1) % len(self.SCOPE_FILTERS)]
                self.filter_skills()
            elif key == 'enter':
                if self.filtered:
                    self.detail_skill = self.filtered[self.cursor]
                    self.detail_scroll = 0
            elif key == 'esc':
                if self.search:
                    self.search = ''
                    self.filter_skills()

    def run(self):
        global TTY_FD
        try:
            tty_file = open('/dev/tty', 'r+b', buffering=0)
            TTY_FD = tty_file.fileno()
            old_settings = termios.tcgetattr(TTY_FD)
        except (OSError, termios.error):
            self.run_static()
            return

        try:
            tty.setraw(TTY_FD)
            sys.stdout.write(ALT_SCREEN_ON + HIDE_CURSOR + MOUSE_ON)
            sys.stdout.flush()

            def on_resize(sig, frame):
                self.draw()
            signal.signal(signal.SIGWINCH, on_resize)

            while self.running:
                try:
                    self.draw()
                except (termios.error, OSError):
                    break
                except Exception as e:
                    # Restore terminal before crashing so user sees the error
                    termios.tcsetattr(TTY_FD, termios.TCSADRAIN, old_settings)
                    sys.stdout.write(MOUSE_OFF + SHOW_CURSOR + ALT_SCREEN_OFF)
                    sys.stdout.flush()
                    raise
                key = get_key()
                self.handle_key(key)
        except (termios.error, OSError):
            pass
        finally:
            try:
                termios.tcsetattr(TTY_FD, termios.TCSADRAIN, old_settings)
            except (termios.error, OSError):
                pass
            sys.stdout.write(MOUSE_OFF + SHOW_CURSOR + ALT_SCREEN_OFF)
            sys.stdout.flush()
            tty_file.close()

    def run_static(self):
        """Fallback: pipe through less or print paginated output."""
        rows, cols = term_size()
        if self.filtered:
            longest = max(len(s['triggerCommand']) for s in self.filtered)
        else:
            longest = 20
        NAME_W = min(max(longest + 2, 20), cols // 3)
        TAG_W = 14
        EDITOR_W = 14
        TRUST_W = 9
        DESC_W = max(cols - NAME_W - TAG_W - EDITOR_W - TRUST_W - 8, 15)

        total = len(self.filtered)
        all_total = len(all_skills)
        editors_str = ', '.join(all_editor_names) if all_editor_names else 'claude'
        count_str = f'{total} skills' if total == all_total else f'{total}/{all_total} skills'
        if self.search:
            print(f'{B}Skill Browser{N}  {BLU}{count_str}{N}  {D}editors: {editors_str}{N}  search: "{self.search}"')
        else:
            print(f'{B}Skill Browser{N}  {BLU}{count_str}{N}  {D}editors: {editors_str}{N}')
        print()
        print(f'  {D}{GRY}{"Name":<{NAME_W}} {"Type":<{TAG_W}} {"Editor":<{EDITOR_W}} {"Source":<{TRUST_W}} {"Description"}{N}')
        print(f'  {SEP}{"─" * NAME_W} {"─" * TAG_W} {"─" * EDITOR_W} {"─" * TRUST_W} {"─" * DESC_W}{N}')

        for s in self.filtered:
            trust = get_trust(s['id'])
            tag = smart_tag(s)
            tgc = tag_c.get(tag, GRY)
            tc = trust_c.get(trust, GRY)
            editors = s.get('editors', [s.get('editor', 'claude')])
            primary_editor = editors[0] if editors else 'claude'
            ec = editor_c.get(primary_editor, GRY)
            if len(editors) > 1:
                editor_label = ','.join(editors[:2]) + '/' + s['scope']
            else:
                editor_label = primary_editor + '/' + s['scope']
            desc = trunc(s['description'], DESC_W)
            print(f"  {CYN}{s['triggerCommand']:<{NAME_W}}{N} {tgc}{tag:<{TAG_W}}{N} {ec}{editor_label:<{EDITOR_W}}{N} {tc}{trust:<{TRUST_W}}{N} {D}{desc}{N}")
            if s.get('isCompound') and s.get('subSkills'):
                for si, sub in enumerate(s['subSkills']):
                    is_last = (si == len(s['subSkills']) - 1)
                    pfx = '\u2514' if is_last else '\u251c'
                    sub_desc = trunc(sub.get('description', ''), DESC_W + TAG_W + EDITOR_W + TRUST_W)
                    print(f"    {D}{pfx} {CYN}{sub['command']:<{NAME_W - 2}}{N} {D}{sub_desc}{N}")


browser = Browser()
browser.run()
PYEOF
}

REMOTE_CACHE_DIR="$SB_CACHE_DIR/remote-cache"
CUSTOM_REPOS_FILE="$SB_CACHE_DIR/custom-repos.txt"

# Built-in skill repos: "owner/repo:skills_path"
REMOTE_REPOS=(
    "anthropics/skills:skills"
    "obra/superpowers:skills"
    "levnikolaevich/claude-code-skills:"
)

# Load user-added custom repos from config file
if [ -f "$CUSTOM_REPOS_FILE" ]; then
    while IFS= read -r line; do
        line="${line%%#*}"  # strip comments
        line="${line// /}"  # strip whitespace
        [ -z "$line" ] && continue
        REMOTE_REPOS+=("$line")
    done < "$CUSTOM_REPOS_FILE"
fi

fetch_remote_repos() {
    mkdir -p "$REMOTE_CACHE_DIR"
    local now
    now=$(date +%s)

    for repo_spec in "${REMOTE_REPOS[@]}"; do
        local repo="${repo_spec%%:*}"
        local skills_path="${repo_spec#*:}"
        local cache_file="$REMOTE_CACHE_DIR/${repo//\//--}.json"
        # TTL: 4 hours
        if [ -f "$cache_file" ]; then
            local file_time age
            if [[ "$OSTYPE" == darwin* ]]; then
                file_time=$(stat -f%m "$cache_file" 2>/dev/null || echo 0)
            else
                file_time=$(stat -c%Y "$cache_file" 2>/dev/null || echo 0)
            fi
            age=$((now - file_time))
            if [ "$age" -lt 14400 ]; then
                continue
            fi
        fi

        echo -e "${DIM}Fetching remote skills from ${repo}...${NC}" >&2
        SB_REPO="$repo" SB_SKILLS_PATH="$skills_path" python3 << 'PYEOF_REMOTE' > "$cache_file" 2>/dev/null || echo '[]' > "$cache_file"
import subprocess, json, base64, sys, os

repo = os.environ['SB_REPO']
skills_path = os.environ.get('SB_SKILLS_PATH', '')
owner, name = repo.split('/')

def gh_api(path):
    """Call gh api, return parsed JSON or None."""
    try:
        r = subprocess.run(['gh', 'api', path], capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            return json.loads(r.stdout)
    except Exception:
        pass
    return None

def curl_api(path):
    """Fallback: curl GitHub API (unauthenticated, 60 req/hr)."""
    try:
        r = subprocess.run(
            ['curl', '-sf', f'https://api.github.com/{path}'],
            capture_output=True, text=True, timeout=30
        )
        if r.returncode == 0:
            return json.loads(r.stdout)
    except Exception:
        pass
    return None

def api(path):
    return gh_api(path) or curl_api(path)

skills = []

# Detect default branch
repo_info = api(f'repos/{repo}')
default_branch = 'main'
if repo_info and isinstance(repo_info, dict):
    default_branch = repo_info.get('default_branch', 'main')

# List skill directories from configured path
api_path = f'repos/{repo}/contents/{skills_path}' if skills_path else f'repos/{repo}/contents'
contents = api(api_path)
if not contents or not isinstance(contents, list):
    print('[]')
    sys.exit(0)

dirs = [item for item in contents if item.get('type') == 'dir']

# Filter: only dirs that contain SKILL.md (batch-check via tree API for efficiency)
# For small repos, just check each dir. For large repos (>30 dirs), use tree API.
skill_dirs = []
if len(dirs) > 30:
    # Use git tree API to find all SKILL.md files in one call
    tree = api(f'repos/{repo}/git/trees/{default_branch}?recursive=1')
    skill_md_paths = set()
    if tree and tree.get('tree'):
        for item in tree['tree']:
            if item.get('path', '').endswith('/SKILL.md'):
                # Extract parent dir path
                parent = '/'.join(item['path'].split('/')[:-1])
                skill_md_paths.add(parent)
    skill_dirs = [d for d in dirs if d['path'] in skill_md_paths]
else:
    skill_dirs = dirs  # Check individually below

for d in skill_dirs:
    skill_name = d['name']
    # For small repos, verify SKILL.md exists; for large repos already filtered
    description = ''
    category = ''

    if len(dirs) <= 30:
        # Quick check: does SKILL.md exist?
        skill_md = api(f'repos/{repo}/contents/{d["path"]}/SKILL.md')
        if not skill_md or not skill_md.get('content'):
            skill_md = api(f'repos/{repo}/contents/{d["path"]}/skill.md')
        if not skill_md or not skill_md.get('content'):
            continue  # Skip dirs without SKILL.md

        try:
            raw = base64.b64decode(skill_md['content']).decode('utf-8', errors='ignore')
            if raw.startswith('---'):
                parts = raw.split('---', 2)
                if len(parts) >= 3:
                    for line in parts[1].strip().split('\n'):
                        if line.startswith('description:'):
                            description = line.split(':', 1)[1].strip().strip('"').strip("'")
                        elif line.startswith('category:'):
                            category = line.split(':', 1)[1].strip().strip('"').strip("'")
        except Exception:
            pass

    skills.append({
        'name': skill_name,
        'id': f'{owner}/{skill_name}',
        'triggerCommand': f'/{skill_name}',
        'description': description or f'Skill from {repo}',
        'scope': 'remote',
        'lineCount': 0,
        'isCompound': False,
        'subSkills': [],
        'provides': [],
        'requires': {'mcps': [], 'bins': [], 'skills': []},
        'argumentHint': '',
        'repo': repo,
        'owner': owner,
        'remote_url': f'https://github.com/{repo}/tree/{default_branch}/{d["path"]}',
        'remote_path': d['path'],
        'installed': False,
    })

print(json.dumps(skills))
PYEOF_REMOTE
    done
}

fetch_hub_skills() {
    mkdir -p "$REMOTE_CACHE_DIR"
    local cache_file="$REMOTE_CACHE_DIR/hub--agent-hub.json"
    local now
    now=$(date +%s)

    if [ -f "$cache_file" ]; then
        local file_time age
        if [[ "$OSTYPE" == darwin* ]]; then
            file_time=$(stat -f%m "$cache_file" 2>/dev/null || echo 0)
        else
            file_time=$(stat -c%Y "$cache_file" 2>/dev/null || echo 0)
        fi
        age=$((now - file_time))
        if [ "$age" -lt 14400 ]; then
            return 0
        fi
    fi

    command -v skills >/dev/null 2>&1 || { echo '[]' > "$cache_file"; return 0; }

    echo -e "${DIM}Fetching skills from Agent Hub...${NC}" >&2
    python3 << 'PYEOF_HUB' > "$cache_file" 2>/dev/null || echo '[]' > "$cache_file"
import subprocess, json, re

try:
    out = subprocess.run(
        ['skills', 'search', '', '-n', '50'],
        capture_output=True, text=True, timeout=30
    ).stdout
except Exception:
    print('[]')
    exit()

skills = []
for line in out.splitlines():
    line = line.strip()
    if not line or line.startswith('Install:') or line.startswith('='):
        continue
    # Parse "name - description" format
    parts = line.split(' - ', 1)
    if len(parts) >= 1:
        name = parts[0].strip()
        desc = parts[1].strip() if len(parts) > 1 else ''
        if name and not name.startswith('#') and not name.startswith('No '):
            skills.append({
                'name': name,
                'id': f'hub/{name}',
                'triggerCommand': f'/{name}',
                'description': desc or f'Skill from Agent Hub',
                'scope': 'remote',
                'lineCount': 0,
                'isCompound': False,
                'subSkills': [],
                'provides': [],
                'requires': {'mcps': [], 'bins': [], 'skills': []},
                'argumentHint': '',
                'repo': 'agent-hub',
                'owner': 'hub',
                'remote_url': '',
                'remote_path': '',
                'installed': False,
            })

print(json.dumps(skills))
PYEOF_HUB
}

# Built-in plugin repos: "owner/repo:dir1,dir2,..."
REMOTE_PLUGIN_REPOS=(
    "anthropics/claude-plugins-official:plugins,external_plugins"
)

# Load user-added custom plugin repos
CUSTOM_PLUGIN_REPOS_FILE="$SB_CACHE_DIR/custom-plugin-repos.txt"
if [ -f "$CUSTOM_PLUGIN_REPOS_FILE" ]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line// /}"
        [ -z "$line" ] && continue
        REMOTE_PLUGIN_REPOS+=("$line")
    done < "$CUSTOM_PLUGIN_REPOS_FILE"
fi

fetch_plugin_repos() {
    mkdir -p "$REMOTE_CACHE_DIR"
    local now
    now=$(date +%s)

    for repo_spec in "${REMOTE_PLUGIN_REPOS[@]}"; do
        local repo="${repo_spec%%:*}"
        local plugin_dirs="${repo_spec#*:}"
        local cache_file="$REMOTE_CACHE_DIR/${repo//\//--}--plugins.json"

        # TTL: 4 hours
        if [ -f "$cache_file" ]; then
            local file_time age
            if [[ "$OSTYPE" == darwin* ]]; then
                file_time=$(stat -f%m "$cache_file" 2>/dev/null || echo 0)
            else
                file_time=$(stat -c%Y "$cache_file" 2>/dev/null || echo 0)
            fi
            age=$((now - file_time))
            if [ "$age" -lt 14400 ]; then
                continue
            fi
        fi

        echo -e "${DIM}Fetching plugins from ${repo}...${NC}" >&2
        SB_REPO="$repo" SB_PLUGIN_DIRS="$plugin_dirs" python3 << 'PYEOF_PLUGIN' > "$cache_file" 2>/dev/null || echo '[]' > "$cache_file"
import subprocess, json, base64, sys, os

repo = os.environ['SB_REPO']
plugin_dirs = os.environ.get('SB_PLUGIN_DIRS', '').split(',')
owner = repo.split('/')[0]

def gh_api(path):
    try:
        r = subprocess.run(['gh', 'api', path], capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            return json.loads(r.stdout)
    except Exception:
        pass
    return None

def curl_api(path):
    try:
        r = subprocess.run(
            ['curl', '-sf', f'https://api.github.com/{path}'],
            capture_output=True, text=True, timeout=30
        )
        if r.returncode == 0:
            return json.loads(r.stdout)
    except Exception:
        pass
    return None

def api(path):
    return gh_api(path) or curl_api(path)

# Detect default branch
repo_info = api(f'repos/{repo}')
default_branch = 'main'
if repo_info and isinstance(repo_info, dict):
    default_branch = repo_info.get('default_branch', 'main')

plugins = []

for pdir in plugin_dirs:
    pdir = pdir.strip()
    if not pdir:
        continue
    contents = api(f'repos/{repo}/contents/{pdir}')
    if not contents or not isinstance(contents, list):
        continue

    dirs = [item for item in contents if item.get('type') == 'dir']

    for d in dirs:
        plugin_name = d['name']
        description = ''
        author = ''
        plugin_type = 'external' if 'external' in pdir else 'official'

        # Fetch plugin.json for metadata
        pjson = api(f'repos/{repo}/contents/{d["path"]}/.claude-plugin/plugin.json')
        if pjson and pjson.get('content'):
            try:
                raw = base64.b64decode(pjson['content']).decode('utf-8', errors='ignore')
                meta = json.loads(raw)
                description = meta.get('description', '')
                author = meta.get('author', '')
                if meta.get('name'):
                    plugin_name = meta['name']
            except Exception:
                pass

        plugins.append({
            'name': plugin_name,
            'id': f'{owner}/{plugin_name}',
            'triggerCommand': f'{plugin_name}',
            'description': description or f'Plugin from {repo}',
            'scope': 'remote',
            'lineCount': 0,
            'isCompound': False,
            'subSkills': [],
            'provides': [],
            'requires': {'mcps': [], 'bins': [], 'skills': []},
            'argumentHint': '',
            'repo': repo,
            'owner': owner,
            'remote_url': f'https://github.com/{repo}/tree/{default_branch}/{d["path"]}',
            'remote_path': d['path'],
            'installed': False,
            'item_type': 'plugin',
            'plugin_type': plugin_type,
            'author': author,
        })

print(json.dumps(plugins))
PYEOF_PLUGIN
    done
}

fetch_all_remote() {
    fetch_remote_repos
    fetch_plugin_repos
    fetch_hub_skills
}

py_static() {
    # Non-interactive output for piping or simple use
    python3 - "$@" << 'PYEOF'
import json, sys, os, re

SB_CACHE_DIR = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
INDEX = os.path.join(SB_CACHE_DIR, 'skill-index.json')
TRUST_CACHE = os.path.join(SB_CACHE_DIR, 'trust-cache.json')

with open(INDEX) as f:
    data = json.load(f)
trust_map = {}
try:
    with open(TRUST_CACHE) as f:
        trust_map = json.load(f)
except Exception:
    pass

skills = data['skills']

B, D, N = '\033[1m', '\033[2m', '\033[0m'
BLU, GRN, PUR, ORA, GRY, RED, CYN, YEL = (
    '\033[38;5;75m', '\033[38;5;78m', '\033[38;5;141m',
    '\033[38;5;214m', '\033[38;5;245m', '\033[38;5;203m',
    '\033[38;5;116m', '\033[38;5;228m'
)
SEP = '\033[38;5;238m'

TAG_OVERRIDES = {
    'data-question': 'Data', 'data-analysis-reviewer': 'Data',
    'signal-scanner': 'Research', 'signal-scanner-feedback': 'Research',
    'gather-context': 'Research', 'briefing': 'Research', 'performance': 'Research',
    'web-research': 'Research',
    'daily-context-sync': 'Productivity', 'dailypm': 'Productivity',
    'deploy': 'Engineering', 'scope-doc-generator': 'Product',
    'skill-architect': 'Automation', 'skill-maker': 'Automation',
    'self-improve': 'Automation', 'skill-list': 'Automation',
    'skill-browser': 'Automation', 'shopify-skills-judge': 'Automation',
    'shopify-skills': 'Automation', 'critique-loop': 'Automation',
    'ralph': 'Automation',
    'opportunity-score': 'Product', 'experiment-brief': 'Product',
    'fact-add': 'Productivity', 'brainstorm': 'Product',
    'second-brain': 'Productivity', 'pm-toolkit': 'Productivity',
    'gworkspace': 'Productivity',
    'browser-use': 'Browser', 'playwright-cli': 'Browser',
    'compound-engineering:git-worktree': 'Engineering',
    'compound-engineering:resolve-pr-parallel': 'Engineering',
    'compound-engineering:setup': 'Automation',
    'compound-engineering:compound-docs': 'Writing',
    'compound-engineering:every-style-editor': 'Writing',
    'compound-engineering:create-agent-skills': 'Automation',
    'compound-engineering:orchestrating-swarms': 'Automation',
    'superpowers:dispatching-parallel-agents': 'Automation',
    'canvas:canvas': 'Design', 'canvas:document': 'Writing',
    'canvas:calendar': 'Productivity', 'canvas:flight': 'Productivity',
    'obsidian:json-canvas': 'Productivity', 'obsidian:obsidian-bases': 'Productivity',
    'obsidian:obsidian-markdown': 'Writing',
    'playground:playground': 'Design',
    'qmd:release': 'Engineering',
    'marimo:marimo-notebook-creator': 'Data', 'marimo:marimo-reviewer': 'Data',
    'marimo:marimo-master': 'Data',
}
TAG_RULES = [
    ('Data',         ['bigquery', 'data warehouse', 'data analysis', 'statistical', 'data question', 'sql', 'data platform', 'marimo', 'notebook']),
    ('Research',     ['intelligence', 'crawl', 'signal scan', 'gather context', 'research', 'catch up', 'what did i miss']),
    ('Browser',      ['browser', 'web test', 'screenshot', 'form fill', 'navigate website', 'playwright', 'chrome devtools', 'chrome-devtools']),
    ('Media',        ['image', 'video', 'music', 'speech', 'radio', 'generat']),
    ('Design',       ['polaris', 'figma', 'design system', 'ui component', 'ui extension', 'cro', 'variant protot', 'refine', 'polish', 'frontend interface', 'frontend-design', 'playground']),
    ('Product',      ['prd', 'requirement', 'roadmap', 'gsd', 'scope doc', 'experiment', 'opportunity', 'rice', 'spec out', 'readout']),
    ('Engineering',  ['code review', 'pull request', 'pr comment', 'debug', 'pipeline', 'monorepo', 'graphite', 'git worktree', 'migration', 'buildkite', 'observe', 'deploy', 'implement', 'release', 'worktree', 'pr-review', 'commit']),
    ('Writing',      ['weekly update', 'impact recap', 'weekly impact', 'write-cli', 'write.quick', 'markdown', 'style guide', 'editing copy', 'documentation']),
    ('Productivity', ['workflow', 'morning', 'daily', 'calendar', 'sync', 'knowledge', 'organize', 'transcri', 'meeting', 'reflect', 'journal', 'session', 'heartbeat', 'fact', 'summar', 'memory', 'synthesize', 'obsidian', 'canvas']),
    ('Automation',   ['agent skill', 'skill-maker', 'skill-architect', 'self-improve', 'critique loop', 'parallel agent', 'parallel process', 'orchestrat', 'autonomous', 'ralph', 'slash command', 'dispatching']),
]
tag_c = {
    'Design': '\033[38;5;213m', 'Engineering': '\033[38;5;203m', 'Product': BLU,
    'Data': YEL, 'Writing': '\033[38;5;180m', 'Productivity': GRN,
    'Automation': ORA, 'Research': PUR, 'Media': '\033[38;5;141m', 'Browser': CYN,
}

def smart_tag(s):
    sid = s.get('id', s.get('name', ''))
    if sid in TAG_OVERRIDES:
        return TAG_OVERRIDES[sid]
    text = (s.get('name', '') + ' ' + s.get('description', '')).lower()
    for tag, keywords in TAG_RULES:
        for kw in keywords:
            if kw.lower() in text:
                return tag
    return 'General'

def trunc(s, n):
    if not s: return ''
    return s[:n-1] + '\u2026' if len(s) > n else s

def get_trust(sid):
    return trust_map.get(sid, 'Manual')

trust_c = {'Comm': CYN, 'Manual': GRY, 'World': YEL}
scope_c = {'local': GRN, 'global': PUR, 'both': ORA, 'plugin': YEL}
editor_c = {
    'claude': CYN, 'codex': '\033[38;5;111m', 'cursor': '\033[38;5;213m',
    'opencode': GRN, 'pi': ORA,
}

def print_table(skill_list):
    try: cols = os.get_terminal_size().columns
    except: cols = 120
    if skill_list:
        longest = max(len(s['triggerCommand']) for s in skill_list)
    else:
        longest = 20
    NAME_W = min(max(longest + 2, 20), cols // 3)
    TAG_W, EDITOR_W, TRUST_W = 14, 14, 9
    DESC_W = max(cols - NAME_W - TAG_W - EDITOR_W - TRUST_W - 8, 15)

    for s in skill_list:
        trust = get_trust(s['id'])
        tag = smart_tag(s)
        tgc = tag_c.get(tag, GRY)
        editors = s.get('editors', [s.get('editor', 'claude')])
        primary = editors[0] if editors else 'claude'
        ec = editor_c.get(primary, GRY)
        if len(editors) > 1:
            elabel = ','.join(editors[:2]) + '/' + s['scope']
        else:
            elabel = primary + '/' + s['scope']
        desc = trunc(s['description'], DESC_W)
        print(f"  {CYN}{s['triggerCommand']:<{NAME_W}}{N} {tgc}{tag:<{TAG_W}}{N} {ec}{elabel:<{EDITOR_W}}{N} {trust_c.get(trust,GRY)}{trust:<{TRUST_W}}{N} {D}{desc}{N}")
        if s.get('isCompound') and s.get('subSkills'):
            for si, sub in enumerate(s['subSkills']):
                is_last = (si == len(s['subSkills']) - 1)
                pfx = '\u2514' if is_last else '\u251c'
                sub_desc = trunc(sub.get('description', ''), DESC_W + TAG_W + EDITOR_W + TRUST_W)
                print(f"    {D}{pfx} {CYN}{sub['command']:<{NAME_W - 2}}{N} {D}{sub_desc}{N}")

t = data['totalSkills']; l = data['localCount']; g = data['globalCount']; p = data.get('pluginCount', 0)
parts = [f'{GRN}{l} local{N}', f'{PUR}{g} global{N}']
if p: parts.append(f'{YEL}{p} plugin{N}')
print(f'{B}Skill Browser{N}  {BLU}{t} skills{N}  ({", ".join(parts)})')
print()

# Group by smart tag
by_tag = {}
for s in skills:
    tag = smart_tag(s)
    by_tag.setdefault(tag, []).append(s)

tag_order = ['Product', 'Engineering', 'Design', 'Data', 'Research', 'Writing', 'Productivity', 'Automation', 'Media', 'Browser', 'General']
for tag in tag_order:
    if tag not in by_tag: continue
    items = sorted(by_tag[tag], key=lambda s: s['name'])
    c = tag_c.get(tag, GRY)
    print(f'  {B}{c}{tag.upper()}{N}  {D}({len(items)}){N}')
    print_table(items)
    print()
PYEOF
}

# Main
cmd="${1:-}"
case "$cmd" in
    refresh)
        echo -e "${BLUE}Regenerating skill index...${NC}"
        detect_editors
        export SB_EDITORS_FILE="$SB_CACHE_DIR/editors.json"
        bash "${SCRIPT_DIR}/generate-skill-index.sh"
        build_trust_cache
        echo -e "${GREEN}Done.${NC}"
        ;;
    web)
        ensure_index
        if [ -f "$SB_CACHE_DIR/index.html" ]; then
            echo -e "${GREEN}Opening skill browser...${NC}"
            open "$SB_CACHE_DIR/index.html" 2>/dev/null || xdg-open "$SB_CACHE_DIR/index.html" 2>/dev/null
        else
            echo -e "${RED}No HTML found. Is skill-browser-template.html alongside the scripts?${NC}"
        fi
        ;;
    help|-h|--help)
        echo -e "${BOLD}Skill Browser CLI${NC}"
        echo ""
        echo -e "  ${BOLD}Interactive:${NC}"
        echo -e "  ${CYAN}sb${NC}                           Interactive browser (TUI)"
        echo -e "  ${CYAN}sb explore${NC}                   Launch directly on Explore tab"
        echo -e "  ${CYAN}sb search${NC} <query>            Interactive browser with pre-filled search"
        echo ""
        echo -e "  ${BOLD}Skill Management:${NC}"
        echo -e "  ${CYAN}sb list${NC} [--local|--global|--json]   List installed skills"
        echo -e "  ${CYAN}sb search${NC} <q> [--json] [-n N]      Search skills (non-interactive when piped)"
        echo -e "  ${CYAN}sb info${NC} <name>               Detail view (alias for show)"
        echo -e "  ${CYAN}sb show${NC} <name>               Detail view for installed skill"
        echo -e "  ${CYAN}sb install${NC} <name> [opts]     Install a skill (auto-resolves deps)"
        echo -e "     ${DIM}--editor <e>                 Target editor (claude|codex|cursor|opencode|pi|all)${NC}"
        echo -e "     ${DIM}--local                      Install to project .claude/skills/${NC}"
        echo -e "     ${DIM}--global                     Install to ~/.claude/skills/${NC}"
        echo -e "     ${DIM}--no-deps                    Skip dependency auto-install${NC}"
        echo -e "  ${CYAN}sb add${NC} <name>                Install to project (alias for install --local)"
        echo -e "  ${CYAN}sb remove${NC} <name> [--local|--global]  Remove an installed skill"
        echo -e "  ${CYAN}sb update${NC} [name] [--local|--global]  Update skills from source"
        echo -e "  ${CYAN}sb validate${NC} [path]           Validate skill(s) have correct SKILL.md"
        echo -e "  ${CYAN}sb init${NC}                      Initialize .claude/skills/ directory"
        echo ""
        echo -e "  ${BOLD}Diagnostics & Sync:${NC}"
        echo -e "  ${CYAN}sb why${NC} <name>                Show where a skill loads from"
        echo -e "  ${CYAN}sb run${NC} <name> [args]         Invoke a skill via its editor CLI"
        echo -e "  ${CYAN}sb diff${NC} [--json]             Compare local vs global vs remote"
        echo -e "  ${CYAN}sb stale${NC} [--days N]          List skills older than N days (default 30)"
        echo -e "  ${CYAN}sb export${NC} [--file F]         Export installed skills manifest"
        echo -e "  ${CYAN}sb import${NC} [--file F]         Install from manifest (--dry-run)"
        echo ""
        echo -e "  ${BOLD}Non-interactive (pipeable):${NC}"
        echo -e "  ${CYAN}sb cats${NC}                      Group installed skills by category"
        echo -e "  ${CYAN}sb explore-list${NC} [opts] [q]   List remote skills/plugins (agent-friendly)"
        echo -e "     ${DIM}--type skills|plugins        Filter by type (default: all)${NC}"
        echo -e "     ${DIM}--json                       Output as JSON array${NC}"
        echo -e "     ${DIM}--repo <owner>               Filter by repo owner${NC}"
        echo -e "  ${CYAN}sb remote-show${NC} <name>       Show detail of a remote skill/plugin"
        echo ""
        echo -e "  ${BOLD}Marketplaces:${NC}"
        echo -e "  ${CYAN}sb repos${NC}                    List all skill/plugin repos (built-in + custom)"
        echo -e "  ${CYAN}sb add-repo${NC} <owner/repo>    Add a custom GitHub skill repo"
        echo -e "  ${CYAN}sb add-repo${NC} <owner/repo> --plugins <dir>  Add a custom plugin repo"
        echo -e "  ${CYAN}sb remove-repo${NC} <owner/repo> Remove a custom repo"
        echo ""
        echo -e "  ${BOLD}Maintenance:${NC}"
        echo -e "  ${CYAN}sb refresh${NC}                  Regenerate local index + trust cache"
        echo -e "  ${CYAN}sb fetch-remote${NC}             Refresh remote skill/plugin cache"
        echo -e "  ${CYAN}sb web${NC}                      Open the HTML browser"
        echo ""
        echo -e "  ${DIM}TUI keys: \u2191\u2193/jk navigate  ENTER detail  / search  f filter  Tab switch tab  q quit${NC}"
        echo -e "  ${DIM}Explore:  i install  f show:all/skills/plugins  R refresh  Tab switch back${NC}"
        ;;
    fetch-remote)
        fetch_all_remote
        echo -e "${GREEN}Remote cache refreshed.${NC}"
        ;;
    list)
        # Non-interactive list of installed skills (skills CLI parity)
        ensure_index
        build_trust_cache
        detect_editors
        shift  # remove 'list'
        python3 - "$@" << 'PYEOF_LIST'
import json, sys, os

SB_CACHE_DIR = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
INDEX = os.path.join(SB_CACHE_DIR, 'skill-index.json')

with open(INDEX) as f:
    data = json.load(f)

args = sys.argv[1:]
scope_filter = ''
json_output = False
for a in args:
    if a == '--local':
        scope_filter = 'local'
    elif a == '--global':
        scope_filter = 'global'
    elif a == '--json':
        json_output = True

skills = data['skills']
if scope_filter == 'local':
    skills = [s for s in skills if s.get('scope') in ('local', 'both')]
elif scope_filter == 'global':
    skills = [s for s in skills if s.get('scope') in ('global', 'both')]

skills.sort(key=lambda s: s.get('triggerCommand', s['name']))

if json_output:
    out = []
    for s in skills:
        out.append({
            'name': s['name'],
            'command': s.get('triggerCommand', '/' + s['name']),
            'scope': s.get('scope', 'unknown'),
            'editor': s.get('editor', 'claude'),
            'editors': s.get('editors', []),
            'description': s.get('description', ''),
            'category': s.get('category', ''),
            'isCompound': s.get('isCompound', False),
            'subSkills': len(s.get('subSkills', [])),
            'skillPath': s.get('skillPath', ''),
        })
    print(json.dumps(out, indent=2))
else:
    B, D, N = '\033[1m', '\033[2m', '\033[0m'
    CYN, GRN, PUR, ORA, GRY = '\033[38;5;116m', '\033[38;5;78m', '\033[38;5;141m', '\033[38;5;214m', '\033[38;5;245m'
    scope_c = {'local': GRN, 'global': PUR, 'both': ORA}

    try: cols = os.get_terminal_size().columns
    except: cols = 120
    CMD_W = 35
    SCOPE_W = 8
    EDITOR_W = 12
    DESC_W = max(cols - CMD_W - SCOPE_W - EDITOR_W - 8, 15)

    label = f'{len(skills)} installed skills'
    if scope_filter:
        label += f' ({scope_filter})'
    print(f'{B}Skills{N}  {CYN}{label}{N}')
    print()
    print(f'  {D}{GRY}{"Command":<{CMD_W}} {"Scope":<{SCOPE_W}} {"Editor":<{EDITOR_W}} {"Description"}{N}')
    for s in skills:
        cmd = s.get('triggerCommand', '/' + s['name'])
        scope = s.get('scope', '?')
        sc = scope_c.get(scope, GRY)
        editor = s.get('editor', 'claude')
        desc = s.get('description', '')
        if len(desc) > DESC_W:
            desc = desc[:DESC_W - 1] + '\u2026'
        subs = len(s.get('subSkills', []))
        sub_label = f' (+{subs})' if subs > 0 else ''
        print(f'  {CYN}{cmd:<{CMD_W}}{N} {sc}{scope:<{SCOPE_W}}{N} {GRY}{editor:<{EDITOR_W}}{N} {D}{desc}{N}{sub_label}')
PYEOF_LIST
        ;;
    search)
        # If stdout is a TTY and no --json flag, launch interactive TUI
        shift  # remove 'search'
        is_json=false
        limit=20
        query_parts=()
        for arg in "$@"; do
            case "$arg" in
                --json) is_json=true ;;
                -n) : ;;  # next arg is limit
                *) query_parts+=("$arg") ;;
            esac
        done
        # Parse -n value
        prev=""
        for arg in "$@"; do
            if [ "$prev" = "-n" ]; then
                limit="$arg"
            fi
            prev="$arg"
        done
        query="${query_parts[*]:-}"

        if [ "$is_json" = true ] || ! [ -t 1 ]; then
            # Non-interactive search
            ensure_index
            python3 - "$query" "$limit" "$is_json" << 'PYEOF_SEARCH'
import json, sys, os, re

SB_CACHE_DIR = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
INDEX = os.path.join(SB_CACHE_DIR, 'skill-index.json')

with open(INDEX) as f:
    data = json.load(f)

query = sys.argv[1] if len(sys.argv) > 1 else ''
limit = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 20
is_json = sys.argv[3] == 'true' if len(sys.argv) > 3 else False

def matches(s, q):
    q = q.lower()
    fields = [s['name'], s['description'], s.get('triggerCommand', ''), s.get('argumentHint', '')]
    fields += s.get('provides', [])
    fields += [sub['name'] for sub in s.get('subSkills', [])]
    fields += [sub['description'] for sub in s.get('subSkills', [])]
    fields += [sub.get('command', '') for sub in s.get('subSkills', [])]
    return any(q in (f or '').lower() for f in fields)

skills = data['skills']
if query:
    skills = [s for s in skills if matches(s, query)]
skills = skills[:limit]

if is_json:
    out = [{'name': s['name'], 'command': s.get('triggerCommand', '/' + s['name']),
            'description': s.get('description', ''), 'scope': s.get('scope', ''),
            'editor': s.get('editor', '')} for s in skills]
    print(json.dumps(out, indent=2))
else:
    B, D, N = '\033[1m', '\033[2m', '\033[0m'
    CYN, GRY = '\033[38;5;116m', '\033[38;5;245m'
    for s in skills:
        cmd = s.get('triggerCommand', '/' + s['name'])
        desc = s.get('description', '')[:80]
        print(f'  {CYN}{cmd:<35}{N} {D}{desc}{N}')
PYEOF_SEARCH
        else
            # Interactive TUI with pre-filled search
            ensure_index
            build_trust_cache
            detect_editors
            fetch_all_remote 2>/dev/null
            py_interactive search "$query"
        fi
        ;;
    info)
        # Alias for show
        shift  # remove 'info'
        ensure_index
        build_trust_cache
        detect_editors
        py_interactive show "$@"
        ;;
    add)
        # Alias for install --local
        shift  # remove 'add'
        name="${1:-}"
        if [ -z "$name" ]; then
            echo -e "${RED}Usage: sb add <name>${NC}" >&2
            exit 1
        fi
        # Re-invoke as install --local
        exec "$0" install "$name" --local
        ;;
    remove)
        # Remove an installed skill
        shift  # remove 'remove'
        name=""
        scope_flag=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --local) scope_flag="local"; shift ;;
                --global) scope_flag="global"; shift ;;
                *) name="$1"; shift ;;
            esac
        done
        if [ -z "$name" ]; then
            echo -e "${RED}Usage: sb remove <name> [--local|--global]${NC}" >&2
            exit 1
        fi

        # Try skills CLI first (for Agent Hub tracking)
        if command -v skills >/dev/null 2>&1; then
            skills_args=("$name")
            [ -n "$scope_flag" ] && skills_args+=("--${scope_flag}")
            if skills remove "${skills_args[@]}" 2>/dev/null; then
                echo -e "${GREEN}Removed: ${name} (via skills CLI)${NC}"
                # Regenerate index
                ensure_index
                detect_editors
                export SB_EDITORS_FILE="$SB_CACHE_DIR/editors.json"
                rm -f "$INDEX"
                bash "${SCRIPT_DIR}/generate-skill-index.sh" >/dev/null 2>&1
                exit 0
            fi
        fi

        # Manual removal: find the skill in the index
        ensure_index
        detect_editors
        SB_NAME="$name" SB_SCOPE="$scope_flag" SB_EDITORS_FILE="$SB_CACHE_DIR/editors.json" python3 << 'PYEOF_REMOVE'
import json, os, sys, shutil

name = os.environ.get('SB_NAME', '').lower().lstrip('/')
scope_flag = os.environ.get('SB_SCOPE', '')
cache_dir = os.environ.get('SB_CACHE_DIR', os.path.join(os.path.expanduser('~'), '.cache', 'skill-browser'))
index_path = os.path.join(cache_dir, 'skill-index.json')

with open(index_path) as f:
    data = json.load(f)

# Find matching skills
matches = [s for s in data['skills'] if s['name'].lower() == name or s.get('id', '').lower() == name]
if not matches:
    print(f'\033[38;5;203m"{name}" not found in installed skills\033[0m', file=sys.stderr)
    sys.exit(1)

# Filter by scope if specified
if scope_flag:
    scoped = [s for s in matches if s.get('scope') in (scope_flag, 'both')]
    if not scoped:
        print(f'\033[38;5;203m"{name}" not found in {scope_flag} scope\033[0m', file=sys.stderr)
        sys.exit(1)
    matches = scoped

removed = []
for s in matches:
    skill_path = s.get('skillPath', '')
    if not skill_path or not os.path.exists(skill_path):
        continue
    # Remove the directory containing SKILL.md
    skill_dir = os.path.dirname(skill_path)
    if os.path.isdir(skill_dir) and os.path.basename(skill_dir).lower() != 'skills':
        shutil.rmtree(skill_dir)
        removed.append(f'{s.get("editor", "?")}:{s.get("scope", "?")} ({skill_dir})')

if removed:
    for r in removed:
        print(f'\033[38;5;78mRemoved: {name} from {r}\033[0m')
else:
    print(f'\033[38;5;203mCould not locate files for "{name}"\033[0m', file=sys.stderr)
    sys.exit(1)
PYEOF_REMOVE
        # Regenerate index
        export SB_EDITORS_FILE="$SB_CACHE_DIR/editors.json"
        rm -f "$INDEX"
        bash "${SCRIPT_DIR}/generate-skill-index.sh" >/dev/null 2>&1
        ;;
    update)
        # Update skills from source
        shift  # remove 'update'
        name=""
        scope_flag=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --local) scope_flag="--local"; shift ;;
                --global) scope_flag="--global"; shift ;;
                *) name="$1"; shift ;;
            esac
        done

        if command -v skills >/dev/null 2>&1; then
            skills_args=()
            [ -n "$name" ] && skills_args+=("$name")
            [ -n "$scope_flag" ] && skills_args+=("$scope_flag")
            echo -e "${DIM}Updating via skills CLI...${NC}" >&2
            skills update "${skills_args[@]}" 2>&1
            echo -e "${GREEN}Update complete.${NC}"
        else
            echo -e "${ORANGE}No skills CLI found. Manual update:${NC}" >&2
            if [ -n "$name" ]; then
                echo -e "${DIM}Re-install the skill: sb install ${name}${NC}"
            else
                echo -e "${DIM}Install the skills CLI: npm install -g @shopify/skills${NC}"
                echo -e "${DIM}Or re-install individual skills: sb install <name>${NC}"
            fi
        fi
        # Regenerate index
        ensure_index
        detect_editors
        export SB_EDITORS_FILE="$SB_CACHE_DIR/editors.json"
        rm -f "$INDEX"
        bash "${SCRIPT_DIR}/generate-skill-index.sh" >/dev/null 2>&1
        ;;
    validate)
        # Validate skill(s)
        shift  # remove 'validate'
        target="${1:-}"
        python3 - "$target" << 'PYEOF_VALIDATE'
import sys, os, re, glob as _glob

target = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else ''

B, N = '\033[1m', '\033[0m'
GRN, RED, GRY, ORA = '\033[38;5;78m', '\033[38;5;203m', '\033[38;5;245m', '\033[38;5;214m'

def validate_skill(path):
    """Validate a skill directory. Returns (name, passed, reason)."""
    name = os.path.basename(path.rstrip('/'))
    skill_md = os.path.join(path, 'SKILL.md')

    if not os.path.isfile(skill_md):
        return name, False, 'SKILL.md not found'

    with open(skill_md) as f:
        content = f.read()

    # Check frontmatter
    parts = content.split('---', 2)
    if len(parts) < 3:
        return name, False, 'No YAML frontmatter (missing --- delimiters)'

    fm = parts[1].strip()
    if not fm:
        return name, False, 'Empty frontmatter'

    # Check name field
    name_match = re.search(r'^name:\s*(.+)$', fm, re.MULTILINE)
    if not name_match:
        return name, False, "Missing required field 'name'"

    # Check description field
    desc_match = re.search(r'^description:\s*(.+)$', fm, re.MULTILINE)
    if not desc_match:
        return name, False, "Missing required field 'description'"

    desc_val = desc_match.group(1).strip().strip('"').strip("'")
    if not desc_val:
        return name, False, "Field 'description' is empty"

    return name, True, 'OK'

dirs = []
if target:
    # Validate specific path
    if os.path.isdir(target):
        dirs = [target]
    else:
        print(f'{RED}Path not found: {target}{N}', file=sys.stderr)
        sys.exit(1)
else:
    # Validate all installed skills from index
    cache_dir = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
    index_path = os.path.join(cache_dir, 'skill-index.json')
    if os.path.isfile(index_path):
        import json
        with open(index_path) as f:
            data = json.load(f)
        seen = set()
        for s in data['skills']:
            sp = s.get('skillPath', '')
            if sp:
                d = os.path.dirname(sp)
                if d not in seen and os.path.isdir(d):
                    seen.add(d)
                    dirs.append(d)
    if not dirs:
        # Fallback: scan common directories
        for d in [os.path.expanduser('~/.claude/skills'), '.claude/skills']:
            if os.path.isdir(d):
                for sub in sorted(os.listdir(d)):
                    full = os.path.join(d, sub)
                    if os.path.isdir(full):
                        dirs.append(full)

passed = 0
failed = 0
total = 0
for d in sorted(dirs):
    total += 1
    name, ok, reason = validate_skill(d)
    if ok:
        passed += 1
        print(f'  {GRN}\u2713{N} {name}')
    else:
        failed += 1
        print(f'  {RED}\u2717{N} {name}: {reason}')

print()
if failed == 0:
    print(f'{GRN}{passed}/{total} skills valid{N}')
else:
    print(f'{RED}{passed}/{total} valid ({failed} failed){N}')
    sys.exit(1)
PYEOF_VALIDATE
        ;;
    init)
        # Initialize .claude/skills/ directory
        if command -v skills >/dev/null 2>&1; then
            echo -e "${DIM}Initializing via skills CLI...${NC}" >&2
            skills init --local 2>&1
        fi
        # Ensure directories exist regardless
        if [ ! -d ".claude/skills" ]; then
            mkdir -p ".claude/skills"
            echo -e "${GREEN}Created .claude/skills/${NC}"
        else
            echo -e "${DIM}.claude/skills/ already exists${NC}"
        fi
        if [ ! -f ".claude/skills.json" ]; then
            echo '{"skills":[]}' > ".claude/skills.json"
            echo -e "${GREEN}Created .claude/skills.json${NC}"
        else
            echo -e "${DIM}.claude/skills.json already exists${NC}"
        fi
        ;;
    repos)
        echo -e "${BOLD}Skill Repos:${NC}"
        echo -e "  ${DIM}Built-in:${NC}"
        echo -e "  ${CYAN}anthropics/skills${NC}               Anthropic's official skills"
        echo -e "  ${CYAN}obra/superpowers${NC}                Community superpowers collection"
        echo -e "  ${CYAN}levnikolaevich/claude-code-skills${NC}  Community skills"
        echo ""
        echo -e "${BOLD}Plugin Repos:${NC}"
        echo -e "  ${DIM}Built-in:${NC}"
        echo -e "  ${CYAN}anthropics/claude-plugins-official${NC}  Official + external plugins"
        if [ -f "$CUSTOM_REPOS_FILE" ] && [ -s "$CUSTOM_REPOS_FILE" ]; then
            echo ""
            echo -e "  ${DIM}Custom skill repos:${NC}"
            while IFS= read -r line; do
                line="${line%%#*}"; line="${line// /}"
                [ -z "$line" ] && continue
                repo="${line%%:*}"
                echo -e "  ${GREEN}${repo}${NC}"
            done < "$CUSTOM_REPOS_FILE"
        fi
        if [ -f "$CUSTOM_PLUGIN_REPOS_FILE" ] && [ -s "$CUSTOM_PLUGIN_REPOS_FILE" ]; then
            echo ""
            echo -e "  ${DIM}Custom plugin repos:${NC}"
            while IFS= read -r line; do
                line="${line%%#*}"; line="${line// /}"
                [ -z "$line" ] && continue
                repo="${line%%:*}"
                echo -e "  ${GREEN}${repo}${NC}"
            done < "$CUSTOM_PLUGIN_REPOS_FILE"
        fi
        echo ""
        echo -e "${DIM}Add your own: sb add-repo owner/repo${NC}"
        ;;
    add-repo)
        shift
        repo=""
        plugins_dir=""
        skills_path=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --plugins)
                    plugins_dir="${2:-plugins}"
                    shift 2
                    ;;
                --path)
                    skills_path="${2:-}"
                    shift 2
                    ;;
                *)
                    repo="$1"
                    shift
                    ;;
            esac
        done
        if [ -z "$repo" ]; then
            echo -e "${RED}Usage: sb add-repo <owner/repo> [--path skills_subdir] [--plugins plugin_dir]${NC}" >&2
            exit 1
        fi
        # Validate format: must be owner/repo
        if [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
            echo -e "${RED}Invalid repo format. Expected: owner/repo (e.g. myuser/my-skills)${NC}" >&2
            exit 1
        fi
        if [ -n "$plugins_dir" ]; then
            # Add as plugin repo
            entry="${repo}:${plugins_dir}"
            if [ -f "$CUSTOM_PLUGIN_REPOS_FILE" ] && grep -qF "$repo" "$CUSTOM_PLUGIN_REPOS_FILE" 2>/dev/null; then
                echo -e "${ORANGE}${repo} already in custom plugin repos${NC}"
            else
                echo "$entry" >> "$CUSTOM_PLUGIN_REPOS_FILE"
                echo -e "${GREEN}Added plugin repo: ${repo} (dir: ${plugins_dir})${NC}"
            fi
        else
            # Add as skill repo
            entry="${repo}:${skills_path}"
            if [ -f "$CUSTOM_REPOS_FILE" ] && grep -qF "$repo" "$CUSTOM_REPOS_FILE" 2>/dev/null; then
                echo -e "${ORANGE}${repo} already in custom skill repos${NC}"
            else
                echo "$entry" >> "$CUSTOM_REPOS_FILE"
                echo -e "${GREEN}Added skill repo: ${repo}${NC}"
                if [ -n "$skills_path" ]; then
                    echo -e "${DIM}  Skills path: ${skills_path}${NC}"
                else
                    echo -e "${DIM}  Skills at repo root (use --path <dir> if skills are in a subdirectory)${NC}"
                fi
            fi
        fi
        echo -e "${DIM}Run 'sb fetch-remote' to pull skills from the new repo.${NC}"
        ;;
    remove-repo)
        shift
        repo="${1:-}"
        if [ -z "$repo" ]; then
            echo -e "${RED}Usage: sb remove-repo <owner/repo>${NC}" >&2
            exit 1
        fi
        removed=false
        for f in "$CUSTOM_REPOS_FILE" "$CUSTOM_PLUGIN_REPOS_FILE"; do
            if [ -f "$f" ] && grep -qF "$repo" "$f" 2>/dev/null; then
                grep -vF "$repo" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                removed=true
            fi
        done
        if [ "$removed" = true ]; then
            echo -e "${GREEN}Removed: ${repo}${NC}"
            # Clean cached data for this repo
            rm -f "$REMOTE_CACHE_DIR/${repo//\//--}.json" "$REMOTE_CACHE_DIR/${repo//\//--}--plugins.json" 2>/dev/null
            echo -e "${DIM}Cleared cached data. Run 'sb fetch-remote' to update.${NC}"
        else
            echo -e "${RED}${repo} not found in custom repos${NC}" >&2
            exit 1
        fi
        ;;
    show)
        ensure_index
        build_trust_cache
        detect_editors
        py_interactive "$@"
        ;;
    cats)
        ensure_index
        build_trust_cache
        detect_editors
        py_static "$@"
        ;;
    explore-list)
        # Non-interactive listing of remote skills/plugins (agent-friendly)
        fetch_all_remote 2>/dev/null
        shift  # remove 'explore-list'
        python3 - "$@" << 'PYEOF_EXPLORE_LIST'
import json, sys, os, glob

SB_CACHE_DIR = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
REMOTE_CACHE_DIR = os.path.join(SB_CACHE_DIR, 'remote-cache')

# Parse args
args = sys.argv[1:]
type_filter = 'all'
json_output = False
repo_filter = ''
query = ''
i = 0
while i < len(args):
    if args[i] == '--type' and i + 1 < len(args):
        type_filter = args[i + 1]
        i += 2
    elif args[i] == '--json':
        json_output = True
        i += 1
    elif args[i] == '--repo' and i + 1 < len(args):
        repo_filter = args[i + 1].lower()
        i += 2
    else:
        query = ' '.join(args[i:])
        break

# Load remote skills
remote = []
if os.path.isdir(REMOTE_CACHE_DIR):
    for f in sorted(glob.glob(os.path.join(REMOTE_CACHE_DIR, '*.json'))):
        try:
            with open(f) as fh:
                items = json.load(fh)
            if isinstance(items, list):
                remote.extend(items)
        except Exception:
            pass

# Apply filters
if type_filter == 'skills':
    remote = [s for s in remote if s.get('item_type') != 'plugin']
elif type_filter == 'plugins':
    remote = [s for s in remote if s.get('item_type') == 'plugin']

if repo_filter:
    remote = [s for s in remote if repo_filter in s.get('owner', '').lower() or repo_filter in s.get('repo', '').lower()]

if query:
    q = query.lower()
    remote = [s for s in remote if q in s.get('name', '').lower() or q in s.get('description', '').lower()]

remote.sort(key=lambda s: (s.get('item_type', 'skill'), s.get('owner', ''), s['name']))

if json_output:
    all_editors = ['claude', 'codex', 'cursor', 'opencode', 'pi']
    # Try to load detected editors from cache
    _editors_file = os.path.join(SB_CACHE_DIR, 'editors.json')
    if os.path.isfile(_editors_file):
        try:
            with open(_editors_file) as _ef:
                _ed = json.load(_ef)
            all_editors = [e['name'] for e in _ed if e.get('found')]
            if not all_editors:
                all_editors = ['claude']
        except Exception:
            pass
    out = []
    for s in remote:
        itype = s.get('item_type', 'skill')
        if itype == 'plugin':
            compat = ['claude']
        else:
            compat = all_editors[:]
        out.append({
            'name': s['name'],
            'type': itype,
            'repo': s.get('repo', ''),
            'owner': s.get('owner', ''),
            'description': s.get('description', ''),
            'url': s.get('remote_url', ''),
            'installed': s.get('installed', False),
            'compatible_editors': compat,
        })
    print(json.dumps(out, indent=2))
else:
    B, D, N = '\033[1m', '\033[2m', '\033[0m'
    CYN, GRY, YEL, GRN, ORA = '\033[38;5;116m', '\033[38;5;245m', '\033[38;5;228m', '\033[38;5;78m', '\033[38;5;214m'
    BLU = '\033[38;5;75m'

    total = len(remote)
    label = f'{total} items'
    if type_filter != 'all':
        label = f'{total} {type_filter}'
    if query:
        label += f' matching "{query}"'
    print(f'{B}Explore{N}  {BLU}{label}{N}')
    print()

    try: cols = os.get_terminal_size().columns
    except: cols = 120
    NAME_W = 30
    TYPE_W = 8
    REPO_W = 14
    DESC_W = max(cols - NAME_W - TYPE_W - REPO_W - 8, 15)

    print(f'  {D}{GRY}{"Name":<{NAME_W}} {"Type":<{TYPE_W}} {"Repo":<{REPO_W}} {"Description"}{N}')
    for s in remote:
        name = s.get('triggerCommand', s['name'])
        itype = s.get('item_type', 'skill')
        tc = YEL if itype == 'plugin' else BLU
        repo = s.get('owner', '?')
        if s.get('repo') == 'agent-hub':
            repo = 'hub'
        desc = s.get('description', '')
        if len(desc) > DESC_W:
            desc = desc[:DESC_W - 1] + '\u2026'
        installed = f' {GRN}\u2713{N}' if s.get('installed') else ''
        print(f'  {CYN}{name:<{NAME_W}}{N} {tc}{itype:<{TYPE_W}}{N} {ORA}{repo:<{REPO_W}}{N} {D}{desc}{N}{installed}')
PYEOF_EXPLORE_LIST
        ;;
    remote-show)
        # Non-interactive detail view for a remote skill/plugin
        fetch_all_remote 2>/dev/null
        shift  # remove 'remote-show'
        python3 - "$@" << 'PYEOF_REMOTE_SHOW'
import json, sys, os, glob, subprocess, base64

SB_CACHE_DIR = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
REMOTE_CACHE_DIR = os.path.join(SB_CACHE_DIR, 'remote-cache')

B, D, N = '\033[1m', '\033[2m', '\033[0m'
CYN, GRY, YEL, GRN, ORA, RED = '\033[38;5;116m', '\033[38;5;245m', '\033[38;5;228m', '\033[38;5;78m', '\033[38;5;214m', '\033[38;5;203m'
BLU = '\033[38;5;75m'

query = ' '.join(sys.argv[1:]).strip()
if not query:
    print(f'{RED}Usage: sb remote-show <name>{N}')
    sys.exit(1)

# Load all remote items
remote = []
if os.path.isdir(REMOTE_CACHE_DIR):
    for f in sorted(glob.glob(os.path.join(REMOTE_CACHE_DIR, '*.json'))):
        try:
            with open(f) as fh:
                items = json.load(fh)
            if isinstance(items, list):
                remote.extend(items)
        except Exception:
            pass

q = query.lower().lstrip('/')
match = next((s for s in remote if s['name'].lower() == q), None)
if not match:
    candidates = [s for s in remote if q in s['name'].lower()]
    if len(candidates) == 1:
        match = candidates[0]
    elif candidates:
        print(f'{ORA}Multiple matches:{N}')
        for c in candidates:
            itype = c.get('item_type', 'skill')
            tc = YEL if itype == 'plugin' else BLU
            print(f'  {CYN}{c["name"]}{N}  {tc}{itype}{N}  {D}{c.get("description","")[:60]}{N}')
        sys.exit(0)
    else:
        print(f'{RED}"{query}" not found in remote cache. Run: sb fetch-remote{N}')
        sys.exit(1)

is_plugin = match.get('item_type') == 'plugin'
type_label = f'{YEL}plugin{N}' if is_plugin else f'{BLU}skill{N}'
print(f'  {B}{CYN}{match.get("triggerCommand", match["name"])}{N}')
print(f'  {type_label}  {GRY}{match.get("repo", "?")}{N}')
if match.get('author'):
    print(f'  {D}by {match["author"]}{N}')
print()
print(f'  {match.get("description", "No description")}')
print()
if match.get('remote_url'):
    print(f'  {D}{match["remote_url"]}{N}')

# Try to fetch and show full content
if match.get('repo') and match.get('remote_path'):
    candidates = ['README.md', 'SKILL.md'] if is_plugin else ['SKILL.md', 'README.md']
    for doc in candidates:
        # Check disk cache first
        import re as _re
        _sanitize = lambda p: _re.sub(r'[^a-zA-Z0-9._-]', '_', p)
        cache_key = f'{_sanitize(match.get("owner", "x"))}--{_sanitize(match["name"])}--{doc}'
        cache_path = os.path.join(REMOTE_CACHE_DIR, cache_key)
        content = None
        if os.path.isfile(cache_path):
            try:
                import time
                if time.time() - os.path.getmtime(cache_path) < 86400:
                    with open(cache_path) as f:
                        content = f.read()
            except Exception:
                pass
        if not content:
            try:
                api_path = f'repos/{match["repo"]}/contents/{match["remote_path"]}/{doc}'
                r = subprocess.run(['gh', 'api', api_path], capture_output=True, text=True, timeout=15)
                if r.returncode == 0:
                    data = json.loads(r.stdout)
                    if data.get('content'):
                        content = base64.b64decode(data['content']).decode('utf-8', errors='ignore')
                        try:
                            os.makedirs(REMOTE_CACHE_DIR, exist_ok=True)
                            with open(cache_path, 'w') as f:
                                f.write(content)
                        except Exception:
                            pass
            except Exception:
                pass
        if content:
            print()
            # Strip frontmatter
            parts = content.split('---', 2)
            body = parts[2].strip() if len(parts) >= 3 else content.strip()
            print(body)
            break
PYEOF_REMOTE_SHOW
        ;;
    install)
        # Non-interactive install (agent-friendly)
        shift  # remove 'install'
        target_editor=""
        scope_flag=""
        name=""
        no_deps=false
        while [ $# -gt 0 ]; do
            case "$1" in
                --editor)
                    target_editor="${2:-}"
                    shift 2
                    ;;
                --local)
                    scope_flag="--local"
                    shift
                    ;;
                --global)
                    scope_flag="--global"
                    shift
                    ;;
                --no-deps)
                    no_deps=true
                    shift
                    ;;
                *)
                    name="$1"
                    shift
                    ;;
            esac
        done
        if [ -z "$name" ]; then
            echo -e "${RED}Usage: sb install <name> [--editor <e>] [--local|--global] [--no-deps]${NC}" >&2
            exit 1
        fi

        # Dependency resolution (unless --no-deps or already in-progress)
        if [ "$no_deps" = false ] && [ -z "${SB_INSTALLING_DEPS:-}" ]; then
            ensure_index
            # Check if this skill has required skills
            deps=$(SB_NAME="$name" python3 -c "
import json, os, sys
cache_dir = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
index_path = os.path.join(cache_dir, 'skill-index.json')
name = os.environ.get('SB_NAME', '').lower().lstrip('/')
# Check local index
try:
    with open(index_path) as f:
        data = json.load(f)
    installed_ids = {s['name'].lower() for s in data['skills']} | {s['id'].lower() for s in data['skills']}
    # Find the skill in remote cache to get its deps
    remote_dir = os.path.join(cache_dir, 'remote-cache')
    import glob
    for f in glob.glob(os.path.join(remote_dir, '*.json')):
        try:
            items = json.load(open(f))
            for s in items:
                if s['name'].lower() == name:
                    deps = s.get('requires', {}).get('skills', [])
                    missing = [d for d in deps if d.lower() not in installed_ids]
                    if missing:
                        print(' '.join(missing))
                    sys.exit(0)
        except: pass
    # Also check local index
    for s in data['skills']:
        if s['name'].lower() == name or s['id'].lower() == name:
            deps = s.get('requires', {}).get('skills', [])
            missing = [d for d in deps if d.lower() not in installed_ids]
            if missing:
                print(' '.join(missing))
            break
except Exception:
    pass
" 2>/dev/null)
            if [ -n "$deps" ]; then
                echo -e "${DIM}Installing dependencies: ${deps}${NC}" >&2
                export SB_INSTALLING_DEPS=1
                for dep in $deps; do
                    echo -e "${DIM}  Installing dependency: ${dep}${NC}" >&2
                    "$0" install "$dep" --local 2>&1 | sed 's/^/    /'
                done
                unset SB_INSTALLING_DEPS
            fi
        fi

        # Detect editors
        detect_editors

        # Determine target editors
        if [ -z "$target_editor" ] || [ "$target_editor" = "claude" ]; then
            # Default: try skills CLI for Claude Code
            if command -v skills >/dev/null 2>&1; then
                skills_scope="${scope_flag:---local}"
                echo -e "${DIM}Installing ${name} via skills CLI...${NC}" >&2
                if skills get "$name" "$skills_scope" 2>&1; then
                    echo -e "${GREEN}Installed: ${name} (claude, ${skills_scope#--})${NC}"
                    [ -z "$target_editor" ] && exit 0
                fi
            fi
        fi

        # For non-claude or --editor all, fetch SKILL.md and copy
        if [ "$target_editor" = "all" ] || { [ -n "$target_editor" ] && [ "$target_editor" != "claude" ]; }; then
            fetch_all_remote 2>/dev/null
            SB_NAME="$name" SB_TARGET_EDITOR="$target_editor" SB_EDITORS_FILE="$SB_CACHE_DIR/editors.json" python3 << 'PYEOF_INSTALL' 2>/dev/null
import json, os, glob, subprocess, base64, sys

name = os.environ.get('SB_NAME', '').lower()
target = os.environ.get('SB_TARGET_EDITOR', '')
editors_file = os.environ.get('SB_EDITORS_FILE', '')
cache_dir = os.path.join(os.environ.get('SB_CACHE_DIR', os.path.join(os.path.expanduser('~'), '.cache', 'skill-browser')), 'remote-cache')

# Load editors
editors = []
try:
    with open(editors_file) as f:
        editors = json.load(f)
except Exception:
    pass

if target == 'all':
    targets = [e for e in editors if e.get('found')]
else:
    targets = [e for e in editors if e['name'] == target and e.get('found')]

if not targets:
    print(f'No matching editor found: {target}', file=sys.stderr)
    sys.exit(1)

# Find SKILL.md content from remote cache
content = None
for f in sorted(glob.glob(os.path.join(cache_dir, '*.json'))):
    try:
        items = json.load(open(f))
        for s in items:
            if s['name'].lower() == name and s.get('repo') and s.get('remote_path'):
                # Fetch SKILL.md via gh api
                api_path = f'repos/{s["repo"]}/contents/{s["remote_path"]}/SKILL.md'
                r = subprocess.run(['gh', 'api', api_path], capture_output=True, text=True, timeout=15)
                if r.returncode == 0:
                    data = json.loads(r.stdout)
                    if data.get('content'):
                        content = base64.b64decode(data['content']).decode('utf-8', errors='ignore')
                        break
    except Exception:
        pass
    if content:
        break

if not content:
    print(f'Could not fetch SKILL.md for {name}', file=sys.stderr)
    sys.exit(1)

installed = []
for editor in targets:
    if editor['name'] == 'claude':
        continue  # Already handled above
    target_dir = os.path.join(editor['global'], name)
    os.makedirs(target_dir, exist_ok=True)
    with open(os.path.join(target_dir, 'SKILL.md'), 'w') as f:
        f.write(content)
    installed.append(editor['name'])
    print(f'Installed {name} to {editor["name"]} ({target_dir})', file=sys.stderr)

if installed:
    print(f'Installed to: {", ".join(installed)}')
PYEOF_INSTALL
            echo -e "${GREEN}Done.${NC}"
            exit 0
        fi

        # Fallback: try claude plugin install
        if command -v claude >/dev/null 2>&1; then
            echo -e "${DIM}Trying claude plugin add...${NC}" >&2
            fetch_all_remote 2>/dev/null
            plugin_url=$(SB_NAME="$name" python3 -c "
import json, glob, os
target = os.environ.get('SB_NAME', '').lower()
for f in glob.glob(os.path.join(os.environ.get('SB_CACHE_DIR', os.path.join(os.path.expanduser('~'), '.cache', 'skill-browser')), 'remote-cache', '*.json')):
    try:
        items = json.load(open(f))
        for s in items:
            if s['name'].lower() == target and s.get('item_type') == 'plugin':
                print(s.get('remote_url', ''))
                exit()
    except: pass
" 2>/dev/null)
            if [ -n "$plugin_url" ]; then
                echo -e "${DIM}Found plugin: ${plugin_url}${NC}" >&2
                echo -e "${ORANGE}Plugin install requires: claude plugin add <url>${NC}"
                echo -e "  ${CYAN}${plugin_url}${NC}"
                exit 0
            fi
        fi
        echo -e "${RED}Could not install '${name}'. Not found in Agent Hub or plugin repos.${NC}" >&2
        exit 1
        ;;
    explore)
        ensure_index
        build_trust_cache
        detect_editors
        fetch_all_remote 2>/dev/null
        py_interactive "$@"
        ;;
    stale)
        # List skills older than N days
        ensure_index
        shift  # remove 'stale'
        python3 - "$@" << 'PYEOF_STALE'
import json, sys, os, time

SB_CACHE_DIR = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
INDEX = os.path.join(SB_CACHE_DIR, 'skill-index.json')

with open(INDEX) as f:
    data = json.load(f)

args = sys.argv[1:]
days = 30
json_output = False
i = 0
while i < len(args):
    if args[i] == '--days' and i + 1 < len(args):
        days = int(args[i + 1])
        i += 2
    elif args[i] == '--json':
        json_output = True
        i += 1
    else:
        i += 1

now = time.time()
threshold = days * 86400
stale = []
for s in data['skills']:
    lm = s.get('lastModified', 0)
    if lm <= 0:
        continue
    age = now - lm
    if age > threshold:
        s['_age_days'] = int(age / 86400)
        stale.append(s)

stale.sort(key=lambda s: s['_age_days'], reverse=True)

if json_output:
    out = [{'name': s['name'], 'command': s.get('triggerCommand', '/' + s['name']),
            'scope': s.get('scope', ''), 'age_days': s['_age_days'],
            'lastModified': s.get('lastModified', 0),
            'skillPath': s.get('skillPath', '')} for s in stale]
    print(json.dumps(out, indent=2))
else:
    B, D, N = '\033[1m', '\033[2m', '\033[0m'
    CYN, GRY, ORA, RED = '\033[38;5;116m', '\033[38;5;245m', '\033[38;5;214m', '\033[38;5;203m'
    print(f'{B}Stale Skills{N}  {ORA}older than {days} days{N}  ({len(stale)} found)')
    print()
    if not stale:
        print(f'  {D}No stale skills found.{N}')
    else:
        try: cols = os.get_terminal_size().columns
        except: cols = 120
        NAME_W = 35
        AGE_W = 8
        SCOPE_W = 10
        DESC_W = max(cols - NAME_W - AGE_W - SCOPE_W - 8, 15)
        print(f'  {D}{GRY}{"Command":<{NAME_W}} {"Age":<{AGE_W}} {"Scope":<{SCOPE_W}} {"Path"}{N}')
        for s in stale:
            cmd = s.get('triggerCommand', '/' + s['name'])
            age_d = s['_age_days']
            ac = RED if age_d > 90 else ORA
            scope = s.get('scope', '?')
            path = s.get('skillPath', '')
            if len(path) > DESC_W:
                path = '...' + path[-(DESC_W - 3):]
            print(f'  {CYN}{cmd:<{NAME_W}}{N} {ac}{age_d}d{N}{" " * max(0, AGE_W - len(str(age_d)) - 1)} {GRY}{scope:<{SCOPE_W}}{N} {D}{path}{N}')
PYEOF_STALE
        ;;
    why)
        # Diagnostic: show where a skill loads from
        ensure_index
        detect_editors
        shift  # remove 'why'
        SB_QUERY="${1:-}" SB_EDITORS_FILE="$SB_CACHE_DIR/editors.json" python3 << 'PYEOF_WHY'
import json, os, sys

B, D, N = '\033[1m', '\033[2m', '\033[0m'
CYN, GRY, GRN, RED, ORA, PUR = '\033[38;5;116m', '\033[38;5;245m', '\033[38;5;78m', '\033[38;5;203m', '\033[38;5;214m', '\033[38;5;141m'

query = os.environ.get('SB_QUERY', '').strip().lstrip('/')
if not query:
    print(f'{RED}Usage: sb why <name>{N}')
    sys.exit(1)

cache_dir = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
index_path = os.path.join(cache_dir, 'skill-index.json')
editors_file = os.environ.get('SB_EDITORS_FILE', os.path.join(cache_dir, 'editors.json'))

# Load index
skills = []
try:
    with open(index_path) as f:
        skills = json.load(f).get('skills', [])
except Exception:
    pass

# Load editors
editors = []
try:
    with open(editors_file) as f:
        editors = json.load(f)
except Exception:
    pass

# Exact match first, then fuzzy
match = next((s for s in skills if s['id'].lower() == query.lower() or s['name'].lower() == query.lower()), None)
if not match:
    candidates = [s for s in skills if query.lower() in s['id'].lower() or query.lower() in s['name'].lower()]
    if len(candidates) == 1:
        match = candidates[0]

if match:
    print(f'{B}Found:{N} {CYN}{match.get("triggerCommand", "/" + match["name"])}{N}')
    print()
    skill_path = match.get('skillPath', '')
    print(f'  {B}Skill path:{N}  {skill_path}')

    # Resolve symlink chain
    if skill_path and os.path.exists(skill_path):
        path = skill_path
        chain = [path]
        while os.path.islink(path):
            target = os.readlink(path)
            if not os.path.isabs(target):
                target = os.path.join(os.path.dirname(path), target)
            target = os.path.normpath(target)
            chain.append(target)
            path = target
            if len(chain) > 10:
                break
        if len(chain) > 1:
            print(f'  {B}Symlink chain:{N}')
            for i, p in enumerate(chain):
                pfx = '  \u2514 ' if i == len(chain) - 1 else '  \u251c '
                exists = f'{GRN}\u2713{N}' if os.path.exists(p) else f'{RED}\u2717{N}'
                print(f'    {pfx}{exists} {p}')
        else:
            exists = f'{GRN}exists{N}' if os.path.exists(path) else f'{RED}missing{N}'
            print(f'  {B}File:{N}        {exists} (not a symlink)')
    elif skill_path:
        print(f'  {B}File:{N}        {RED}missing{N}')

    scope = match.get('scope', '?')
    eds = match.get('editors', [match.get('editor', 'claude')])
    print(f'  {B}Scope:{N}       {scope}')
    print(f'  {B}Editors:{N}     {", ".join(eds)}')
    print(f'  {B}In index:{N}    {GRN}yes{N}')

    # Last modified
    import time
    lm = match.get('lastModified', 0)
    if lm > 0:
        age_days = int((time.time() - lm) / 86400)
        lm_str = time.strftime('%Y-%m-%d %H:%M', time.localtime(lm))
        print(f'  {B}Modified:{N}    {lm_str} ({age_days}d ago)')

    # Dependencies
    dep_skills = match.get('requires', {}).get('skills', [])
    if dep_skills:
        local_ids = {s['id'].lower() for s in skills} | {s['name'].lower() for s in skills}
        print(f'  {B}Deps:{N}')
        for dep in dep_skills:
            installed = dep.lower() in local_ids
            indicator = f'{GRN}\u2713{N}' if installed else f'{RED}\u2717 missing{N}'
            print(f'    {indicator} {dep}')

else:
    print(f'{ORA}"{query}" not found in index.{N}')
    print()

    # Show all scanned directories
    print(f'{B}Scanned directories:{N}')
    for e in editors:
        found = e.get('found', False)
        status = f'{GRN}\u2713{N}' if found else f'{RED}\u2717{N}'
        print(f'  {status} {B}{e["name"]}{N}')
        gdir = e.get('global', '')
        if os.path.isdir(gdir):
            print(f'    global: {GRN}{gdir}{N}')
        else:
            print(f'    global: {D}{gdir} (not found){N}')
        ldir = e.get('local', '')
        if ldir:
            full_local = os.path.join(os.getcwd(), ldir)
            if os.path.isdir(full_local):
                print(f'    local:  {GRN}{full_local}{N}')
            else:
                print(f'    local:  {D}{full_local} (not found){N}')

    # Partial matches
    partial = [s for s in skills if query.lower() in s['id'].lower() or query.lower() in s['name'].lower()]
    if partial:
        print()
        print(f'{B}Partial matches:{N}')
        for s in partial[:10]:
            print(f'  {CYN}{s.get("triggerCommand", "/" + s["name"])}{N}  {D}{s.get("description", "")[:60]}{N}')
PYEOF_WHY
        ;;
    diff)
        # Compare local vs global vs remote
        ensure_index
        detect_editors
        shift  # remove 'diff'
        python3 - "$@" << 'PYEOF_DIFF'
import json, sys, os, glob as _glob

SB_CACHE_DIR = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
INDEX = os.path.join(SB_CACHE_DIR, 'skill-index.json')
REMOTE_CACHE_DIR = os.path.join(SB_CACHE_DIR, 'remote-cache')

with open(INDEX) as f:
    data = json.load(f)

args = sys.argv[1:]
json_output = '--json' in args

# Partition installed skills
local_set = set()
global_set = set()
all_installed = set()
for s in data['skills']:
    name = s['name'].lower()
    all_installed.add(name)
    scope = s.get('scope', '')
    if scope in ('local', 'both'):
        local_set.add(name)
    if scope in ('global', 'both'):
        global_set.add(name)

# Load remote skills
remote_set = set()
if os.path.isdir(REMOTE_CACHE_DIR):
    for f in _glob.glob(os.path.join(REMOTE_CACHE_DIR, '*.json')):
        try:
            items = json.load(open(f))
            if isinstance(items, list):
                for item in items:
                    remote_set.add(item['name'].lower())
        except Exception:
            pass

local_only = local_set - global_set
global_only = global_set - local_set
both = local_set & global_set
remote_only = remote_set - all_installed

if json_output:
    print(json.dumps({
        'local_only': sorted(local_only),
        'global_only': sorted(global_only),
        'both': sorted(both),
        'remote_only': sorted(remote_only),
    }, indent=2))
else:
    B, D, N = '\033[1m', '\033[2m', '\033[0m'
    GRN, PUR, ORA, GRY, CYN, BLU = '\033[38;5;78m', '\033[38;5;141m', '\033[38;5;214m', '\033[38;5;245m', '\033[38;5;116m', '\033[38;5;75m'

    print(f'{B}Skill Diff{N}')
    print()

    if both:
        print(f'  {B}{ORA}Both local + global ({len(both)}):{N}')
        for n in sorted(both):
            print(f'    {CYN}/{n}{N}')
        print()

    if local_only:
        print(f'  {B}{GRN}Local only ({len(local_only)}):{N}')
        for n in sorted(local_only):
            print(f'    {CYN}/{n}{N}')
        print()

    if global_only:
        print(f'  {B}{PUR}Global only ({len(global_only)}):{N}')
        for n in sorted(global_only):
            print(f'    {CYN}/{n}{N}')
        print()

    if remote_only:
        print(f'  {B}{BLU}Remote only / not installed ({len(remote_only)}):{N}')
        for n in sorted(list(remote_only)[:20]):
            print(f'    {D}/{n}{N}')
        if len(remote_only) > 20:
            print(f'    {D}... and {len(remote_only) - 20} more{N}')
        print()

    total = len(all_installed)
    print(f'  {D}Installed: {total} total  |  {len(local_set)} local  |  {len(global_set)} global  |  {len(remote_only)} available remotely{N}')
PYEOF_DIFF
        ;;
    run)
        # Invoke a skill via its editor CLI
        ensure_index
        shift  # remove 'run'
        name="${1:-}"
        if [ -z "$name" ]; then
            echo -e "${RED}Usage: sb run <name> [args...]${NC}" >&2
            exit 1
        fi
        shift  # remove name
        run_args="$*"
        name="${name#/}"  # strip leading /

        SB_NAME="$name" SB_ARGS="$run_args" python3 << 'PYEOF_RUN'
import json, os, sys

cache_dir = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
index_path = os.path.join(cache_dir, 'skill-index.json')
editors_file = os.path.join(cache_dir, 'editors.json')

B, D, N = '\033[1m', '\033[2m', '\033[0m'
CYN, GRY, RED, GRN = '\033[38;5;116m', '\033[38;5;245m', '\033[38;5;203m', '\033[38;5;78m'

name = os.environ.get('SB_NAME', '')
args = os.environ.get('SB_ARGS', '')

with open(index_path) as f:
    skills = json.load(f).get('skills', [])

# Exact match first, then fuzzy
match = next((s for s in skills if s['id'].lower() == name.lower() or s['name'].lower() == name.lower()), None)
if not match:
    candidates = [s for s in skills if name.lower() in s['id'].lower() or name.lower() in s['name'].lower()]
    if len(candidates) == 1:
        match = candidates[0]
    elif candidates:
        print(f'{RED}Multiple matches:{N}')
        for c in candidates:
            print(f'  {CYN}{c.get("triggerCommand", "/" + c["name"])}{N}')
        sys.exit(1)
    else:
        print(f'{RED}Skill "{name}" not found{N}')
        sys.exit(1)

# Determine primary editor
editors_list = match.get('editors', [match.get('editor', 'claude')])
primary = editors_list[0] if editors_list else 'claude'

skill_cmd = match.get('triggerCommand', '/' + match['name'])
if args:
    prompt = f'{skill_cmd} {args}'
else:
    prompt = skill_cmd

import shutil
if primary == 'claude':
    claude_bin = shutil.which('claude')
    if claude_bin:
        print(f'{D}Running: claude -p "{prompt}"{N}', file=sys.stderr)
        os.execvp(claude_bin, ['claude', '-p', prompt])
    else:
        print(f'{RED}claude binary not found. Run manually:{N}')
        print(f'  claude -p "{prompt}"')
elif primary == 'codex':
    codex_bin = shutil.which('codex')
    if codex_bin:
        print(f'{D}Running: codex "{prompt}"{N}', file=sys.stderr)
        os.execvp(codex_bin, ['codex', prompt])
    else:
        print(f'{RED}codex binary not found. Run manually:{N}')
        print(f'  codex "{prompt}"')
elif primary == 'cursor':
    cursor_bin = shutil.which('cursor')
    if cursor_bin:
        print(f'{D}Running: cursor --chat "{prompt}"{N}', file=sys.stderr)
        os.execvp(cursor_bin, ['cursor', '--chat', prompt])
    else:
        print(f'{RED}cursor binary not found. Run manually:{N}')
        print(f'  cursor --chat "{prompt}"')
else:
    print(f'{D}Editor: {primary}{N}')
    print(f'{D}Command: {prompt}{N}')
    print(f'{RED}No known invocation for {primary}. Run the skill manually.{N}')
PYEOF_RUN
        ;;
    export)
        # Export installed skills manifest
        ensure_index
        shift  # remove 'export'
        output_file="skills-manifest.json"
        for arg in "$@"; do
            case "$arg" in
                --file) : ;;
                *) [ "$prev_arg" = "--file" ] && output_file="$arg" ;;
            esac
            prev_arg="$arg"
        done
        SB_OUTPUT="$output_file" python3 << 'PYEOF_EXPORT'
import json, os, sys

cache_dir = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
index_path = os.path.join(cache_dir, 'skill-index.json')
output_file = os.environ.get('SB_OUTPUT', 'skills-manifest.json')

B, D, N = '\033[1m', '\033[2m', '\033[0m'
GRN, GRY, CYN = '\033[38;5;78m', '\033[38;5;245m', '\033[38;5;116m'

with open(index_path) as f:
    data = json.load(f)

manifest = {
    'version': 1,
    'generatedAt': data.get('generatedAt', ''),
    'skills': []
}

for s in data['skills']:
    entry = {
        'name': s['name'],
        'scope': s.get('scope', 'unknown'),
        'editors': s.get('editors', [s.get('editor', 'claude')]),
    }
    if s.get('plugin'):
        entry['plugin'] = s['plugin']
        entry['marketplace'] = s.get('marketplace', '')
    manifest['skills'].append(entry)

manifest['skills'].sort(key=lambda s: s['name'])

with open(output_file, 'w') as f:
    json.dump(manifest, f, indent=2)

print(f'{GRN}Exported {len(manifest["skills"])} skills to {CYN}{output_file}{N}')
PYEOF_EXPORT
        ;;
    import)
        # Import skills from manifest
        shift  # remove 'import'
        input_file="skills-manifest.json"
        dry_run=false
        prev_arg=""
        for arg in "$@"; do
            case "$arg" in
                --dry-run) dry_run=true ;;
                --file) : ;;
                *) [ "$prev_arg" = "--file" ] && input_file="$arg" ;;
            esac
            prev_arg="$arg"
        done
        if [ ! -f "$input_file" ]; then
            echo -e "${RED}Manifest not found: ${input_file}${NC}" >&2
            exit 1
        fi
        ensure_index
        detect_editors
        SB_INPUT="$input_file" SB_DRY_RUN="$dry_run" SB_SCRIPT="$0" SB_EDITORS_FILE="$SB_CACHE_DIR/editors.json" python3 << 'PYEOF_IMPORT'
import json, os, sys, subprocess

cache_dir = os.environ.get('SB_CACHE_DIR', os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.join(os.path.expanduser('~'), '.cache')), 'skill-browser'))
index_path = os.path.join(cache_dir, 'skill-index.json')
input_file = os.environ.get('SB_INPUT', 'skills-manifest.json')
dry_run = os.environ.get('SB_DRY_RUN', 'false') == 'true'
script_path = os.environ.get('SB_SCRIPT', '')

B, D, N = '\033[1m', '\033[2m', '\033[0m'
GRN, GRY, CYN, RED, ORA = '\033[38;5;78m', '\033[38;5;245m', '\033[38;5;116m', '\033[38;5;203m', '\033[38;5;214m'

with open(input_file) as f:
    manifest = json.load(f)

with open(index_path) as f:
    data = json.load(f)

installed_ids = {s['name'].lower() for s in data['skills']}
installed_ids.update(s['id'].lower() for s in data['skills'])

manifest_skills = manifest.get('skills', [])
missing = [s for s in manifest_skills if s['name'].lower() not in installed_ids]
already = len(manifest_skills) - len(missing)

print(f'{B}Import from {CYN}{input_file}{N}')
print(f'  {D}{len(manifest_skills)} in manifest, {already} already installed, {len(missing)} to install{N}')
print()

if not missing:
    print(f'{GRN}All skills already installed.{N}')
    sys.exit(0)

for s in missing:
    scope = s.get('scope', 'local')
    scope_flag = '--local' if scope in ('local', 'both') else '--global'
    if dry_run:
        print(f'  {D}[dry-run]{N} Would install: {CYN}{s["name"]}{N} ({scope_flag})')
    else:
        print(f'  Installing: {CYN}{s["name"]}{N} ({scope_flag})...', end=' ', flush=True)
        try:
            r = subprocess.run(
                ['bash', script_path, 'install', s['name'], scope_flag],
                capture_output=True, text=True, timeout=60
            )
            if r.returncode == 0:
                print(f'{GRN}OK{N}')
            else:
                print(f'{RED}FAILED{N}')
                if r.stderr.strip():
                    print(f'    {D}{r.stderr.strip()[:100]}{N}')
        except Exception as e:
            print(f'{RED}ERROR: {e}{N}')

if dry_run:
    print()
    print(f'{ORA}Dry run complete. Run without --dry-run to install.{N}')
else:
    print()
    print(f'{GRN}Import complete.{N}')
PYEOF_IMPORT
        ;;
    *)
        ensure_index
        build_trust_cache
        detect_editors
        fetch_all_remote 2>/dev/null
        py_interactive "$@"
        ;;
esac
