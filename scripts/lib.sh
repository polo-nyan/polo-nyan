# lib.sh — shared helpers for the profile builders (sourced, not executed).
#
# Contract for a builder:
#   STATS_JSON, TEMPLATE, OUT set; `source lib.sh`; define gen_<name> functions;
#   call `render_template`. Every `<!-- GEN:<name> -->` line in TEMPLATE is
#   replaced by the output of gen_<name>; unknown names, leftover placeholders
#   or an implausibly small result abort without touching OUT.
#
# Everything emitted is plain GFM (tables, <details>, unicode bars) so it
# renders identically in GitHub's light and dark themes.

BAR_WIDTH="${BAR_WIDTH:-12}"

log() { printf '%s\n' "$*" >&2; }
die() { log "❌ $*"; exit 1; }

require_tools() {
  command -v jq  >/dev/null 2>&1 || die "jq is required but not installed."
  command -v awk >/dev/null 2>&1 || die "awk is required but not installed."
}

# validate_json FILE KEY... — file must be non-empty, valid JSON, and have KEYs.
validate_json() {
  local f="$1"; shift
  [ -s "$f" ] || die "stats file missing or empty: $f"
  jq empty "$f" >/dev/null 2>&1 || die "stats file is not valid JSON: $f"
  local k
  for k in "$@"; do
    jq -e --arg k "$k" 'has($k) and .[$k] != null' "$f" >/dev/null 2>&1 || die "$f is missing required field '$k'"
  done
}

# sget PATH [DEFAULT] — read a scalar from STATS_JSON; empty/null -> default.
sget() {
  local path="$1" default="${2:-}" val
  val="$(jq -r "${path} // empty" "$STATS_JSON")"
  if [ -z "$val" ] || [ "$val" = "null" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# num N — thousands separator: 11898 -> 11,898 ; 1651.8 -> 1,651.8
num() {
  local s="$1" int frac="" out=""
  case "$s" in *.*) int="${s%%.*}"; frac=".${s#*.}";; *) int="$s";; esac
  [[ "$int" =~ ^-?[0-9]+$ ]] || { printf '%s' "$s"; return; }
  while [ ${#int} -gt 3 ]; do out=",${int: -3}${out}"; int="${int:0:${#int}-3}"; done
  printf '%s%s%s' "$int" "$out" "$frac"
}

# bar VALUE MAX [WIDTH] — "█████░░░░░░░", proportional to VALUE/MAX.
bar() {
  awk -v v="$1" -v m="$2" -v w="${3:-$BAR_WIDTH}" 'BEGIN {
    n = (m > 0) ? int(v * w / m + 0.5) : 0;
    if (n > w) n = w; if (v > 0 && n < 1) n = 1;
    s = ""; for (i = 0; i < n; i++) s = s "█"; for (; i < w; i++) s = s "░";
    printf "%s", s }'
}

# spark "1 5 9 ..." — "▁▂▃▅▇█" scaled to the series maximum.
spark() {
  awk 'BEGIN { split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", lv, " ") }
       { m = 0; for (i = 1; i <= NF; i++) if ($i > m) m = $i;
         for (i = 1; i <= NF; i++) { k = (m > 0) ? int($i * 7 / m + 0.5) + 1 : 1; printf "%s", lv[k] } }' <<<"$1"
}

# render_template — assemble OUT from TEMPLATE using gen_<name> functions.
render_template() {
  [ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
  local tmp replaced=0 line name
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^\<!--\ GEN:([a-z_]+)\ --\>$ ]]; then
      name="${BASH_REMATCH[1]}"
      declare -F "gen_${name}" >/dev/null || die "template references unknown block GEN:${name}"
      "gen_${name}"
      replaced=$((replaced + 1))
    else
      printf '%s\n' "$line"
    fi
  done < "$TEMPLATE" > "$tmp"
  [ "$replaced" -gt 0 ] || die "template contains no GEN placeholders; nothing was generated"
  grep -Eq '^<!-- GEN:[a-z_]+ -->$' "$tmp" && die "unreplaced GEN placeholder left in output"
  [ "$(wc -c < "$tmp")" -gt 1000 ] || die "rendered output is implausibly small; aborting without overwriting"
  if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
    log "✅ unchanged: $OUT"
  else
    mv "$tmp" "$OUT"
    log "✅ rendered $OUT (${replaced} generated blocks)"
  fi
  trap - EXIT
}
