#!/usr/bin/env bash
#
# build-ai-stats.sh — render AI-STATS.md from the template + ai-stats.json.
#
# Same engine as build-readme.sh (scripts/lib.sh): deterministic, idempotent,
# fails loudly on bad input, plain GFM only so it reads in both GitHub themes.
#
# Usage: scripts/build-ai-stats.sh [AI_STATS_JSON] [OUT] [TEMPLATE]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STATS_JSON="${1:-${REPO_ROOT}/ai-stats.json}"
OUT="${2:-${REPO_ROOT}/AI-STATS.md}"
TEMPLATE="${3:-${SCRIPT_DIR}/templates/AI-STATS.template.md}"
BAR_WIDTH=20
CI_MIN_N=30   # minimum checked PRs per group before a CI pass rate is shown
CHART_DIR="${REPO_ROOT}/assets/charts"
mkdir -p "$CHART_DIR"
# The profile repo is a stats artifact, not a project; it stays in the totals but is not named.
SELF_REPO="${SELF_REPO:-polo-nyan}"

# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_tools
validate_json "$STATS_JSON" generatedAt window totals monthly weekly repos prs lines
jq -e '.totals.commits > 0' "$STATS_JSON" >/dev/null 2>&1 || die "ai-stats.json has 0 commits; refusing to render"
jq -e '(.monthly | length) > 0' "$STATS_JSON" >/dev/null 2>&1 || die "ai-stats.json has no monthly series"

# hours -> "14h" / "2.5 d"
fmt_hours() {
  awk -v h="$1" 'BEGIN { if (h == "" || h == "null") printf "—"; else if (h < 1) printf "%d min", h*60+0.5; else if (h < 48) printf "%.1f h", h; else printf "%.1f d", h/24 }'
}

gen_headline() {
  local c a s add del since until repos
  c="$(sget .totals.commits 0)"; a="$(sget .totals.ai 0)"; s="$(sget .totals.share 0)"
  add="$(sget .totals.additions 0)"; del="$(sget .totals.deletions 0)"
  since="$(sget .window.since)"; until="$(sget .window.until)"; repos="$(sget .reposWithCommits 0)"
  cat <<EOF
| AI-assisted share | Commits scanned | Repositories | Lines added / removed |
|:--:|:--:|:--:|:--:|
| **${s}%** <sub>$(num "$a") of $(num "$c") commits</sub> | **$(num "$c")** <sub>${since} → ${until}</sub> | **${repos}** <sub>with commits in the window</sub> | **+$(num "$add")** / **−$(num "$del")** |
EOF
}

gen_monthly() {
  local rows
  # Bars run pink -> violet with the share so the chart reads at a glance.
  jq -r '.monthly[-12:][] | "\(.period)\t\(.share)\t\(.share)% · \(.ai) of \(.commits)\t" + (if .share >= 75 then "#8b5cf6" elif .share >= 40 then "#c084fc" else "#f472b6" end)' "$STATS_JSON" \
    | svg_barchart "${CHART_DIR}/ai-share" 100
  rows="$(jq -r '.monthly[-12:][] | "| \(.period) | \(.share)% | \(.ai) / \(.commits) |"' "$STATS_JSON")"
  cat <<EOF
Share of my commits per month that carry an AI co-author trailer (bars span 0–100 %).

$(picture_block "assets/charts/ai-share" "AI-assisted share of commits per month")

<details>
<summary>As a table</summary>

| Month | Share | AI / all commits |
|:--|--:|--:|
${rows}

</details>
EOF
}

gen_weekly() {
  local n shares vols first last
  n="$(jq -r '.weekly | length' "$STATS_JSON")"
  [ "$n" -gt 1 ] || return 0
  shares="$(jq -r '.weekly[-26:] | map(.share | tostring) | join(" ")' "$STATS_JSON")"
  vols="$(jq -r '.weekly[-26:] | map(.commits | tostring) | join(" ")' "$STATS_JSON")"
  first="$(jq -r '.weekly[-26:][0].period' "$STATS_JSON")"; last="$(jq -r '.weekly[-1].period' "$STATS_JSON")"
  local rows
  rows="$(jq -r '.weekly[-26:][] | "| \(.period) | \(.ai) / \(.commits) | \(.share)% |"' "$STATS_JSON")"
  cat <<EOF
<details>
<summary>Weekly view (last 26 ISO weeks, ${first} → ${last})</summary>

\`\`\`
AI share   $(spark "$shares")
commits    $(spark "$vols")
\`\`\`

| Week | AI / all | Share |
|:--|--:|--:|
${rows}

</details>
EOF
}

gen_repos() {
  local rows priv_n priv_c priv_a priv_s
  rows="$(jq -r --arg self "$SELF_REPO" '.repos.public[] | select(.name != $self) | "\(.name)\t\(.owner)\t\(.url)\t\(.commits)\t\(.ai)\t\(.share)"' "$STATS_JSON" \
    | while IFS=$'\t' read -r name owner url c a s; do
        printf '| [%s](%s) <sub>%s</sub> | `%s` | %s%% | %s / %s |\n' "$name" "$url" "$owner" "$(bar "$s" 100)" "$s" "$(num "$a")" "$(num "$c")"
      done)"
  priv_n="$(sget .repos.private.repos 0)"; priv_c="$(sget .repos.private.commits 0)"; priv_a="$(sget .repos.private.ai 0)"; priv_s="$(sget .repos.private.share 0)"
  cat <<EOF
Public repositories by name, ordered by commits in the window. Private, forked and archived repositories (and this profile repo) are rolled up into one row.

| Repository | Share | | AI / all commits |
|:--|:--|--:|--:|
${rows}
| *${priv_n} private / other repos* | \`$(bar "$priv_s" 100)\` | ${priv_s}% | $(num "$priv_a") / $(num "$priv_c") |
EOF
}

gen_prs() {
  local sampled cap trunc
  sampled="$(sget .prs.sampled 0)"; cap="$(sget .prs.perRepoCap 0)"; trunc="$(sget .prs.truncatedCommitLists 0)"
  [ "$sampled" -gt 0 ] || { printf '_No merged pull requests in the window._\n'; return 0; }
  local g; local -A v
  for g in ai human; do
    v[$g.count]="$(sget ".prs.$g.count" 0)"; v[$g.med]="$(sget ".prs.$g.medianMergeHours" null)"; v[$g.mean]="$(sget ".prs.$g.meanMergeHours" null)"
    v[$g.mc]="$(sget ".prs.$g.medianCommits" 0)"; v[$g.ml]="$(sget ".prs.$g.medianLinesChanged" 0)"
    v[$g.ci]="$(sget ".prs.$g.ciPassRate" 0)"; v[$g.cic]="$(sget ".prs.$g.ciChecked" 0)"; v[$g.cip]="$(sget ".prs.$g.ciPassed" 0)"
  done
  cat <<EOF
$(num "$sampled") merged pull requests sampled (up to ${cap} most recent per repository, bot authors excluded). A PR counts as "with AI" when at least one of its commits is AI-assisted.

| | With AI commits | Without AI commits |
|:--|--:|--:|
| Pull requests | **$(num "${v[ai.count]}")** | **$(num "${v[human.count]}")** |
| Median time to merge | **$(fmt_hours "${v[ai.med]}")** | **$(fmt_hours "${v[human.med]}")** |
| Mean time to merge | $(fmt_hours "${v[ai.mean]}") | $(fmt_hours "${v[human.mean]}") |
| Median commits per PR | ${v[ai.mc]} | ${v[human.mc]} |
| Median lines changed per PR | $(num "${v[ai.ml]}") | $(num "${v[human.ml]}") |
EOF
  # CI pass rate only when both groups have enough checked PRs to mean anything,
  # always with n, never as a causal claim.
  if [ "${v[ai.cic]}" -ge "$CI_MIN_N" ] && [ "${v[human.cic]}" -ge "$CI_MIN_N" ]; then
    cat <<EOF
| CI pass rate of the head commit | ${v[ai.ci]}% <sub>n = $(num "${v[ai.cic]}")</sub> | ${v[human.ci]}% <sub>n = $(num "${v[human.cic]}")</sub> |

<sub>CI pass rates describe different kinds of PRs (small manual fixes vs assisted feature work), not an effect of AI use; failures include infrastructure noise.</sub>
EOF
  else
    printf '\n<sub>CI pass rate not shown: fewer than %s PRs with checks in one of the groups.</sub>\n' "$CI_MIN_N"
  fi
  if [ "$trunc" -gt 0 ]; then
    printf '\n<sub>%s PRs had more commits than the per-PR scan limit; only their first commits were inspected for trailers.</sub>\n' "$trunc"
  fi
}

gen_lines() {
  local -A v; local g
  for g in ai human; do
    v[$g.c]="$(sget ".lines.$g.commits" 0)"; v[$g.a]="$(sget ".lines.$g.additions" 0)"; v[$g.d]="$(sget ".lines.$g.deletions" 0)"; v[$g.pc]="$(sget ".lines.$g.perCommit" 0)"
  done
  local max rows
  max="$(jq -r '[.monthly[-12:][] | (.additions + .deletions)] | max // 0' "$STATS_JSON")"
  rows="$(jq -r '.monthly[-12:][] | "\(.period)\t\(.aiAdditions + .aiDeletions)\t\(.additions + .deletions)"' "$STATS_JSON" \
    | while IFS=$'\t' read -r p ai all; do
        printf '| %s | `%s` | %s | %s |\n' "$p" "$(bar "$ai" "$max")" "$(num "$ai")" "$(num "$all")"
      done)"
  cat <<EOF
| | AI-assisted commits | Human-only commits |
|:--|--:|--:|
| Commits | $(num "${v[ai.c]}") | $(num "${v[human.c]}") |
| Lines added | +$(num "${v[ai.a]}") | +$(num "${v[human.a]}") |
| Lines removed | −$(num "${v[ai.d]}") | −$(num "${v[human.d]}") |
| Lines changed per commit | **$(num "${v[ai.pc]}")** | **$(num "${v[human.pc]}")** |

<details>
<summary>Lines changed per month (bar = AI-assisted share of the month's volume, scaled to the busiest month)</summary>

| Month | | AI-assisted lines | All lines |
|:--|:--|--:|--:|
${rows}

</details>
EOF
}

gen_updated() {
  printf '<sub>Last updated %s.</sub>\n' "$(sget .generatedAt "$(date -u +%Y-%m-%d)")"
}

render_template
