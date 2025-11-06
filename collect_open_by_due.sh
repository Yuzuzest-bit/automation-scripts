#!/usr/bin/env bash
# collect_open_by_due.sh (Windows Git Bash / macOS / Linux)
# - front matter先頭〜次の "---" のみ解析
# - closed: が無いファイルを due: 昇順で集計
# - CRLF/BOM/末尾空白/後ろに空白を含む"---" に対応
# - --debug で詳細ログ

set -euo pipefail

DEBUG=0
if [[ "${1:-}" == "--debug" ]]; then DEBUG=1; shift; fi

ROOT_IN="${1:-.}"
OUT_IN="${2:-dashboards/open_by_due.md}"

log(){ [[ $DEBUG -eq 1 ]] && echo "[DBG]" "$@" >&2 || true; }
die(){ echo "[ERR]" "$@" >&2; exit 1; }

# Windowsパス→POSIX（Git Bash/cygwin想定）
ROOT="$ROOT_IN"; OUT="$OUT_IN"
if command -v cygpath >/dev/null 2>&1; then
  [[ "$ROOT" =~ ^[A-Za-z]:[\\/].* ]] && ROOT="$(cygpath -u "$ROOT")"
  d="$(dirname "$OUT")"; [[ "$d" =~ ^[A-Za-z]:[\\/].* ]] && OUT="$(cygpath -u "$OUT")"
fi

abspath(){ ( cd "$(dirname "$1")" >/dev/null 2>&1 || exit 1; echo "$(pwd -P)/$(basename "$1")"); }
ROOT="$(abspath "$ROOT")"
OUT="$(abspath "$OUT")"
log "ROOT=$ROOT"; log "OUT=$OUT"

mkdir -p "$(dirname "$OUT")" || die "cannot mkdir: $(dirname "$OUT")"

TMP="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$TMP"' EXIT

parse_awk='
BEGIN{
  infm=0; seen_start=0; has_closed=0
  due=""; id=""; created=""; tags=""; parent=""
}
{
  sub(/\r$/,"",$0)                         # strip CR (CRLF)
  if (NR==1) sub(/^\xEF\xBB\xBF/,"",$0)   # strip UTF-8 BOM
}
NR==1{
  if ($0 ~ /^---[ \t]*$/){infm=1; seen_start=1; next}
  else {exit} # no front matter at top -> ignore
}
infm{
  if ($0 ~ /^---[ \t]*$/){infm=0; next}
  if (match($0, /^([A-Za-z0-9_-]+):[ \t]*/)){
    key=$1; sub(/:.*/, "", key)
    val=$0; sub(/^[A-Za-z0-9_-]+:[ \t]*/, "", val)
    if (key=="closed" && length(val)>0) has_closed=1
    else if (key=="due") due=val
    else if (key=="id") id=val
    else if (key=="created") created=val
    else if (key=="tags") tags=val
    else if (key=="parent") parent=val
  }
  next
}
!infm && seen_start { ; }    # ignore body
END{
  if (has_closed) exit
  if (due !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) due="9999-12-31"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n", due, FILENAME, id, created, tags, parent
}'

# --- 探索（null区切り優先、失敗時フォールバック） ---
FOUND=0
if find "$ROOT" -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune -o \
     -type f -name "*.md" -print0 >/dev/null 2>&1; then
  log "using -print0 pipeline"
  while IFS= read -r -d '' f; do
    ((FOUND++))
    [[ $DEBUG -eq 1 ]] && echo "[DBG] scan:" "$f" >&2
    awk "$parse_awk" "$f" >>"$TMP" || true
  done < <(
    find "$ROOT" \
      \( -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune \) -o \
      \( -type f -name "*.md" -print0 \)
  )
else
  log "fallback to newline-delimited find"
  while IFS= read -r f; do
    ((FOUND++))
    [[ $DEBUG -eq 1 ]] && echo "[DBG] scan:" "$f" >&2
    awk "$parse_awk" "$f" >>"$TMP" || true
  done < <(
    find "$ROOT" \
      \( -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune \) -o \
      \( -type f -name "*.md" -print \)
  )
fi
log "FOUND files=" "$FOUND"

# sort
if [ -s "$TMP" ]; then
  LC_ALL=C sort -t $'\t' -k1,1 "$TMP" -o "$TMP"
fi

relpath(){ case "$1" in "$ROOT"/*) printf '%s\n' "${1#"$ROOT/"}";; *) printf '%s\n' "$1";; esac; }

{
  printf '# Open Tasks by Due Date\n\n'
  printf '- Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '\n- Root: `%s`\n\n' "$ROOT"

  if [ ! -s "$TMP" ]; then
    printf '_No open notes found (all closed or no front matter)._ \n'
    exit 0
  fi

  printf '| Due | File | id | created | tags |\n'
  printf '| :-- | :--- | :-- | :------ | :--- |\n'
  while IFS=$'\t' read -r due path id created tags parent; do
    rp="$(relpath "$path")"
    printf '| %s | [%s](%s) | %s | %s | %s |\n' "$due" "$rp" "$rp" "${id:-}" "${created:-}" "${tags:-}"
  done < "$TMP"
} > "$OUT"

echo "[OK] Wrote -> $OUT"
[[ $DEBUG -eq 1 ]] && echo "[DBG] rows=$(wc -l < "$TMP") (after sort, before render)" >&2 || true
