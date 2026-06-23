#!/usr/bin/env bash
#
# build-readme.sh — assemble the GitHub profile README from stats.json.
#
# Design goals:
#   * Idempotent & self-bootstrapping: if README.md (or the generated region)
#     is missing, it is created from scripts/templates/README.template.md.
#     Hand-written content outside the markers is always preserved; only the
#     region between STATS:START and STATS:END is rewritten.
#   * Resilient: a missing/empty/invalid stats.json or a missing individual
#     field never aborts the run — sane defaults are used and the section is
#     skipped instead of producing broken Markdown.
#   * Minimal deps: bash + jq only.
#
# Usage:
#   scripts/build-readme.sh [STATS_JSON] [README] [TEMPLATE]
# Defaults:
#   STATS_JSON = stats.json
#   README     = README.md
#   TEMPLATE   = scripts/templates/README.template.md
#
# Exit status is 0 on success. The script writes README.md in place; the
# caller (workflow) is responsible for deciding whether to commit a diff.

set -euo pipefail

START_MARKER='<!-- STATS:START -->'
END_MARKER='<!-- STATS:END -->'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STATS_JSON="${1:-${REPO_ROOT}/stats.json}"
README="${2:-${REPO_ROOT}/README.md}"
TEMPLATE="${3:-${SCRIPT_DIR}/templates/README.template.md}"

log() { printf '%s\n' "$*" >&2; }

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    log "❌ jq is required but not installed."
    exit 1
  fi
}

# Read a scalar from stats.json with a fallback. Never aborts.
stat_get() {
  local path="$1" default="${2:-}"
  local val
  val="$(jq -r "${path} // empty" "$STATS_JSON" 2>/dev/null || true)"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

require_jq

# ---------------------------------------------------------------------------
# 1. Validate stats.json. If it is missing or invalid we still (re)assemble the
#    README so the structure/markers exist, but emit a minimal placeholder.
# ---------------------------------------------------------------------------
STATS_OK=1
if [ ! -s "$STATS_JSON" ]; then
  log "⚠️  stats.json missing or empty ($STATS_JSON); generating placeholder section."
  STATS_OK=0
elif ! jq empty "$STATS_JSON" >/dev/null 2>&1; then
  log "⚠️  stats.json is not valid JSON; generating placeholder section."
  STATS_OK=0
fi

# ---------------------------------------------------------------------------
# 2. Build the generated section into a temp file.
# ---------------------------------------------------------------------------
SECTION="$(mktemp)"
trap 'rm -f "$SECTION" "${SECTION}.body" 2>/dev/null || true' EXIT

if [ "$STATS_OK" -eq 0 ]; then
  {
    echo ''
    echo '> _Stats are being collected. They will appear here after the next successful workflow run._'
    echo ''
  } >> "$SECTION"
else
  UPDATED_AT="$(stat_get '.updatedAt' "$(date -u +%Y-%m-%d)")"
  TOTAL_REPOS="$(stat_get '.totalRepos' '0')"
  PUBLIC_REPOS="$(stat_get '.publicRepos' '0')"
  PRIVATE_REPOS="$(stat_get '.privateRepos' '0')"
  PERSONAL_PUBLIC="$(stat_get '.personalPublic' '0')"
  PERSONAL_PRIVATE="$(stat_get '.personalPrivate' '0')"
  ORG_PUBLIC="$(stat_get '.orgPublic' '0')"
  ORG_PRIVATE="$(stat_get '.orgPrivate' '0')"
  TOTAL_STARS="$(stat_get '.totalStars' '0')"
  TOTAL_FORKS="$(stat_get '.totalForks' '0')"
  TOP_LANG="$(stat_get '.topLanguage' 'Unknown')"
  RECENT_COMMITS="$(stat_get '.recentCommits' '0')"
  TOTAL_SIZE_MB="$(stat_get '.totalSizeMB' '0')"
  ARCHIVED_REPOS="$(stat_get '.archivedRepos' '0')"
  ACTIVE_REPOS="$(stat_get '.activeRepos' '0')"
  ORIGINAL_REPOS="$(stat_get '.originalRepos' '0')"
  FORKED_REPOS="$(stat_get '.forkedRepos' '0')"
  TOTAL_COMMITS="$(stat_get '.totalCommits' '0')"
  AVG_COMMITS="$(stat_get '.avgCommitsPerRepo' '0')"
  MEDIAN_COMMITS="$(stat_get '.medianCommits' '0')"
  ESTIMATED_FILES="$(stat_get '.estimatedTotalFiles' '0')"
  AVG_FILES="$(stat_get '.avgFilesPerRepo' '0')"
  ESTIMATED_LINES="$(stat_get '.estimatedTotalLines' '0')"
  AVG_LINES_FILE="$(stat_get '.avgLinesPerFile' '0')"
  AVG_REPO_AGE="$(stat_get '.avgRepoAge' '0')"

  # --- Overview ----------------------------------------------------------
  {
    echo ''
    echo '<div align="center">'
    echo ''
    echo '### 📈 Overview'
    echo ''
    echo '| 📁 Repositories | ⭐ Stars | 🍴 Forks | 💻 Top Language | 📦 Total Size |'
    echo '|:---------------:|:-------:|:--------:|:---------------:|:-------------:|'
    echo "| **${TOTAL_REPOS}** | **${TOTAL_STARS}** | **${TOTAL_FORKS}** | **${TOP_LANG}** | **${TOTAL_SIZE_MB} MB** |"
    echo ''
    echo '</div>'
    echo ''
    echo '---'
    echo ''
  } >> "$SECTION"

  # --- Repository distribution ------------------------------------------
  {
    echo '### 📁 Repository Distribution'
    echo ''
    echo '<div align="center">'
    echo ''
    echo '```mermaid'
    echo '%%{init: {"theme": "base", "themeVariables": { "pie1": "#22c55e", "pie2": "#f59e0b", "pie3": "#3b82f6", "pie4": "#ec4899", "pieTextColor": "#ffffff", "pieLegendTextColor": "#e2e8f0", "pieSectionTextColor": "#ffffff", "pieStrokeColor": "#1e293b" }}}%%'
    echo 'pie showData'
    echo '    title Repository Visibility'
    echo "    \"🌐 Public\" : ${PUBLIC_REPOS}"
    echo "    \"🔒 Private\" : ${PRIVATE_REPOS}"
    echo '```'
    echo ''
    echo '</div>'
    echo ''
    echo '<table align="center">'
    echo '<tr>'
    echo '<td align="center">'
    echo ''
    echo '**📊 By Visibility**'
    echo ''
    echo '| Type | Count |'
    echo '|:-----|------:|'
    echo "| 🌐 Public | ${PUBLIC_REPOS} |"
    echo "| 🔒 Private | ${PRIVATE_REPOS} |"
    echo ''
    echo '</td>'
    echo '<td align="center">'
    echo ''
    echo '**👤 By Owner**'
    echo ''
    echo '| Type | Public | Private |'
    echo '|:-----|-------:|--------:|'
    echo "| Personal | ${PERSONAL_PUBLIC} | ${PERSONAL_PRIVATE} |"
    echo "| Organization | ${ORG_PUBLIC} | ${ORG_PRIVATE} |"
    echo ''
    echo '</td>'
    echo '<td align="center">'
    echo ''
    echo '**📋 By Status**'
    echo ''
    echo '| Type | Count |'
    echo '|:-----|------:|'
    echo "| ✅ Active | ${ACTIVE_REPOS} |"
    echo "| 📦 Archived | ${ARCHIVED_REPOS} |"
    echo "| 🔀 Original | ${ORIGINAL_REPOS} |"
    echo "| 🍴 Forked | ${FORKED_REPOS} |"
    echo ''
    echo '</td>'
    echo '</tr>'
    echo '</table>'
    echo ''
    echo '---'
    echo ''
  } >> "$SECTION"

  # --- Activity & commits -----------------------------------------------
  {
    echo '### 🔥 Activity & Commits'
    echo ''
    echo '<div align="center">'
    echo ''
    echo '<table>'
    echo '<tr>'
    echo '<td align="center">'
    echo ''
    echo '**📝 Commit Stats**'
    echo ''
    echo '| Metric | Value |'
    echo '|:-------|------:|'
    echo "| Total Commits | **${TOTAL_COMMITS}** |"
    echo "| Avg per Repo | **${AVG_COMMITS}** |"
    echo "| Median | **${MEDIAN_COMMITS}** |"
    echo ''
    echo '</td>'
    echo '<td align="center">'
    echo ''
    echo '**📜 Codebase Size**'
    echo ''
    echo '| Metric | Value |'
    echo '|:-------|------:|'
    echo "| Est. Files | **~${ESTIMATED_FILES}** |"
    echo "| Est. Lines | **~${ESTIMATED_LINES}** |"
    echo "| Avg Files/Repo | **${AVG_FILES}** |"
    echo "| Avg Lines/File | **${AVG_LINES_FILE}** |"
    echo ''
    echo '</td>'
    echo '<td align="center">'
    echo ''
    echo '**📅 Activity**'
    echo ''
    echo '| Metric | Value |'
    echo '|:-------|------:|'
    echo "| Push Events (30d) | **${RECENT_COMMITS}** |"
    echo "| Avg Repo Age | **${AVG_REPO_AGE} years** |"
    echo ''
    echo '</td>'
    echo '</tr>'
    echo '</table>'
    echo ''
    echo '</div>'
    echo ''
    echo '---'
    echo ''
  } >> "$SECTION"

  # --- Languages ---------------------------------------------------------
  LANG_COUNT="$(jq -r '(.languages // []) | length' "$STATS_JSON" 2>/dev/null || echo 0)"
  if [ "${LANG_COUNT:-0}" -gt 0 ]; then
    {
      echo '### 💻 Languages by Code Volume'
      echo ''
      echo '<div align="center">'
      echo ''
      echo '```mermaid'
      echo '%%{init: {"theme": "base", "themeVariables": { "pie1": "#8b5cf6", "pie2": "#f59e0b", "pie3": "#06b6d4", "pie4": "#22c55e", "pie5": "#f43f5e", "pie6": "#3b82f6", "pie7": "#ec4899", "pieTextColor": "#ffffff", "pieLegendTextColor": "#e2e8f0", "pieSectionTextColor": "#ffffff", "pieStrokeColor": "#1e293b" }}}%%'
      echo 'pie showData'
      echo '    title Code Distribution by Language'
      jq -r '(.languages // [])[:6][] | "    \"\(.name)\" : \(.percentage)"' "$STATS_JSON" 2>/dev/null || true
      echo '```'
      echo ''
      echo '</div>'
      echo ''
      echo '<details>'
      echo '<summary><b>📋 Detailed Language Breakdown</b></summary>'
      echo ''
      echo '| Language | Percentage | Repositories |'
      echo '|:---------|:----------:|:------------:|'
      jq -r '(.languages // [])[] | "| \(.name) | \(.percentage)% | \(.repos) |"' "$STATS_JSON" 2>/dev/null || true
      echo ''
      echo '</details>'
      echo ''
      echo '---'
      echo ''
    } >> "$SECTION"
  fi

  # --- Notable public projects ------------------------------------------
  TOP_COUNT="$(jq -r '[(.topStarred // [])[] | select(.stars > 0)] | length' "$STATS_JSON" 2>/dev/null || echo 0)"
  ALL_TOP_COUNT="$(jq -r '(.topStarred // []) | length' "$STATS_JSON" 2>/dev/null || echo 0)"
  if [ "${ALL_TOP_COUNT:-0}" -gt 0 ]; then
    {
      echo '### ⭐ Notable Public Projects'
      echo ''
    } >> "$SECTION"
    if [ "${TOP_COUNT:-0}" -gt 0 ]; then
      # Repos that actually have stars: show with star count.
      jq -r '(.topStarred // [])[] | select(.stars > 0) |
              "- [**\(.name)**](\(.url)) — ⭐ \(.stars)" +
              (if (.description // "") != "" then "\n  > \(.description)" else "" end)' \
        "$STATS_JSON" >> "$SECTION" 2>/dev/null || true
    else
      # No stars yet — still surface the public projects so the section is useful.
      jq -r '(.topStarred // [])[] |
              "- [**\(.name)**](\(.url))" +
              (if (.description // "") != "" then "\n  > \(.description)" else "" end)' \
        "$STATS_JSON" >> "$SECTION" 2>/dev/null || true
    fi
    echo '' >> "$SECTION"
  fi

  # --- Recently updated --------------------------------------------------
  RECENT_COUNT="$(jq -r '(.recentlyUpdated // []) | length' "$STATS_JSON" 2>/dev/null || echo 0)"
  if [ "${RECENT_COUNT:-0}" -gt 0 ]; then
    {
      echo '<details>'
      echo '<summary><b>🔄 Recently Updated (Public)</b></summary>'
      echo ''
      echo '| Repository | Last Updated |'
      echo '|:-----------|:------------:|'
      jq -r '(.recentlyUpdated // [])[:5][] | "| [\(.name)](\(.url)) | \(.pushedAt) |"' "$STATS_JSON" 2>/dev/null || true
      echo ''
      echo '</details>'
      echo ''
      echo '---'
      echo ''
    } >> "$SECTION"
  fi

  # --- Repository creation timeline -------------------------------------
  YEARS="$(jq -r '(.reposByYear // {}) | keys | sort | .[]' "$STATS_JSON" 2>/dev/null || true)"
  if [ -n "$YEARS" ]; then
    {
      echo '### 📅 Repository Creation Timeline'
      echo ''
      echo '<div align="center">'
      echo ''
      echo '```mermaid'
      echo '%%{init: {"xyChart": {"titleColor": "#ffffff", "xAxisLabelColor": "#ffffff", "yAxisLabelColor": "#ffffff"}, "themeVariables": {"xyChart": {"titleColor": "#ffffff", "plotColorPalette": "#a78bfa"}}}}%%'
      echo 'xychart-beta'
      echo '    title "Repos Created Per Year"'
      # x-axis: quoted years; bar: counts. Built with jq to stay safe.
      jq -r '(.reposByYear // {}) as $y
             | ($y | keys | sort) as $ks
             | "    x-axis [" + ([$ks[] | "\"\(.)\""] | join(", ")) + "]"' \
        "$STATS_JSON" 2>/dev/null || true
      jq -r '(.reposByYear // {}) as $y
             | ($y | keys | sort) as $ks
             | "    bar [" + ([$ks[] | ($y[.] | tostring)] | join(", ")) + "]"' \
        "$STATS_JSON" 2>/dev/null || true
      echo '```'
      echo ''
      echo '</div>'
      echo ''
      echo '---'
      echo ''
    } >> "$SECTION"
  fi

  # --- Development focus (static mindmap) -------------------------------
  {
    echo '### 🎯 Development Focus'
    echo ''
    echo '<div align="center">'
    echo ''
    echo '```mermaid'
    echo '%%{init: {"theme": "base", "themeVariables": { "primaryColor": "#6366f1", "primaryTextColor": "#ffffff", "primaryBorderColor": "#818cf8", "lineColor": "#a5b4fc", "secondaryColor": "#8b5cf6", "tertiaryColor": "#a78bfa" }}}%%'
    echo 'mindmap'
    echo '  root((🚀 My Projects))'
    echo '    🖥️ Backend'
    echo '      PHP'
    echo '      C# .NET'
    echo '      REST APIs'
    echo '    ⚙️ DevOps'
    echo '      Docker'
    echo '      Linux'
    echo '      CI/CD'
    echo '      Python'
    echo '      ML/AI'
    echo '      IoT'
    echo '```'
    echo ''
    echo '</div>'
    echo ''
    echo '---'
    echo ''
  } >> "$SECTION"

  # --- Quick stats footer ------------------------------------------------
  {
    echo '<div align="center">'
    echo ''
    echo '| 📊 Quick Stats | |'
    echo '|:---|:---|'
    echo "| 📁 Total Repos | **${TOTAL_REPOS}** (${PUBLIC_REPOS} public, ${PRIVATE_REPOS} private) |"
    echo "| 💾 Code Volume | **${TOTAL_SIZE_MB} MB** across ${ORIGINAL_REPOS} projects |"
    echo "| 💻 Top Language | **${TOP_LANG}** |"
    echo "| 📅 Last Updated | **${UPDATED_AT}** |"
    echo ''
    echo '</div>'
    echo ''
  } >> "$SECTION"
fi

# ---------------------------------------------------------------------------
# 3. Self-bootstrap: ensure README.md exists and contains both markers.
#    If not, start from the template.
# ---------------------------------------------------------------------------
needs_template=0
if [ ! -f "$README" ]; then
  log "ℹ️  $README does not exist; bootstrapping from template."
  needs_template=1
elif ! grep -qF "$START_MARKER" "$README" || ! grep -qF "$END_MARKER" "$README"; then
  log "ℹ️  $README is missing the STATS markers; rebuilding from template."
  needs_template=1
fi

if [ "$needs_template" -eq 1 ]; then
  if [ ! -f "$TEMPLATE" ]; then
    log "❌ Template not found at $TEMPLATE; cannot bootstrap README."
    exit 1
  fi
  cp "$TEMPLATE" "$README"
fi

# ---------------------------------------------------------------------------
# 4. Replace the region between the markers (inclusive of markers) with the
#    freshly generated section, preserving everything outside the markers.
#    Implemented in awk so it is portable and handles arbitrary content.
# ---------------------------------------------------------------------------
NEW_README="$(mktemp)"
trap 'rm -f "$SECTION" "${SECTION}.body" "$NEW_README" 2>/dev/null || true' EXIT

awk -v start="$START_MARKER" -v end="$END_MARKER" -v sectionfile="$SECTION" '
  BEGIN { inblock = 0; replaced = 0 }
  index($0, start) {
    print start
    # Stream the generated body between the markers.
    while ((getline line < sectionfile) > 0) print line
    close(sectionfile)
    print end
    inblock = 1
    replaced = 1
    next
  }
  index($0, end) {
    if (inblock) { inblock = 0; next }
  }
  { if (!inblock) print }
  END {
    if (!replaced) {
      # Should not happen (markers guaranteed above) but fail loudly.
      exit 3
    }
  }
' "$README" > "$NEW_README"

if [ "$(awk 'END{print NR}' "$NEW_README")" -eq 0 ]; then
  log "❌ Generated README is empty; aborting without overwriting."
  exit 1
fi

mv "$NEW_README" "$README"
# NEW_README consumed; reset trap target.
trap 'rm -f "$SECTION" "${SECTION}.body" 2>/dev/null || true' EXIT

log "✅ README assembled at $README"
