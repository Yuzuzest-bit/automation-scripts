#!/usr/bin/env bash
# md_open_due_dashboard.sh v2.6
# - OUT が空になるのを防止（必ずヘッダ＋統計を書き出す）
# - 拡張子を大小/別名まで網羅: .md .markdown .mkd .mdx（大文字含む）
# - 総ファイル数 / 該当MD数 をヘッダに出す（原因特定が一発）
# - front matter は先頭30行の最初の ---〜次の--- を解析
# - closed: あり→除外、due: 無し→9999-12-31、CRLF/BOM対応
set -u
set -o pipefail

ROOT_IN="${1:-.}"
OUT_IN="${2:-open_by_due.md}"

# --- パス正規化（Git Bash on Windows 対応） ---
ROOT="$ROOT_IN"; OUT="$OUT_IN"
if command -v cygpath >/dev/null 2>&1; then
  case "$ROOT" in [A-Za-z]:/*|[A-Za-z]:\\*) ROOT="$(cygpath -u "$ROOT")";; esac
  case "$OUT"  in [A-Za-z]:/*|[A-Za-z]:\\*) OUT="$(cygpath -u "$OUT")";;  esac
fi
case "$ROOT" in [A-Za-z]/*) ROOT="/$ROOT";; esac
case "$OUT"  in [A-Za-z]/*) OUT="/$OUT";;  esac

# OUT がディレクトリなら既定ファイル名を付ける
if [ -d "$OUT" ] || [[ "$OUT" == */ ]]; then
  OUT="${OUT%/}/open_by_due.md"
fi

# ルート存在チェック
[ -d "$ROOT" ] || { echo "[ERR] ROOT not found: $ROOT" >&2; exit 1; }

OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR" || { echo "[ERR] cannot mkdir: $OUT_DIR" >&2; exit 1; }

# 先にヘッダ（ここで必ず中身ができる）
{
  echo "# Open Tasks by Due Date"
  echo
  echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
  echo "- Root: \`$ROOT\`"
} > "$OUT" || { echo "[ERR] cannot write OUT header: $OUT" >&2; exit 1; }

TMP="${OUT}.rows.$$"
: > "$TMP" || { echo "[ERR] cannot create tmp: $TMP" >&2; exit 1; }

# --- 探索条件（大小混在の拡張子を網羅） ---
md_predicate=( \( -iname '*.md' -o -iname '*.markdown' -o -iname '*.mkd' -o -iname '*.mdx' \) )
prune_dirs=( -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune )

# 総ファイル数と MD 該当数（統計）
TOTAL_FILES=$(find "$ROOT" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
MATCH_MD=$(find "$ROOT" \( "${prune_dirs[@]}" \) -o \( -type f "${md_predicate[@]}" -print \) 2>/dev/null | wc -l | tr -d '[:space:]')

# 収集
COUNT=0
scan_file() {
  awk '
    BEGIN { RS="\n"; started=0; ended=0; has_closed=0; due=""; max_seek=30 }
    { sub(/\r$/,"") }               # CRLF
    NR==1 { sub(/^\xEF\xBB\xBF/,"") } # BOM
    NR<=max_seek && started==0 {     # 先頭30行で --- を探す（空行/ゴミは許容）
      if ($0 ~ /^---[ \t]*$/) { started=1; next } else { next }
    }
    started && !ended {
      if ($0 ~ /^---[ \t]*$/) { ended=1; next }
      if (match($0, /^[ \t]*([A-Za-z0-9_-]+):[ \t]*(.*)$/, m)) {
        k=m[1]; v=m[2]
        gsub(/^[\"\047]/,"",v); gsub(/[\"\047]$/,"",v)
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

# -print0 が使えれば優先
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

# 追記（統計＋表）
{
  echo "- Scanned (all files under root): ${TOTAL_FILES}"
  echo "- Matched markdown files: ${MATCH_MD}"
  echo "- Parsed markdown files (after prune): ${COUNT}"
  echo
  if [ ! -s "$TMP" ]; then
    echo "_No open notes found (all closed or no front matter)._"
  else
    echo "| Due | File |"
    echo "| :-- | :--- |"
    while IFS=$'\t' read -r D P; do
      RP="$P"; case "$RP" in "$ROOT"/*) RP="${RP#"$ROOT/"}";; esac
      printf "| %s | [%s](%s) |\n" "$D" "$RP" "$RP"
    done < "$TMP"
  fi
} >> "$OUT"

rm -f "$TMP"
echo "[OK] wrote -> $OUT"
