#!/usr/bin/env bash
# md_open_due_list.sh v3.2
# - 出力ファイルはスクリプトと同じ場所: open_due.md
# - 引数は ROOT のみ（省略時はカレント）
# - 出力は箇条書き、リンクは実行時の $PWD からの相対
# - front matter: 先頭30行の最初の ---〜次の--- を解析
# - closed: あり→除外 / due: 無し→9999-12-31
# - .md/.markdown/.mkd/.mdx（大小文字OK）、CRLF/BOM対応
# - Windows Git Bash / macOS / Linux

set -u
set -o pipefail

ROOT_IN="${1:-$PWD}"          # 検索対象（省略時=カレント）
AUTO_OPEN="${AUTO_OPEN:-1}"   # 0で自動オープン無効

# --- スクリプト自身の場所 & 出力先 ---
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
OUT_NAME="open_due.md"
OUT="$HERE/$OUT_NAME"

# --- パス正規化（Git Bash on Windows 対応） ---
ROOT="$ROOT_IN"
if command -v cygpath >/dev/null 2>&1; then
  case "$ROOT" in [A-Za-z]:/*|[A-Za-z]:\\*) ROOT="$(cygpath -u "$ROOT")";; esac
fi
case "$ROOT" in [A-Za-z]/*) ROOT="/$ROOT";; esac

# --- 基本チェック ---
[ -d "$ROOT" ] || { echo "[ERR] ROOT not found: $ROOT" >&2; exit 1; }
mkdir -p "$HERE" || { echo "[ERR] cannot mkdir: $HERE" >&2; exit 1; }

# --- 相対パス計算（リンクは実行時カレント基準） ---
abspath() { ( cd "$(dirname "$1")" >/dev/null 2>&1 || exit 1; printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" ); }
relpath_from_base() {
  local ABS_TARGET="$1"; local BASE="$2"
  ABS_TARGET="${ABS_TARGET%/}"; BASE="${BASE%/}"
  case "$ABS_TARGET" in /*) :;; *) ABS_TARGET="$(abspath "$ABS_TARGET")";; esac
  case "$BASE" in /*) :;; *) BASE="$(abspath "$BASE")";; esac
  # /c と /d のようにボリュームが違う場合は絶対で返す
  [[ "${ABS_TARGET%%/*}" != "${BASE%%/*}" ]] && { echo "$ABS_TARGET"; return; }
  local IFS='/'; read -r -a T <<<"$ABS_TARGET"; read -r -a B <<<"$BASE"
  local i=0; while [[ $i -lt ${#T[@]} && $i -lt ${#B[@]} && "${T[$i]}" == "${B[$i]}" ]]; do ((i++)); done
  local up=""; for ((j=i;j<${#B[@]};j++)); do [[ -n "${B[$j]}" ]] && up+="../"; done
  local down=""; for ((j=i;j<${#T[@]};j++)); do [[ -n "${T[$j]}" ]] && down+="${down:+/}${T[$j]}"; done
  printf '%s\n' "${up}${down:-.}"
}

BASE_DIR="$PWD"

# --- 先にヘッダ（常に内容を残す） ---
{
  echo "# Open Tasks by Due Date"
  echo
  echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
  echo "- Root: \`$ROOT\`"
  echo "- Link base: \`$BASE_DIR\`"
} > "$OUT" || { echo "[ERR] cannot write OUT: $OUT" >&2; exit 1; }

TMP="${OUT}.rows.$$"
: > "$TMP" || { echo "[ERR] cannot create tmp: $TMP" >&2; exit 1; }

# --- 探索条件（拡張子網羅 & 自ファイル除外） ---
md_predicate=( \( -iname '*.md' -o -iname '*.markdown' -o -iname '*.mkd' -o -iname '*.mdx' \) )
prune=( -type d \( -name .git -o -name node_modules -o -name .obsidian \) -prune )
# 自分が出力する open_due.md はスキャン対象から除外
prune_out=( -path "$OUT" -prune )

TOTAL_FILES=$(find "$ROOT" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
MATCH_MD=$(find "$ROOT" \( "${prune[@]}" -o "${prune_out[@]}" \) -o \( -type f "${md_predicate[@]}" -print \) 2>/dev/null | wc -l | tr -d '[:space:]')

# --- 1ファイル解析 ---
scan_file() {
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

# --- 収集（-print0 優先。自ファイル除外付き） ---
COUNT=0
if find "$ROOT" \( "${prune[@]}" -o "${prune_out[@]}" \) -o \( -type f "${md_predicate[@]}" -print0 \) >/dev/null 2>&1; then
  while IFS= read -r -d '' F; do COUNT=$((COUNT+1)); scan_file "$F"; done < <(
    find "$ROOT" \( "${prune[@]}" -o "${prune_out[@]}" \) -o \( -type f "${md_predicate[@]}" -print0 \)
  )
else
  while IFS= read -r F; do COUNT=$((COUNT+1)); scan_file "$F"; done < <(
    find "$ROOT" \( "${prune[@]}" -o "${prune_out[@]}" \) -o \( -type f "${md_predicate[@]}" -print \)
  )
fi

# --- 並べ替え ---
if [ -s "$TMP" ]; then
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 "$TMP" -o "$TMP"
fi

# --- 箇条書きで追記（リンクは $PWD からの相対） ---
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

rm -f "$TMP"

# --- 自動で開く ---
if [ "$AUTO_OPEN" = "1" ]; then
  if command -v cygpath >/dev/null 2>&1; then
    WIN="$(cygpath -w "$OUT")"
    cmd.exe /C start "" "$WIN" >/dev/null 2>&1 || explorer.exe "$WIN" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "$OUT" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$OUT" >/dev/null 2>&1 || true
  fi
fi

echo "[OK] wrote -> $OUT"
