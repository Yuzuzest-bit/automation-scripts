#!/usr/bin/env bash
# close_task.sh
# 使い方: close_task.sh <file>
# やること:
# 1) frontmatterの中に closed: <timestamp> を追加/更新（--- ～ --- を厳密検出、空白許容）
# 2) 本文は一切変更しない（@progress/@focus/@hold/... を勝手に done にしない）

set -euo pipefail

# 引数
FILE_IN="${1:-}"
if [ -z "$FILE_IN" ]; then
  echo "usage: $0 <markdown-file>" >&2
  exit 1
fi

# Windowsパス→POSIX (Git Bash)
FILE="$FILE_IN"
if command -v cygpath >/dev/null 2>&1; then
  case "$FILE" in
    [A-Za-z]:\\*) FILE="$(cygpath -u "$FILE")" ;;
  esac
fi
[ -f "$FILE" ] || {
  echo "usage: $0 <markdown-file>  (not found: $FILE_IN -> $FILE)" >&2
  exit 1
}

# タイムスタンプ（環境変数 CLOSE_TASK_TZ があればそれを優先）
if [ -n "${CLOSE_TASK_TZ:-}" ]; then
  TS="$(TZ="$CLOSE_TASK_TZ" date '+%Y-%m-%dT%H:%M:%S%z')"
else
  TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

awk -v ts="$TS" '
BEGIN {
  inFM = 0
  hasFM = 0
  closedDone = 0
}
{
  # CR除去 + 先頭BOM除去
  sub(/\r$/, "", $0)
  if (NR == 1) sub(/^\357\273\277/, "", $0)
}

# 先頭が frontmatter 開始（--- だけ、末尾空白許容）
NR == 1 && $0 ~ /^---[[:space:]]*$/ {
  inFM = 1
  hasFM = 1
  print $0
  next
}

# frontmatter 内
inFM == 1 {
  # 既存 closed: は置換
  if ($0 ~ /^[[:space:]]*closed:[[:space:]]*/) {
    print "closed: " ts
    closedDone = 1
    next
  }
  # frontmatter 終了
  if ($0 ~ /^---[[:space:]]*$/) {
    if (closedDone == 0) print "closed: " ts
    print $0
    inFM = 0
    next
  }
  # それ以外はそのまま
  print $0
  next
}

# frontmatter が無いファイル → 冒頭に作る（1回だけ）
hasFM == 0 && NR == 1 {
  print "---"
  print "closed: " ts
  print "---"
  hasFM = 1
  # この行自体は本文として引き続き処理（fallthrough）
}

# 本文はそのまま出力（@行には一切触れない）
{ print $0 }
' "$FILE" > "$TMP"

mv "$TMP" "$FILE"
echo "[INFO] closed: ${TS} を追加/更新しました（本文中の@行は変更していません） -> ${FILE}"
