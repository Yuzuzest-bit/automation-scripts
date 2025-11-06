#!/usr/bin/env bash
# md_open_due_dashboard.sh — Windows Git Bash / macOS / Linux 決定版
# 1) 必ずヘッダを書き出す（空ファイルにならない）
# 2) front matter は先頭30行までの最初の --- 〜 次の --- を解析
# 3) closed: あり→除外、due: 無し→9999-12-31
# 4) CRLF/BOM/日本語パス対応、-print0 使えない環境は自動フォールバック
set -u
set -o pipefail

DEBUG="${DEBUG:-0}"               # DEBUG=1 で詳細ログ
ROOT_IN="${1:-.}"
OUT_IN="${2:-open_by_due.md}"

# --- パス正規化（Git Bash on Windows） ---
ROOT="$ROOT_IN"; OUT="$OUT_IN"
if command -v cygpath >/dev/null 2>&1; then
  case "$ROOT" in [A-Za-z]:/*|[A-Za-z]:\\*) ROOT="$(cygpath -u "$ROOT")";; esac
  case "$OUT"  in [A-Za-z]:/*|[A-Za-z]:\\*) OUT="$(cygpath -u "$OUT")";;  esac
fi
case "$ROOT" in [A-Za-z]/*) ROOT="/$ROOT";; esac
case "$OUT"  in [A-Za-z]/*) OUT="/$OUT";;  esac

mkdir -p "$(dirname "$OUT")" || { echo "[ERR] cannot mkdir: $(dirname "$OUT")" >&2; exit 1; }

TMP="${OUT}.tmp.$$"
: > "$TMP" || { echo "[ERR] cannot create tmp: $TMP" >&2; exit 1; }

# --- 先にヘッダを書いておく（ここで必ず中身ができる） ---
{
  echo "# Open Tasks by Due Date"
  echo
  date_str=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
  echo "- Generated: $date_str"
  echo "- Root: \`$ROOT\`"
} > "$OUT" || { echo "[ERR] cannot write OUT header: $OUT" >&2; exit 1; }

# --- 収集（find -print0 優先、ダメなら改行区切りへ） ---
COUNT=0

scan_file() {
  awk -v DEBUG="$DEBUG" '
    BEGIN {
      RS="\n"; FS="\n"
      cr = sprintf("%c",13)
      started=0; ended=0; fm_line=0
      has_closed=0; due=""; max_seek=30
    }
    {
      sub(/\r$/,"")                  # CRLF
      if (NR<=max_seek && started==0) {
        if ($0 ~ /^---[ \t]*$/) { started=1; next }
        else if ($0 ~ /^[ \t]*$/) { next }   # 空行は許容
        else { next }                         # ヘッダ前の雑多な行は読み飛ばし
      }
      else if (started==1 && ended==0) {
        if ($0 ~ /^---[ \t]*$/) { ended=1; next }
        if (match($0, /^[ \t]*([A-Za-z0-9_-]+):[ \t]*(.*)$/, m)) {
          k=m[1]; v=m[2]
          gsub(/^[\"\047]/,"",v); gsub(/[\"\047]$/,"",v)
          if (k=="closed" && length(v)>0) has_closed=1
          else if (k=="due" && length(v)>0) {
            if (match(v, /[0-9]{4}-[0-9]{2}-[0-9]{2}/))      due=substr(v,RSTART,RLENGTH)
            else if (match(v, /[0-9]{4}\/[0-9]{2}\/[0-9]{2}/)) {
              d=substr(v,RSTART,RLENGTH); gsub(/\//,"-",d);  due=d
            }
          }
        }
      }
    }
    END {
      if (started==1 && has_closed==0) {
        if (due=="") due="9999-12-31"
        printf "%s\t%s\n", due, FILENAME
      }
    }
  ' "$1" >> "$TMP" || true
}

if find "$ROOT" -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune -o -type f -name "*.md" -print0 >/dev/null 2>&1; then
  [ "$DEBUG" = "1" ] && echo "[DBG] using -print0 pipeline" >&2
  while IFS= read -r -d '' F; do
    COUNT=$((COUNT+1))
    [ "$DEBUG" = "1" ] && echo "[DBG] scan: $F" >&2
    scan_file "$F"
  done < <(
    find "$ROOT" \
      \( -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune \) -o \
      \( -type f -name "*.md" -print0 \)
  )
else
  [ "$DEBUG" = "1" ] && echo "[DBG] fallback to newline pipeline" >&2
  while IFS= read -r F; do
    COUNT=$((COUNT+1))
    [ "$DEBUG" = "1" ] && echo "[DBG] scan: $F" >&2
    scan_file "$F"
  done < <(
    find "$ROOT" \
      \( -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune \) -o \
      \( -type f -name "*.md" -print \)
  )
fi

# --- 並べ替え & 本文追記 ---
if [ -s "$TMP" ]; then
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 "$TMP" -o "$TMP"
fi

{
  echo "- Scanned: $COUNT files"
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
[ "$DEBUG" = "1" ] && { echo "[DBG] OUT: $OUT" >&2; head -n 8 "$OUT" | sed 's/^/[HEAD] /' >&2; } || true
echo "[OK] wrote -> $OUT"
