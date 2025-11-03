#!/usr/bin/env bash
# close_task.sh
# 使い方: close_task.sh <file>
# やること:
# 1) frontmatterの中に closed: <timestamp> を追加/更新
# 2) 最初の @progress/@focus/... の行を done:<timestamp> … に書き換え
set -eu
FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "usage: $0 <markdown-file>" >&2
  exit 1
fi
# JSTでISO8601っぽく（2025-11-03T09:29:06+0900）
TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
awk -v ts="$TS" '
BEGIN{
  inFM=0
  hasFM=0
  closedDone=0
  doneReplaced=0
}
NR==1 { sub(/^\357\273\277/, "") }
{ sub(/\r$/, "") }
NR==1 {
  if ($0=="---") {
    inFM=1
    hasFM=1
    print $0
    next
  }
}
# frontmatterの中を処理
inFM==1 {
  # 既存 closed: があれば置き換え
  if ($0 ~ /^closed:[[:space:]]*/) {
    print "closed: " ts
    closedDone=1
    next
  }
  # frontmatter終了
  if ($0=="---") {
    if (closedDone==0) {
      print "closed: " ts
    }
    print $0
    inFM=0
    next
  }
  print $0
  next
}
# frontmatterが無いファイルだった場合 → 冒頭にFMを作る
hasFM==0 && NR==1 {
  print "---"
  print "closed: " ts
  print "---"
  hasFM=1
  # この行も処理しないといけないので fallthrough で続ける
}
# 本文側：最初の @progress/@focus/@hold/... を done: に変える
doneReplaced==0 && $0 ~ /^@[a-zA-Z]/ {
  # 先頭の@...を消して、done:TIMESTAMP で付け直す
  # 例: @progress due:... タイトル → done:TS due:... タイトル
  sub(/^@[a-zA-Z0-9_-]+[[:space:]]+/, "")
  print "done:" ts " " $0
  doneReplaced=1
  next
}
# その他の行はそのまま
{ print $0 }
' "$FILE" > "$TMP"
mv "$TMP" "$FILE"
echo "[INFO] closed: ${TS} を追加し、先頭タスクをdone化しました -> ${FILE}"
