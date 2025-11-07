#!/usr/bin/env bash
# md_open_due_list.sh v3.0
# - カレントディレクトリ（$PWD）からの相対リンクでMarkdownを出力
# - 出力は表ではなく箇条書き
# - front matter: 先頭30行以内の最初の ---〜次の--- を解析
# - closed: あり→除外 / due: 無し→9999-12-31
# - .md/.markdown/.mkd/.mdx（大小文字OK）、CRLF/BOM対応
# - Windows Git Bash / macOS / Linux

set -u
set -o pipefail

ROOT_IN="${1:-.}"                 # 検索対象
OUT_IN="${2:-open_by_due.md}"     # 出力先（ディレクトリ指定も可）

# --- パス正規化（Git Bash on Windows対応） ---
ROOT="$ROOT_IN"; OUT="$OUT_IN"
if command -v cygpath >/dev/null 2>&1; then
  case "$ROOT" in [A-Za-z]:/*|[A-Za-z]:\\*) ROOT="$(cygpath -u "$ROOT")";; esac
  case "$OUT"  in [A-Za-z]:/*|[A-Za-z]:\\*) OUT="$(cygpath -u "$OUT")";;  esac
fi
case "$ROOT" in [A-Za-z]/*) ROOT="/$ROOT";; esac
case "$OUT"  in [A-Za-z]/*) OUT="/$OUT";;  esac

# OUT がディレクトリなら既定名を付ける
if [ -d "$OUT" ] || [[ "$OUT" == */ ]]; then
  OUT="${OUT%/}/open_by_due.md"
fi

# 便利関数：絶対パス化
abspath() { ( cd "$(dirname "$1")" >/dev/null 2>&1 || exit 1; printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" ); }

# 相対パス計算（ABS_TARGET を BASE からの相対に）
relpath_from_base() {
  local ABS_TARGET="$1"; local BASE="$2"
  # パス末尾のスラッシュ除去
  ABS_TARGET="${ABS_TARGET%/}"; BASE="${BASE%/}"
  # どちらも絶対に
  case "$ABS_TARGET" in /*) :;; *) ABS_TARGET="$(abspath "$ABS_TARGET")";; esac
  case "$BASE" in /*) :;; *) BASE="$(abspath "$BASE")";; esac

  # 別ボリューム（例：/c と /d）の場合は相対にできないので絶対を返す
  case "$ABS_TARGET" in /*) :;; *) echo "$ABS_TARGET"; return;; esac
  case "$BASE" in /*) :;; *) echo "$ABS_TARGET"; return;; esac
  if [[ "${ABS_TARGET%%/*}" != "${BASE%%/*}" ]]; then
    echo "$ABS_TARGET"; return
  fi

  local IFS='/'
  read -r -a T_ARR <<< "$ABS_TARGET"
  read -r -a B_ARR <<< "$BASE"

  # 共有プレフィクスの長さ
  local i=0
  while [[ $i -lt ${#T_ARR[@]} && $i -lt ${#B_ARR[@]} && "${T_ARR[$i]}" == "${B_ARR[$i]}" ]]; do
    ((i++))
  done

  local UP=""
  local j=$i
  while [[ $j -lt ${#B_ARR[@]} ]]; do
    [[ -n "${B_ARR[$j]}" ]] && UP+="../"
    ((j++))
  done

  local DOWN=""
  j=$i
  while [[ $j -lt ${#T_ARR[@]} ]]; do
    if [[ -n "$DOWN" ]]; then DOWN+="/${T_ARR[$j]}"; else DOWN="${T_ARR[$j]}"; fi
    ((j++))
  done

  local RES="${UP}${DOWN}"
  [[ -z "$RES" ]] && RES="."
  printf '%s\n' "$RES"
}

# 基準ディレクトリ（相対リンクの起点）＝実行時のカレント
BASE_DIR="$PWD"

# ルート存在チェックと出力ディレクトリ作成
[ -d "$ROOT" ] || { echo "[ERR] ROOT not found: $ROOT" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")" || { echo "[ERR] cannot mkdir: $(dirname "$OUT")" >&2; exit 1; }

# 先にヘッダ（必ず何か書く）
{
  echo "# Open Tasks by Due Date"
  echo
  echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
  echo "- Root: \`$ROOT\`"
  echo "- Link base: \`$BASE_DIR\`"
} > "$OUT" || { echo "[ERR] cannot write OUT header: $OUT" >&2; exit 1; }

TMP="${OUT}.rows.$$"
: > "$TMP" || { echo "[ERR] cannot create tmp: $TMP" >&2; exit 1; }

# --- 探索条件 ---
md_predicate=( \( -iname '*.md' -o -iname '*.markdown' -o -iname '*.mkd' -o -iname '*.mdx' \) )
prune_dirs=( -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune )

TOTAL_FILES=$(find "$ROOT" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
MATCH_MD=$(find "$ROOT" \( "${prune_dirs[@]}" \) -o \( -type f "${md_predicate[@]}" -print \) 2>/dev/null | wc -l | tr -d '[:space:]')

# 1ファイル解析（front matter先頭30行）
scan_file() {
  awk '
    BEGIN { RS="\n"; started=0; ended=0; has_closed=0; due=""; max_seek=30 }
    { sub(/\r$/,"") }                     # CRLF
    NR==1 { sub(/^\xEF\xBB\xBF/,"") }     # BOM
    NR<=max_seek && started==0 {
      if ($0 ~ /^---[ \t]*$/) { started=1; next } else { next }
    }
    started && !ended {
      if ($0 ~ /^---[ \t]*$/) { ended=1; next }
      if (match($0, /^[ \t]*([A-Za-z0-9_-]+):[ \t]*(.*)$/, m)) {
        k=m[1]; v=m[2]
        gsub(/^["\047]/,"",v); gsub(/["\047]$/,"",v)   # ← ここで¥エスケープ警告は出ません
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

# 収集（-print0 優先）
COUNT=0
if find "$ROOT" \( "${prune_dirs[@]}" \) -o \( -type f "${md_predicate[@]}" -print0 \) >/dev/null 2>&1; then
  while IFS= read -r -d '' F; do COUNT=$((COUNT+1)); scan_file "$F"; done < <(
    find "$ROOT" \( "${prune_dirs[@]}" \) -o \( -type f "${md_predicate[@]}" -print0 \)
  )
else
  while IFS= read -r F; do COUNT=$((COUNT+1)); scan_file "$F"; done < <(
    find "$ROOT" \( "${prune_dirs[@]}" \) -o \( -type f "${md_predicate[@]}" -print \)
  )
fi

# 並べ替え
if [ -s "$TMP" ]; then
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 "$TMP" -o "$TMP"
fi

# 箇条書きで出力（相対リンクは $PWD 基準）
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
