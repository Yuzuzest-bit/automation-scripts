#!/usr/bin/env bash
# close_task.sh (mac/linux/windows Git Bash 対応)
# 使い方: close_task.sh <file>
# やること:
# 1) frontmatter に closed: <timestamp> を追加/更新
# 2) 本文の最初の @progress/@focus/... 行を done:<timestamp> ... に差し替え

set -euo pipefail

FILE_IN="${1:-}"
if [[ -z "$FILE_IN" ]]; then
  echo "usage: $0 <markdown-file>" >&2
  exit 1
fi

# Git Bash で VS Code から C:\... が来る場合に備えて POSIX へ変換
FILE="$FILE_IN"
if command -v cygpath >/dev/null 2>&1; then
  if [[ "$FILE" =~ ^[A-Za-z]:\\ ]]; then
    FILE="$(cygpath -u "$FILE")"
  fi
fi

if [[ ! -f "$FILE" ]]; then
  echo "Not a regular file: $FILE_IN (resolved: $FILE)" >&2
  exit 1
fi

# タイムスタンプ（JSTが使える環境ならそれを使う。無ければローカル）
: "${TZ:=Asia/Tokyo}"
TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"

# 同一ディレクトリに一時ファイル（クロスデバイス回避 & エディタの監視と相性良い）
dir="$(dirname "$FILE")"
TMP="$(mktemp "$dir/.close_task.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

awk -v ts="$TS" '
BEGIN{
  inFM=0; hasFM=0; closedDone=0; doneReplaced=0;
}
{
  # 行末CR除去 (Windows CRLF 対策)
  sub(/\r$/, "", $0)
}
NR==1 {
  # UTF-8 BOM 除去
  sub(/^\xEF\xBB\xBF/, "", $0)
  if ($0=="---") { inFM=1; hasFM=1; print $0; next }
}
# frontmatter 内
inFM==1 {
  # 既存 closed: を置き換え
  if ($0 ~ /^closed:[[:space:]]*/) { print "closed: " ts; closedDone=1; next }
  # frontmatter 終了
  if ($0=="---") {
    if (closedDone==0) { print "closed: " ts }
    print $0; inFM=0; next
  }
  print $0; next
}
# frontmatter が無い → 冒頭に生成
hasFM==0 && NR==1 {
  print "---"; print "closed: " ts; print "---"; hasFM=1
}
# 本文：最初の @... 行を done: に差し替え
doneReplaced==0 && $0 ~ /^[[:space:]]*@[[:alpha:]]/ {
  sub(/^[[:space:]]*@[[:alnum:]_-]+[[:space:]]+/, "", $0)
  print "done:" ts " " $0
  doneReplaced=1
  next
}
# その他はそのまま
{ print $0 }
' "$FILE" > "$TMP"

# 置換（Windowsで稀にmvが失敗する対策としてfallbackも用意）
if ! mv -f "$TMP" "$FILE"; then
  cp -f "$TMP" "$FILE" && rm -f "$TMP"
fi

echo "[INFO] closed: ${TS} を追加し、先頭タスクをdone化しました -> ${FILE_IN}"
