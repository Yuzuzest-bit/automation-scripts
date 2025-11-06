#!/usr/bin/env bash
# collect_open_by_due.sh v2.3
# Windows Git Bash / macOS / Linux
# - front matter(先頭 --- までにある空行・BOM・CRLF)を許容
# - 常にヘッダ＋統計を書き出す（空でも「何件見たか」が分かる）
# - due: YYYY-MM-DD が無ければ 9999-12-31 として末尾送り
# - closed: があれば除外
# - --debug で探索ログ表示

set -euo pipefail

DEBUG=0
if [[ "${1:-}" == "--debug" ]]; then DEBUG=1; shift; fi
ROOT_IN="${1:-.}"
OUT_IN="${2:-dashboards/open_by_due.md}"

log(){ [[ $DEBUG -eq 1 ]] && echo "[DBG]" "$@" >&2 || true; }
die(){ echo "[ERR]" "$@" >&2; exit 1; }

# --- Path normalize ---
ROOT="$ROOT_IN"; OUT="$OUT_IN"
if command -v cygpath >/dev/null 2>&1; then
  [[ "$ROOT" =~ ^[A-Za-z]:[\\/].* ]] && ROOT="$(cygpath -u "$ROOT")"
  d="$(dirname "$OUT")"; [[ "$d" =~ ^[A-Za-z]:[\\/].* ]] && OUT="$(cygpath -u "$OUT")"
fi
fix_leading_slash(){ local p="$1"; [[ "$p" =~ ^[A-Za-z]/ ]] && p="/$p"; echo "$p"; }
ROOT="$(fix_leading_slash "$ROOT")"
OUT="$(fix_leading_slash "$OUT")"

# make OUT dir and pre-create empty file so“必ず存在”する
mkdir -p "$(dirname "$OUT")" || die "cannot mkdir: $(dirname "$OUT")"
: > "$OUT" || die "cannot create OUT: $OUT"

# abspath (after OUT exists)
abspath(){ ( cd "$(dirname "$1")" >/dev/null 2>&1 || exit 1; echo "$(pwd -P)/$(basename "$1")"); }
ROOT="$(abspath "$ROOT")"
OUT="$(abspath "$OUT")"
log "ROOT=$ROOT"; log "OUT=$OUT"

TMP_ROWS="$(mktemp)" || die "mktemp rows failed"
TMP_STAT="$(mktemp)" || die "mktemp stat failed"
trap 'rm -f "$TMP_ROWS" "$TMP_STAT"' EXIT

# --- AWK: front matter parser ---
# 変更点: 先頭の空行をスキップしてから --- を期待
#         BOM/CRLF を除去
parse_awk='
BEGIN{
  infm=0; seen_start=0; has_closed=0
  due=""; id=""; created=""; tags=""; parent=""
  skipped_blank=1
}
{
  sub(/\r$/,"",$0)                        # strip CR
  if (NR==1) sub(/^\xEF\xBB\xBF/,"",$0)  # strip BOM
}
# 先頭の空行は無視
skipped_blank && $0 ~ /^[ \t]*$/ { next }
skipped_blank { skipped_blank=0 }

NR>=1 {
  if (!seen_start) {
    if ($0 ~ /^---[ \t]*$/) { infm=1; seen_start=1; next }
    else { exit } # 先頭付近に front matter 無ければ対象外
  }
}

infm{
  if ($0 ~ /^---[ \t]*$/){ infm=0; next }
  if (match($0, /^([A-Za-z0-9_-]+):[ \t]*/)){
    key=$1; sub(/:.*/,"",key)
    val=$0; sub(/^[A-Za-z0-9_-]+:[ \t]*/,"",val)
    if (key=="closed" && length(val)>0) has_closed=1
    else if (key=="due")     due=val
    else if (key=="id")      id=val
    else if (key=="created") created=val
    else if (key=="tags")    tags=val
    else if (key=="parent")  parent=val
  }
  next
}
# 本文は読まない

END{
  fm=seen_start?1:0
  if (due !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) nd=1; else nd=0
  # 統計行: fm(0/1) closed(0/1) nodue(0/1)
  printf "STAT\tfm=%d\tclosed=%d\tnodue=%d\tfile=%s\n", fm, has_closed?1:0, nd, FILENAME > "'"$TMP_STAT"'"
  if (!has_closed && fm==1) {
    if (nd==1) due="9999-12-31"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", due, FILENAME, id, created, tags, parent
  }
}'

# --- Find ---
FOUND=0
if find "$ROOT" -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune -o -type f -name "*.md" -print0 >/dev/null 2>&1; then
  log "using -print0 pipeline"
  while IFS= read -r -d '' f; do
    ((FOUND++))
    [[ $DEBUG -eq 1 ]] && echo "[DBG] scan:" "$f" >&2
    awk "$parse_awk" "$f" >>"$TMP_ROWS" || true
  done < <(
    find "$ROOT" \
      \( -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune \) -o \
      \( -type f -name "*.md" -print0 \)
  )
else
  log "fallback newline pipeline"
  while IFS= read -r f; do
    ((FOUND++))
    [[ $DEBUG -eq 1 ]] && echo "[DBG] scan:" "$f" >&2
    awk "$parse_awk" "$f" >>"$TMP_ROWS" || true
  done < <(
    find "$ROOT" \
      \( -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune \) -o \
      \( -type f -name "*.md" -print \)
  )
fi

# --- 統計集計 ---
SCANNED="$FOUND"
FM=$(grep -c $'^STAT\tfm=1' "$TMP_STAT" || true)
NOFM=$(grep -c $'^STAT\tfm=0' "$TMP_STAT" || true)
CLOSED=$(grep -c $'^STAT\t.*\tclosed=1' "$TMP_STAT" || true)
NODUE=$(grep -c $'^STAT\t.*\tnodue=1' "$TMP_STAT" || true)

# --- Sort rows ---
if [ -s "$TMP_ROWS" ]; then
  LC_ALL=C sort -t $'\t' -k1,1 "$TMP_ROWS" -o "$TMP_ROWS"
fi

# --- Render (常にヘッダ＋統計を書き出す) ---
{
  printf '# Open Tasks by Due Date\n\n'
  printf '- Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '\n- Root: `%s`\n' "$ROOT"
  printf '- Scanned: %s files (front-matter: %s / no-front-matter: %s, closed: %s, no-due: %s)\n\n' \
    "$SCANNED" "$FM" "$NOFM" "$CLOSED" "$NODUE"

  if [ ! -s "$TMP_ROWS" ]; then
    printf '_No open notes found (all closed or no front matter)._ \n'
  else
    printf '| Due | File | id | created | tags |\n'
    printf '| :-- | :--- | :-- | :------ | :--- |\n'
    while IFS=$'\t' read -r due path id created tags parent; do
      case "$path" in "$ROOT"/*) rp="${path#"$ROOT/"}";; *) rp="$path";; esac
      printf '| %s | [%s](%s) | %s | %s | %s |\n' "$due" "$rp" "$rp" "${id:-}" "${created:-}" "${tags:-}"
    done < "$TMP_ROWS"
  fi
} > "$OUT" || die "cannot write OUT: $OUT"

BYTES=$(wc -c < "$OUT" | tr -d '[:space:]')
echo "[OK] Wrote -> $OUT (size=${BYTES}B)"
[[ $DEBUG -eq 1 ]] && head -n 8 "$OUT" | sed 's/^/[HEAD] /' >&2 || true
