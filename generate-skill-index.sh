#!/bin/bash
# generate-skill-index.sh - Scan installed Claude Code skills and generate a JSON index
# Output: $SB_CACHE_DIR/skill-index.json (+ optional index.html)
#
# Portable: works in any Claude Code project. Auto-detects project root.
# Override: SKILL_BROWSER_PROJECT_DIR=/path/to/project

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Auto-detect project root ---
# Walk up from CWD looking for .claude/skills/ directory
find_project_root() {
    local dir="${1:-$(pwd)}"
    while [ "$dir" != "/" ]; do
        if [ -d "${dir}/.claude/skills" ]; then
            echo "$dir"
            return
        fi
        dir=$(dirname "$dir")
    done
    echo ""
}

PROJECT_DIR="${SKILL_BROWSER_PROJECT_DIR:-$(find_project_root)}"
LOCAL_SKILLS_DIR="${PROJECT_DIR:+${PROJECT_DIR}/.claude/skills}"
GLOBAL_SKILLS_DIR="${HOME}/.claude/skills"
OUTPUT_DIR="${SB_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/skill-browser}"
OUTPUT_FILE="${OUTPUT_DIR}/skill-index.json"
EDITORS_FILE="${SB_EDITORS_FILE:-${OUTPUT_DIR}/editors.json}"

mkdir -p "${OUTPUT_DIR}"

# Load editor definitions for multi-editor scanning
declare -a EDITOR_NAMES=()
declare -A EDITOR_GLOBALS=()
declare -A EDITOR_LOCALS=()
declare -A EDITOR_FOUND=()

load_editors() {
    if [ -f "$EDITORS_FILE" ]; then
        # Parse editors.json safely without eval - read tab-delimited fields
        while IFS=$'\t' read -r ename eglobal elocal efound; do
            [ -z "$ename" ] && continue
            EDITOR_NAMES+=("$ename")
            EDITOR_GLOBALS["$ename"]="$eglobal"
            EDITOR_LOCALS["$ename"]="$elocal"
            EDITOR_FOUND["$ename"]="$efound"
        done < <(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        editors = json.load(f)
    for e in editors:
        found = 'true' if e.get('found') else 'false'
        # Output tab-delimited: name, global, local, found
        # Validate name is alphanumeric to prevent injection
        name = e['name']
        if not name.isalnum():
            continue
        print(f'{name}\t{e[\"global\"]}\t{e[\"local\"]}\t{found}')
except Exception:
    pass
" "$EDITORS_FILE" 2>/dev/null)
    fi
    # Fallback: always include claude if no editors loaded
    if [ ${#EDITOR_NAMES[@]} -eq 0 ]; then
        EDITOR_NAMES+=("claude")
        EDITOR_GLOBALS["claude"]="${HOME}/.claude/skills"
        EDITOR_LOCALS["claude"]=".claude/skills"
        EDITOR_FOUND["claude"]="true"
    fi
}
load_editors

# Check if any editor has skills
has_any_skills=false
for ename in "${EDITOR_NAMES[@]}"; do
    [ "${EDITOR_FOUND[$ename]}" = "true" ] || continue
    [ -d "${EDITOR_GLOBALS[$ename]}" ] && { has_any_skills=true; break; }
    if [ -n "$PROJECT_DIR" ] && [ -d "${PROJECT_DIR}/${EDITOR_LOCALS[$ename]}" ]; then
        has_any_skills=true; break
    fi
done

if [ "$has_any_skills" = false ] && [ -z "$PROJECT_DIR" ]; then
    echo "ERROR: No skills found. Run from a project with skills or set SKILL_BROWSER_PROJECT_DIR." >&2
    exit 1
fi

# Track seen skills for deduplication
declare -A SEEN_SKILLS

# Extract YAML frontmatter value
extract_field() {
    local frontmatter="$1"
    local field="$2"
    echo "$frontmatter" | grep -E "^${field}:" | head -1 | sed "s/^${field}: *//" | tr -d '"' | tr -d "'" || true
}

# Extract YAML list items under a nested key (e.g., requires.mcps)
extract_nested_list() {
    local frontmatter="$1"
    local parent="$2"
    local child="$3"
    echo "$frontmatter" | awk -v p="$parent" -v c="$child" '
        $0 ~ "^"p":"{found=1; next}
        found && $0 ~ "^  "c":"{getlist=1; next}
        getlist && /^    - /{gsub(/^    - /,""); gsub(/"/,""); gsub(/'\''/,""); print; next}
        getlist && !/^    /{exit}
        found && /^[^ ]/{exit}
    ' 2>/dev/null || true
}

# Extract top-level YAML list items (e.g., provides)
extract_list() {
    local frontmatter="$1"
    local field="$2"
    echo "$frontmatter" | awk -v f="$field" '
        $0 ~ "^"f":"{getlist=1; next}
        getlist && /^  - /{gsub(/^  - /,""); gsub(/"/,""); gsub(/'\''/,""); print; next}
        getlist && !/^  /{exit}
    ' 2>/dev/null || true
}

# Convert a list to JSON array string
list_to_json_array() {
    local items="$1"
    if [ -z "$items" ]; then
        echo "[]"
        return
    fi
    local result="["
    local first=true
    while IFS= read -r item; do
        item=$(echo "$item" | xargs 2>/dev/null || echo "$item")
        [ -z "$item" ] && continue
        if [ "$first" = true ]; then
            first=false
        else
            result+=","
        fi
        result+="\"${item}\""
    done <<< "$items"
    result+="]"
    echo "$result"
}

# Escape string for JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/ }"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/}"
    echo "$s"
}

# Parse sub-skills from a compound skill
parse_sub_skills() {
    local skill_dir="$1"
    local skill_file="$2"
    local sub_skills_dir="${skill_dir}/skills"

    if [ ! -d "$sub_skills_dir" ]; then
        echo "[]"
        return
    fi

    local result="["
    local first=true

    for sub_file in "${sub_skills_dir}"/*.md; do
        [ -f "$sub_file" ] || continue
        local sub_name
        sub_name=$(basename "$sub_file" .md)

        local sub_desc=""
        # Check if sub-file has frontmatter
        local sub_fm
        sub_fm=$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$sub_file" 2>/dev/null || true)
        if [ -n "$sub_fm" ]; then
            sub_desc=$(extract_field "$sub_fm" "description")
        fi
        # Fallback: grab description from parent SKILL.md command table
        if [ -z "$sub_desc" ]; then
            local table_line
            table_line=$(grep -F "[${sub_name}]" "$skill_file" 2>/dev/null | head -1 || true)
            if [ -n "$table_line" ]; then
                sub_desc=$(echo "$table_line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}' 2>/dev/null || true)
            fi
        fi
        # Fallback 2: extract first sentence from the sub-skill file body
        if [ -z "$sub_desc" ] || [ "$sub_desc" = "|" ]; then
            sub_desc=$(awk '/^---$/{n++; next} n>=2 && /^[A-Z]/{print; exit}' "$sub_file" 2>/dev/null | head -c 200 || true)
        fi
        [ -z "$sub_desc" ] && sub_desc="Sub-skill of $(basename "$skill_dir")"

        sub_desc=$(json_escape "$sub_desc")

        if [ "$first" = true ]; then
            first=false
        else
            result+=","
        fi
        result+="{\"name\":\"${sub_name}\",\"description\":\"${sub_desc}\",\"command\":\"/${sub_name}\"}"
    done

    result+="]"
    echo "$result"
}

# Collect entries in a temp file
ENTRIES_FILE=$(mktemp)
trap 'rm -f "$ENTRIES_FILE"' EXIT

# Track which editors each skill has been seen in
declare -A SKILL_EDITORS

# Process a single skill directory
process_skill() {
    local dir="$1"
    local scope="$2"
    local editor="${3:-claude}"
    local name
    name=$(basename "$dir")

    [ -d "$dir" ] || return 0
    [[ "$name" == *.* ]] && return 0

    local skill_file="${dir}/SKILL.md"
    # For cursor, also check .mdc files
    if [ ! -f "$skill_file" ] && [ "$editor" = "cursor" ]; then
        # Look for any .mdc file as skill_file
        local mdc_file
        mdc_file=$(ls "${dir}"/*.mdc 2>/dev/null | head -1)
        if [ -n "$mdc_file" ]; then
            skill_file="$mdc_file"
        else
            return 0
        fi
    elif [ ! -f "$skill_file" ]; then
        return 0
    fi

    # Handle deduplication: track editors per skill
    if [ -n "${SEEN_SKILLS[$name]+x}" ]; then
        # Already seen: update scope + add editor
        local prev_editors="${SKILL_EDITORS[$name]:-$editor}"
        # Use comma-delimited exact match (not substring) to avoid "code" matching "opencode"
        if [[ ! ",${prev_editors}," == *",${editor},"* ]]; then
            SKILL_EDITORS[$name]="${prev_editors},${editor}"
        fi
        if [ "$scope" != "${SEEN_SKILLS[$name]}" ]; then
            SEEN_SKILLS[$name]="both"
        fi
        # Update the editors field in the existing entry (pass values via env vars, not interpolation)
        local updated_editors="${SKILL_EDITORS[$name]}"
        _SB_ENTRIES="$ENTRIES_FILE" _SB_NAME="$name" _SB_SCOPE="${SEEN_SKILLS[$name]}" _SB_EDITORS="$updated_editors" \
        python3 -c "
import re, json, os
entries_file = os.environ['_SB_ENTRIES']
skill_name = os.environ['_SB_NAME']
new_scope = os.environ['_SB_SCOPE']
editors_csv = os.environ['_SB_EDITORS']
with open(entries_file, 'r') as f:
    lines = f.readlines()
with open(entries_file, 'w') as f:
    for line in lines:
        if '\"id\":\"' + skill_name + '\"' in line:
            line = re.sub(r'\"scope\":\"[^\"]*\"', '\"scope\":\"' + new_scope + '\"', line)
            editors_list = editors_csv.split(',')
            editors_json = json.dumps(editors_list)
            line = re.sub(r'\"editors\":\[[^\]]*\]', '\"editors\":' + editors_json, line)
        f.write(line)
" 2>/dev/null || true
        return 0
    fi
    SEEN_SKILLS[$name]="$scope"
    SKILL_EDITORS[$name]="$editor"

    # Extract frontmatter
    local frontmatter
    frontmatter=$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$skill_file" 2>/dev/null || true)
    [ -z "$frontmatter" ] && return 0

    local fm_name fm_desc fm_cat fm_arg_hint
    fm_name=$(extract_field "$frontmatter" "name")
    fm_desc=$(extract_field "$frontmatter" "description")
    fm_cat=$(extract_field "$frontmatter" "category")
    fm_arg_hint=$(extract_field "$frontmatter" "argument-hint")

    [ -z "$fm_name" ] && fm_name="$name"
    [ -z "$fm_cat" ] && fm_cat="utility"

    fm_desc=$(json_escape "$fm_desc")
    fm_arg_hint=$(json_escape "$fm_arg_hint")

    local provides mcps bins skills_req
    provides=$(extract_list "$frontmatter" "provides")
    mcps=$(extract_nested_list "$frontmatter" "requires" "mcps")
    bins=$(extract_nested_list "$frontmatter" "requires" "bins")
    skills_req=$(extract_nested_list "$frontmatter" "requires" "skills")

    local provides_json mcps_json bins_json skills_json
    provides_json=$(list_to_json_array "$provides")
    mcps_json=$(list_to_json_array "$mcps")
    bins_json=$(list_to_json_array "$bins")
    skills_json=$(list_to_json_array "$skills_req")

    local is_compound="false"
    local sub_skills_json="[]"
    if [ -d "${dir}/skills" ] && ls "${dir}/skills/"*.md >/dev/null 2>&1; then
        is_compound="true"
        sub_skills_json=$(parse_sub_skills "$dir" "$skill_file")
    fi

    local line_count
    line_count=$(wc -l < "$skill_file" | xargs)

    # Resolve real path for skill file (use actual skill_file, not hardcoded SKILL.md)
    local real_path skill_basename
    skill_basename=$(basename "$skill_file")
    real_path=$(cd "$dir" && pwd -P)/${skill_basename}

    echo "{\"id\":\"${name}\",\"name\":\"${fm_name}\",\"description\":\"${fm_desc}\",\"category\":\"${fm_cat}\",\"scope\":\"${scope}\",\"editor\":\"${editor}\",\"editors\":[\"${editor}\"],\"provides\":${provides_json},\"requires\":{\"mcps\":${mcps_json},\"bins\":${bins_json},\"skills\":${skills_json}},\"argumentHint\":\"${fm_arg_hint}\",\"isCompound\":${is_compound},\"subSkills\":${sub_skills_json},\"triggerCommand\":\"/${name}\",\"lineCount\":${line_count},\"skillPath\":\"${real_path}\"}" >> "$ENTRIES_FILE"
}

# Process skills from all detected editors
for ename in "${EDITOR_NAMES[@]}"; do
    [ "${EDITOR_FOUND[$ename]}" = "true" ] || continue

    # Process local (project) skills for this editor
    local_dir="${PROJECT_DIR:+${PROJECT_DIR}/${EDITOR_LOCALS[$ename]}}"
    if [ -n "$local_dir" ] && [ -d "$local_dir" ]; then
        for dir in "${local_dir}"/*/; do
            [ -d "$dir" ] && process_skill "$dir" "local" "$ename"
        done
    fi

    # Process global skills for this editor
    global_dir="${EDITOR_GLOBALS[$ename]}"
    if [ -d "$global_dir" ]; then
        for dir in "${global_dir}"/*/; do
            [ -d "$dir" ] && process_skill "$dir" "global" "$ename"
        done
    fi
done

# Process plugin skills (from ~/.claude/plugins/)
PLUGINS_MANIFEST="${HOME}/.claude/plugins/installed_plugins.json"
if [ -f "$PLUGINS_MANIFEST" ]; then
    python3 -c "
import json, os, sys

manifest_path = '$PLUGINS_MANIFEST'
entries_path = '$ENTRIES_FILE'

with open(manifest_path) as f:
    manifest = json.load(f)

# Collect already-seen skill IDs from entries file
seen = set()
if os.path.exists(entries_path):
    with open(entries_path) as f:
        for line in f:
            try:
                d = json.loads(line.strip().rstrip(','))
                seen.add(d.get('id', ''))
            except:
                pass

def extract_field(frontmatter, field):
    for line in frontmatter.splitlines():
        if line.startswith(field + ':'):
            return line[len(field)+1:].strip().strip('\"').strip(\"'\")
    return ''

def json_escape(s):
    return s.replace('\\\\', '\\\\\\\\').replace('\"', '\\\\\"').replace('\\t', ' ').replace('\\n', ' ').replace('\\r', '')

new_entries = []
for plugin_key, installs in manifest.get('plugins', {}).items():
    if not installs:
        continue
    info = installs[0]
    install_path = info.get('installPath', '')
    plugin_name = plugin_key.split('@')[0]
    marketplace = plugin_key.split('@')[1] if '@' in plugin_key else ''

    skills_dir = os.path.join(install_path, 'skills')
    if not os.path.isdir(skills_dir):
        continue

    for skill_name in sorted(os.listdir(skills_dir)):
        skill_dir = os.path.join(skills_dir, skill_name)
        skill_file = os.path.join(skill_dir, 'SKILL.md')
        if not os.path.isfile(skill_file):
            continue

        # Unique ID: plugin:skill
        skill_id = f'{plugin_name}:{skill_name}'
        if skill_id in seen:
            continue
        seen.add(skill_id)

        # Parse frontmatter
        with open(skill_file) as sf:
            content = sf.read()
        lines = content.split('\\n')
        in_fm = False
        fm_lines = []
        fm_count = 0
        for line in lines:
            if line.strip() == '---':
                fm_count += 1
                if fm_count == 2:
                    break
                in_fm = True
                continue
            if in_fm:
                fm_lines.append(line)
        frontmatter = '\\n'.join(fm_lines)

        fm_name = extract_field(frontmatter, 'name') or skill_name
        fm_desc = extract_field(frontmatter, 'description') or ''
        fm_cat = extract_field(frontmatter, 'category') or 'utility'

        fm_desc = json_escape(fm_desc)
        fm_name = json_escape(fm_name)

        line_count = len(lines)
        trigger = f'/{plugin_name}:{skill_name}'

        entry = json.dumps({
            'id': skill_id,
            'name': fm_name,
            'description': fm_desc,
            'category': fm_cat,
            'scope': 'plugin',
            'provides': [],
            'requires': {'mcps': [], 'bins': [], 'skills': []},
            'argumentHint': '',
            'isCompound': False,
            'subSkills': [],
            'triggerCommand': trigger,
            'lineCount': line_count,
            'plugin': plugin_name,
            'marketplace': marketplace,
            'skillPath': skill_file
        })
        new_entries.append(entry)

# Append to entries file
if new_entries:
    with open(entries_path, 'a') as f:
        for e in new_entries:
            f.write(e + '\\n')
    print(f'  Added {len(new_entries)} plugin skills from {len(manifest.get(\"plugins\", {}))} plugins', file=sys.stderr)
" 2>&1
fi

# Count entries
SKILL_COUNT=$(wc -l < "$ENTRIES_FILE" | xargs)

LOCAL_COUNT=0
GLOBAL_COUNT=0
BOTH_COUNT=0
PLUGIN_COUNT=0
for scope in "${SEEN_SKILLS[@]}"; do
    case "$scope" in
        local) LOCAL_COUNT=$((LOCAL_COUNT + 1)) ;;
        global) GLOBAL_COUNT=$((GLOBAL_COUNT + 1)) ;;
        both) BOTH_COUNT=$((BOTH_COUNT + 1)) ;;
    esac
done
# Plugin count comes from total minus shell-processed skills
SHELL_SKILLS=${#SEEN_SKILLS[@]}
PLUGIN_COUNT=$((SKILL_COUNT - SHELL_SKILLS))

GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build JSON
{
    echo "{"
    echo "  \"generatedAt\": \"${GENERATED_AT}\","
    echo "  \"totalSkills\": ${SKILL_COUNT},"
    echo "  \"localCount\": ${LOCAL_COUNT},"
    echo "  \"globalCount\": ${GLOBAL_COUNT},"
    echo "  \"bothCount\": ${BOTH_COUNT},"
    echo "  \"pluginCount\": ${PLUGIN_COUNT},"
    echo "  \"skills\": ["

    line_num=0
    total_lines=$SKILL_COUNT
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [ "$line_num" -eq "$total_lines" ]; then
            echo "    ${line}"
        else
            echo "    ${line},"
        fi
    done < "$ENTRIES_FILE"

    echo "  ]"
    echo "}"
} > "${OUTPUT_FILE}"

# Count editors detected
DETECTED_EDITORS=""
for ename in "${EDITOR_NAMES[@]}"; do
    [ "${EDITOR_FOUND[$ename]}" = "true" ] && DETECTED_EDITORS="${DETECTED_EDITORS:+$DETECTED_EDITORS, }${ename}"
done

echo "Generated ${OUTPUT_FILE}"
echo "  Total: ${SKILL_COUNT} skills (${LOCAL_COUNT} local, ${GLOBAL_COUNT} global, ${PLUGIN_COUNT} plugin)"
echo "  Editors: ${DETECTED_EDITORS:-none}"
[ -n "$PROJECT_DIR" ] && echo "  Project: ${PROJECT_DIR}"

# Build HTML if template exists (co-located with this script)
HTML_TEMPLATE="${SCRIPT_DIR}/skill-browser-template.html"
HTML_OUTPUT="${OUTPUT_DIR}/index.html"

if [ -f "$HTML_TEMPLATE" ]; then
    python3 -c "
import json
with open('${HTML_TEMPLATE}', 'r') as f:
    html = f.read()
with open('${OUTPUT_FILE}', 'r') as f:
    data = json.dumps(json.load(f))
html = html.replace('__SKILL_DATA__', data)
with open('${HTML_OUTPUT}', 'w') as f:
    f.write(html)
"
    echo "Built ${HTML_OUTPUT} ($(wc -c < "${HTML_OUTPUT}" | xargs) bytes)"
fi
