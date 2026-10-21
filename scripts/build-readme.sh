#!/usr/bin/env bash
#
# build-readme.sh — render the GitHub profile README from the template + stats.json.
#
#   README.md = scripts/templates/README.template.md with every
#   `<!-- GEN:<name> -->` line replaced by the generated block `<name>`.
#
# Deterministic and idempotent (same inputs -> same README.md, whatever README.md
# contained before), fails loudly on bad input, plain GFM only (no mermaid, no
# external image services). Shared helpers live in scripts/lib.sh.
#
# Usage: scripts/build-readme.sh [STATS_JSON] [README] [TEMPLATE]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STATS_JSON="${1:-${REPO_ROOT}/stats.json}"
OUT="${2:-${REPO_ROOT}/README.md}"
TEMPLATE="${3:-${SCRIPT_DIR}/templates/README.template.md}"
# The profile repo itself is never a "project"; it is filtered out of lists.
SELF_REPO="${SELF_REPO:-polo-nyan}"

# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_tools
validate_json "$STATS_JSON" totalRepos publicRepos privateRepos languages updatedAt activity prsAllTime
jq -e '.totalRepos > 0' "$STATS_JSON" >/dev/null 2>&1 \
  || die "stats.json reports 0 repositories; refusing to render an empty profile"
jq -e '(.languages | length) > 0' "$STATS_JSON" >/dev/null 2>&1 \
  || die "stats.json has no language data"

# ---------------------------------------------------------------------------
# Generators. Each prints one Markdown block to stdout.
# ---------------------------------------------------------------------------

# Recently pushed public repos (forks, archived repos and the profile repo
# itself are excluded; the hand-picked "Current projects" table covers the rest).
# Dates use non-breaking hyphens so the narrow column never wraps.
gen_recent() {
  local rows
  rows="$(jq -r --arg self "$SELF_REPO" '
    (.recentlyUpdated // [])
    | map(select(.name != $self and ((.fork // false) | not) and ((.archived // false) | not) and ((.private // false) | not)))
    | .[:6][]
    | "| [\(.name)](\(.url)) | \(.description // "" | gsub("\\|"; "\\|") | if length > 90 then .[:87] + "…" else . end) | \(.language // "—") | \(.pushedAt | gsub("-"; "\u2011")) |"' \
    "$STATS_JSON")"
  [ -n "$rows" ] || { log "⚠️  no public repos left after filtering; skipping 'recent' block"; return 0; }
  cat <<EOF
<details>
<summary>Recently pushed public repos</summary>

| Repository | Description | Language | Last push |
|:--|:--|:--|:--|
${rows}

</details>
EOF
}

# Headline numbers: only the ones that mean something.
gen_numbers() {
  local total public priv contrib active_days merged opened rate ci_rate ci_runs
  total="$(sget .totalRepos 0)"; public="$(sget .publicRepos 0)"; priv="$(sget .privateRepos 0)"
  contrib="$(sget .activity.totalContributions 0)"; active_days="$(sget .activity.activeDays 0)"
  merged="$(sget .prsAllTime.merged 0)"; opened="$(sget .prsAllTime.opened 0)"; rate="$(sget .prsAllTime.mergeRate 0)"
  ci_rate="$(sget .ci.successRate '')"; ci_runs="$(sget .ci.runsSampled 0)"
  local ci_cell="—"
  if [ -n "$ci_rate" ] && [ "$ci_runs" != "0" ]; then ci_cell="**${ci_rate}%** <sub>of $(num "$ci_runs") runs</sub>"; fi
  cat <<EOF
| Repositories | Contributions <sub>12 mo</sub> | Active days <sub>12 mo</sub> | PRs merged | CI success |
|:--:|:--:|:--:|:--:|:--:|
| **$(num "$total")** <sub>${public} public · $(num "$priv") private</sub> | **$(num "$contrib")** | **${active_days}** | **$(num "$merged")** <sub>of $(num "$opened") · ${rate}%</sub> | ${ci_cell} |
EOF
}

# Languages by code volume: top 6 as bars, full list collapsed.
gen_languages() {
  local max rows all
  max="$(jq -r '[.languages[].percentage | tonumber] | max' "$STATS_JSON")"
  rows="$(jq -r '.languages[:6][] | "\(.name)\t\(.percentage)\t\(.repos)"' "$STATS_JSON" \
    | while IFS=$'\t' read -r name pct repos; do
        printf '| %s | `%s` | %s%% | %s |\n' "$name" "$(bar "$pct" "$max")" "$pct" "$repos"
      done)"
  all="$(jq -r '.languages[6:][] | "| \(.name) | \(.percentage)% | \(.repos) |"' "$STATS_JSON")"
  cat <<EOF
**Languages** <sub>by bytes across all repos, incl. private</sub>

| Language | | Share | Repos |
|:--|:--|--:|--:|
${rows}
EOF
  if [ -n "$all" ]; then
    cat <<EOF

<details>
<summary>All languages</summary>

| Language | Share | Repos |
|:--|--:|--:|
${all}

</details>
EOF
  fi
}

# Activity details: streaks, PR flow, cadence sparkline, repos per year.
gen_activity() {
  local cur longest busy_date busy_count d30 d90 window
  window="$(sget .activity.window 'past 12 months')"
  cur="$(sget .activity.currentStreakDays 0)"; longest="$(sget .activity.longestStreakDays 0)"
  busy_date="$(sget .activity.busiestDay.date '—')"; busy_count="$(sget .activity.busiestDay.count 0)"
  d30="$(sget .activity.last30d 0)"; d90="$(sget .activity.last90d 0)"
  local hours weekday top_hour sample
  hours="$(jq -r '(.commitPatterns.byHour // []) | map(tostring) | join(" ")' "$STATS_JSON")"
  weekday="$(sget .commitPatterns.topWeekday '')"; top_hour="$(sget .commitPatterns.topHour '')"
  sample="$(sget .commitPatterns.sampleSize 0)"
  local years ymax
  ymax="$(jq -r '[(.reposByYear // {})[]] | max // 0' "$STATS_JSON")"
  years="$(jq -r '(.reposByYear // {}) | to_entries | sort_by(.key)[] | "\(.key)\t\(.value)"' "$STATS_JSON" \
    | while IFS=$'\t' read -r y n; do printf '| %s | `%s` | %s |\n' "$y" "$(bar "$n" "$ymax")" "$n"; done)"

  cat <<EOF
<details>
<summary>Activity details</summary>

| Contributions <sub>${window}, incl. private</sub> | |
|:--|--:|
| Last 30 / 90 days | **$(num "$d30")** / **$(num "$d90")** |
| Current streak | **${cur} days** |
| Longest streak | **${longest} days** |
| Busiest day | **$(num "$busy_count")** <sub>${busy_date}</sub> |
EOF
  if [ -n "$hours" ]; then
    cat <<EOF

**Commit clock** <sub>UTC, ${sample} sampled commits · busiest: ${weekday} around ${top_hour}:00</sub>

\`\`\`
00h $(spark "$hours") 23h
\`\`\`
EOF
  fi
  if [ -n "$years" ]; then
    cat <<EOF

**Repositories created per year**

| Year | | Repos |
|:--|:--|--:|
${years}
EOF
  fi
  cat <<EOF

</details>
EOF
}

# One line pointing at the dedicated AI statistics page; the numbers live there.
gen_ai_link() {
  local enabled rate; enabled="$(sget .ai.enabled false)"; rate="$(sget .ai.assistRate '')"
  if [ "$enabled" = "true" ] && [ -n "$rate" ]; then
    printf '<sub>AI pair-programming: **%s%%** of recent commits carry an AI co-author trailer. Full analysis in [AI-STATS.md](AI-STATS.md).</sub>\n' "$rate"
  else
    printf '<sub>AI pair-programming analysis: [AI-STATS.md](AI-STATS.md).</sub>\n'
  fi
}

gen_updated() {
  printf '<sub>Last updated %s.</sub>\n' "$(sget .updatedAt "$(date -u +%Y-%m-%d)")"
}

render_template
