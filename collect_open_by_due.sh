#!/usr/bin/env bash
# md_open_due_list.sh v3.4-rootbase (safe)
# - 出力: スクリプトと同じ場所 open_due.md（固定）
# - 引数: ROOT だけ（省略時は $PWD）
# - リンク: ★ ROOT 基準（$PWD ではない）
# - 箇条書き出力 / front matter 先頭30行 / closed除外 / due無→9999-12-31
# - .md/.markdown/.mkd/.mdx（大小OK）、CRLF/BOM対応
# - プロセス置換なし・外部アプリ起動なし

set -eu
set -o pipefail

ROOT_IN="${1:-$PWD}"   # 検索対象（省略時=カレント）

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
OUT="$HERE/open_due.md"

ROOT="$ROOT_IN"
if command -v cygpath >/dev/null 2>&1; then
  case "$ROOT" in [A-Za-z]:/*|[A-Za-z]:\\*) ROOT="$(cygpath -u "$ROOT")";; esac
fi
case "$ROOT" in [A-Za-z]/*) ROOT="/$ROOT";; esac

[ -d "$ROOT" ] || { echo "[ERR] ROOT not found: $ROOT" >&2; exit 1; }
mkdir -p "$HERE" || { echo "[ERR] cannot mkdir: $HERE" >&2; exit 1; }

abspath(){ ( cd "$(dirname "$1")" >/dev/null 2>&1 || exit 1; printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" ); }
relpath_from_base(){
  local ABS_TARGET="$1" BASE="$2"
  ABS_TARGET="${ABS_TARGET%/}"; BASE="${BASE%/}"
  case "$ABS_TARGET" in /*) :;; *) ABS_TARGET="$(abspath "$ABS_TARGET")";; esac
  case "$BASE" in /*) :;; *) BASE="$(abspath "$BASE")";; esac
  [[ "${ABS_TARGET%%/*}" != "${BASE%%/*}" ]] && { echo "$ABS_TARGET"; return; }
  local IFS='/'; read -r -a T <<<"$ABS_TARGET"; read -r -a B <<<"$BASE"
  local i=0; while [[ $i -lt ${#T[@]} && $i -lt ${#B[@]} && "${T[$i]}" == "${B[$i]}" ]]; do ((i++)); done
  local up=""; for ((j=i;j<${#B[@]};j++)); do [[ -n "${B[$j]}" ]] && up+="../"; done
  local down=""; for ((j=i;j<${#T[@]};j++)); do [[ -n "${T[$j]}" ]] && down+="${down:+/}${T[$j]}"; done
  printf '%s\n' "${up}${down:-.}"
}

# ★ ここが唯一の変更点：リンク基準は ROOT に固定
BASE_DIR="$ROOT"

{
  echo "# Open Tasks by Due Date"
  echo
  echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
  echo "- Root: \`$ROOT\`"
  echo "- Link base: \`$BASE_DIR\`"
} > "$OUT" || { echo "[ERR] cannot write OUT: $OUT" >&2; exit 1; }

TMP="${OUT}.rows.$$"
FLIST="${OUT}.list.$$"
: > "$TMP"; : > "$FLIST"
trap 'rm -f "$TMP" "$FLIST"' EXIT

md_predicate=( \( -iname '*.md' -o -iname '*.markdown' -o -iname '*.mkd' -o -iname '*.mdx' \) )
prune=( -type d \( -name .git -o -name node_modules -o -name .obsidian \) -prune )
prune_out=( -path "$OUT" -prune )

TOTAL_FILES=$(find "$ROOT" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
MATCH_MD=$(find "$ROOT" \( "${prune[@]}" -o "${prune_out[@]}" \) -o \( -type f "${md_predicate[@]}" -print \) 2>/dev/null | wc -l | tr -d '[:space:]')

find "$ROOT" \( "${prune[@]}" -o "${prune_out[@]}" \) -o \( -type f "${md_predicate[@]}" -print0 \) > "$FLIST" 2>/dev/null

scan_file(){
  awk '
    BEGIN { RS="\n"; started=0; ended=0; has_closed=0; due=""; max_seek=30 }
    { sub(/\r$/,"") }
    NR==1 { sub(/^\xEF\xBB\xBF/,"") }
    NR<=max_seek && started==0 {
      if ($0 ~ /^---[ \t]*$/) { started=1; next } else { next }
    }
    started && !ended {
      if ($0 ~ /^---[ \t]*$/) { ended=1; next }
      if (match($0, /^[ \t]*([A-Za-z0-9_-]+):[ \t]*(.*)$/, m)) {
        k=m[1]; v=m[2]
        gsub(/^["\047]/,"",v); gsub(/["\047]$/,"",v)
        if (k=="closed" && length(v)>0) has_closed=1
        else if (k=="due" && length(v)>0) {
          if (match(v, /[0-9]{4}-[0-9]{2}-[0-9]{2}/))      due=substr(v,RSTART,RLENGTH)
          else if (match(v, /[0-9]{4}\/[0-9]{2}\/[0-9]{2}/)) { d=substr(v,RSTART,RLENGTH); gsub(/\//,"-",d); due=d }
        }
      }
      next
    }
    END {
      if (started==1 && has_closed==0) {
        if (due=="") due="9999-12-31"
        printf "%s\t%s\n", due, FILENAME
      }
    }
  ' "$1" >> "$TMP" || true
}

COUNT=0
while IFS= read -r -d '' F <&3; do
  COUNT=$((COUNT+1))
  scan_file "$F"
done 3<"$FLIST"

if [ -s "$TMP" ]; then
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 "$TMP" -o "$TMP"
fi

{
  echo "- Scanned (all files under root): ${TOTAL_FILES}"
  echo "- Matched markdown files: ${MATCH_MD}"
  echo "- Parsed markdown files (after prune): ${COUNT}"
  echo
  if [ ! -s "$TMP" ]; then
    echo "_No open notes found (all closed or no front matter)._"
  else
    while IFS=$'\t' read -r D ABS; do
      REL="$(relpath_from_base "$ABS" "$BASE_DIR")"
      printf -- "- %s  [%s](%s)\n" "$D" "$REL" "$REL"
    done < "$TMP"
  fi
} >> "$OUT"

exit 0
