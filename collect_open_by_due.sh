#!/usr/bin/env bash
# collect_open_by_due.sh v2.2
# Windows Git Bash / macOS / Linux
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
abspath(){ ( cd "$(dirname "$1")" >/dev/null 2>&1 || exit 1; echo "$(pwd -P)/$(basename "$1")"); }
mkdir -p "$(dirname "$OUT")" || die "cannot mkdir: $(dirname "$OUT")"
: > "$OUT" || die "cannot create OUT: $OUT"   # ここで“必ず”作る
ROOT="$(abspath "$ROOT")"
OUT="$(abspath "$OUT")"
log "ROOT=$ROOT"; log "OUT=$OUT"

TMP="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$TMP"' EXIT

parse_awk='
BEGIN{infm=0;seen_start=0;has_closed=0;due="";id="";created="";tags="";parent=""}
{ sub(/\r$/,"",$0); if(NR==1) sub(/^\xEF\xBB\xBF/,"",$0) }
NR==1{ if($0~/^---[ \t]*$/){infm=1;seen_start=1;next}else exit }
infm{
  if($0~/^---[ \t]*$/){infm=0;next}
  if(match($0,/^([A-Za-z0-9_-]+):[ \t]*/)){
    k=$1; sub(/:.*/,"",k); v=$0; sub(/^[A-Za-z0-9_-]+:[ \t]*/,"",v)
    if(k=="closed" && length(v)>0) has_closed=1
    else if(k=="due") due=v
    else if(k=="id") id=v
    else if(k=="created") created=v
    else if(k=="tags") tags=v
    else if(k=="parent") parent=v
  }
  next
}
END{
  if(has_closed) exit
  if(due !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) due="9999-12-31"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n", due, FILENAME, id, created, tags, parent
}'

# --- Find ---
FOUND=0
PIPE_OK=1
if ! find "$ROOT" -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune -o -type f -name "*.md" -print0 >/dev/null 2>&1; then
  PIPE_OK=0
fi
if [[ $PIPE_OK -eq 1 ]]; then
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
  log "fallback newline pipeline"
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
echo "[INFO] scanned_md_files=$FOUND"

# --- Sort ---
if [ -s "$TMP" ]; then
  LC_ALL=C sort -t $'\t' -k1,1 "$TMP" -o "$TMP"
fi

# --- Render ---
{
  printf '# Open Tasks by Due Date\n\n'
  printf '- Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '\n- Root: `%s`\n\n' "$ROOT"
  if [ ! -s "$TMP" ]; then
    printf '_No open notes found (all closed or no front matter)._ \n'
  else
    printf '| Due | File | id | created | tags |\n'
    printf '| :-- | :--- | :-- | :------ | :--- |\n'
    while IFS=$'\t' read -r due path id created tags parent; do
      case "$path" in "$ROOT"/*) rp="${path#"$ROOT/"}";; *) rp="$path";; esac
      printf '| %s | [%s](%s) | %s | %s | %s |\n' "$due" "$rp" "$rp" "${id:-}" "${created:-}" "${tags:-}"
    done < "$TMP"
  fi
} > "$OUT" || die "cannot write OUT: $OUT"

# 追跡しやすいように、最終サイズと先頭数行を表示
BYTES=$(wc -c < "$OUT" | tr -d '[:space:]')
echo "[OK] Wrote -> $OUT (size=${BYTES}B)"
head -n 5 "$OUT" | sed 's/^/[HEAD] /' >&2
