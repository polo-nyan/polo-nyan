#!/usr/bin/env bash
#
# build-readme.sh — render the GitHub profile README from the template + stats.json.
#
#   README.md = scripts/templates/README.template.md with every
#   `<!-- GEN:<name> -->` line replaced by the generated block `<name>`.
#
# Properties:
#   * Deterministic and idempotent: the same template + stats.json always
#     produce the same README.md, no matter what README.md contained before.
#     README.md is therefore a build artifact; edit the template instead.
#   * Fails loudly: a missing/invalid stats.json, a missing required field,
#     an unknown placeholder or an empty render all exit non-zero and leave
#     the existing README.md untouched.
#   * No mermaid, no external image services, no inline colours: everything
#     is plain GFM (tables, <details>, unicode bars) so it reads the same in
#     GitHub's light and dark themes.
#   * Minimal deps: bash 4+, jq, awk.
#
# Usage:
#   scripts/build-readme.sh [STATS_JSON] [README] [TEMPLATE]
# Defaults:
#   STATS_JSON = stats.json
#   README     = README.md
#   TEMPLATE   = scripts/templates/README.template.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STATS_JSON="${1:-${REPO_ROOT}/stats.json}"
README="${2:-${REPO_ROOT}/README.md}"
TEMPLATE="${3:-${SCRIPT_DIR}/templates/README.template.md}"

# The profile repo itself is never a "project"; it is filtered out of lists.
SELF_REPO="${SELF_REPO:-polo-nyan}"
BAR_WIDTH=12

log()  { printf '%s\n' "$*" >&2; }
die()  { log "❌ $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Validate inputs. Anything wrong here is a real problem; do not paper over.
# ---------------------------------------------------------------------------
command -v jq  >/dev/null 2>&1 || die "jq is required but not installed."
command -v awk >/dev/null 2>&1 || die "awk is required but not installed."
[ -f "$TEMPLATE" ]   || die "template not found: $TEMPLATE"
[ -s "$STATS_JSON" ] || die "stats.json missing or empty: $STATS_JSON"
jq empty "$STATS_JSON" >/dev/null 2>&1 || die "stats.json is not valid JSON: $STATS_JSON"

# Required fields: the README cannot be meaningful without them.
for key in totalRepos publicRepos privateRepos languages updatedAt activity prsAllTime; do
  jq -e --arg k "$key" 'has($k) and .[$k] != null' "$STATS_JSON" >/dev/null 2>&1 \
    || die "stats.json is missing required field '$key'"
done
jq -e '.totalRepos > 0' "$STATS_JSON" >/dev/null 2>&1 \
  || die "stats.json reports 0 repositories; refusing to render an empty profile"
jq -e '(.languages | length) > 0' "$STATS_JSON" >/dev/null 2>&1 \
  || die "stats.json has no language data"

# ---------------------------------------------------------------------------
# 2. Helpers.
# ---------------------------------------------------------------------------

# Read a scalar; empty/null -> default.
sget() {
  local path="$1" default="${2:-}" val
  val="$(jq -r "${path} // empty" "$STATS_JSON")"
  if [ -z "$val" ] || [ "$val" = "null" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# Thousands separator for integers or decimals: 11898 -> 11,898 ; 1651.8 -> 1,651.8
num() {
  local s="$1" int frac="" out=""
  case "$s" in *.*) int="${s%%.*}"; frac=".${s#*.}";; *) int="$s";; esac
  [[ "$int" =~ ^-?[0-9]+$ ]] || { printf '%s' "$s"; return; }
  while [ ${#int} -gt 3 ]; do out=",${int: -3}${out}"; int="${int:0:${#int}-3}"; done
  printf '%s%s%s' "$int" "$out" "$frac"
}

# bar VALUE MAX -> "█████░░░░░░░" (BAR_WIDTH cells, proportional to VALUE/MAX).
bar() {
  awk -v v="$1" -v m="$2" -v w="$BAR_WIDTH" 'BEGIN {
    n = (m > 0) ? int(v * w / m + 0.5) : 0;
    if (n > w) n = w; if (v > 0 && n < 1) n = 1;
    s = ""; for (i = 0; i < n; i++) s = s "█"; for (; i < w; i++) s = s "░";
    printf "%s", s }'
}

# spark "1 5 9 ..." -> "▁▂▃▅▇█" scaled to the series maximum.
spark() {
  awk 'BEGIN { split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", lv, " ") }
       { m = 0; for (i = 1; i <= NF; i++) if ($i > m) m = $i;
         for (i = 1; i <= NF; i++) { k = (m > 0) ? int($i * 7 / m + 0.5) + 1 : 1; printf "%s", lv[k] } }' <<<"$1"
}

# ---------------------------------------------------------------------------
# 3. Generators. Each prints one Markdown block to stdout.
# ---------------------------------------------------------------------------

# Recently pushed public repos (forks, archived repos and the profile repo
# itself are excluded; the hand-picked "Current projects" table covers the rest).
gen_recent() {
  local rows
  rows="$(jq -r --arg self "$SELF_REPO" '
    (.recentlyUpdated // [])
    | map(select(.name != $self and ((.fork // false) | not) and ((.archived // false) | not)))
    | .[:6][]
    | "| [\(.name)](\(.url)) | \(.description // "" | gsub("\\|"; "\\|") | if length > 90 then .[:87] + "…" else . end) | \(.language // "—") | \(.pushedAt) |"' \
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

# AI pair-programming: derived from Co-authored-by trailers. Headline rate +
# monthly trend; family split collapsed. Per-version model tables are not shown.
gen_ai() {
  local enabled; enabled="$(sget .ai.enabled false)"
  [ "$enabled" = "true" ] || return 0
  local commits scanned rate months mmax fams
  commits="$(sget .ai.totalAICommits 0)"; scanned="$(sget .ai.scannedCommits 0)"; rate="$(sget .ai.assistRate 0)"
  mmax="$(jq -r '[(.ai.monthly // [])[].total] | max // 0' "$STATS_JSON")"
  months="$(jq -r '(.ai.monthly // []) | .[-6:][] | "\(.month)\t\(.total)"' "$STATS_JSON" \
    | while IFS=$'\t' read -r m n; do printf '| %s | `%s` | %s |\n' "$m" "$(bar "$n" "$mmax")" "$(num "$n")"; done)"
  fams="$(jq -r '(.ai.families // [])[] | "| \(.family) | \(.count) |"' "$STATS_JSON")"
  cat <<EOF
<details>
<summary>AI pair-programming — <b>${rate}%</b> of $(num "$scanned") recent commits carry an AI co-author trailer</summary>

Derived from \`Co-authored-by:\` trailers on my commits: **$(num "$commits")** of $(num "$scanned") scanned commits were written with an AI assistant in the loop.
EOF
  if [ -n "$months" ]; then
    cat <<EOF

| Month | | AI-assisted commits |
|:--|:--|--:|
${months}
EOF
  fi
  if [ -n "$fams" ]; then
    cat <<EOF

| Co-author family | Credits |
|:--|--:|
${fams}
EOF
  fi
  cat <<EOF

</details>
EOF
}

gen_updated() {
  printf '<sub>Last updated %s.</sub>\n' "$(sget .updatedAt "$(date -u +%Y-%m-%d)")"
}

# ---------------------------------------------------------------------------
# 4. Assemble: replace every GEN placeholder; unknown names fail the build.
# ---------------------------------------------------------------------------
NEW_README="$(mktemp)"
trap 'rm -f "$NEW_README"' EXIT

replaced=0
while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^\<!--\ GEN:([a-z_]+)\ --\>$ ]]; then
    name="${BASH_REMATCH[1]}"
    declare -F "gen_${name}" >/dev/null || die "template references unknown block GEN:${name}"
    "gen_${name}"
    replaced=$((replaced + 1))
  else
    printf '%s\n' "$line"
  fi
done < "$TEMPLATE" > "$NEW_README"

[ "$replaced" -gt 0 ] || die "template contains no <!-- GEN:name --> placeholders; nothing was generated"
grep -Eq '^<!-- GEN:[a-z_]+ -->$' "$NEW_README" && die "unreplaced GEN placeholder left in output"
[ "$(wc -c < "$NEW_README")" -gt 1000 ] || die "rendered README is implausibly small; aborting without overwriting"

if [ -f "$README" ] && cmp -s "$NEW_README" "$README"; then
  log "✅ README unchanged ($README)"
else
  mv "$NEW_README" "$README"
  trap - EXIT
  log "✅ README rendered at $README (${replaced} generated blocks)"
fi
