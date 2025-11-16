#!/usr/bin/env bash
# zk_print_id.sh — print frontmatter id: of a markdown file
# macOS / Linux / Windows(Git Bash)
set -euo pipefail

FILE_IN="${1:-}"

if [ -z "$FILE_IN" ]; then
  echo "usage: $0 <markdown-file>" >&2
  exit 2
fi

FILE="$FILE_IN"

# Windowsパス → POSIX 変換（Git Bash 用。mac では何も起きない）
if command -v cygpath >/dev/null 2>&1; then
  case "$FILE" in
    [A-Za-z]:[\\/]*) FILE="$(cygpath -u "$FILE")" ;;
  esac
fi

if [ ! -f "$FILE" ]; then
  echo "No such file: $FILE_IN (resolved: $FILE)" >&2
  exit 1
fi

# frontmatter から id: の行だけ拾って値部分を出力
awk '
  BEGIN { in_fm=0 }
  # 1行目 "---" から frontmatter 開始とみなす
  NR==1 && $0 ~ /^---[[:space:]]*$/ { in_fm=1; next }
  # 2個目の "---" で frontmatter 終了
  in_fm && $0 ~ /^---[[:space:]]*$/ { exit }
  # frontmatter 内の id: 行
  in_fm && $0 ~ /^id:[[:space:]]*/ {
      sub(/^id:[[:space:]]*/, "")   # 先頭の "id:" と空白を削る
      print
      exit
  }
' "$FILE"
