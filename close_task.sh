#!/usr/bin/env bash
# close_task.sh
# 使い方: close_task.sh <file>
# やること:
# 1) frontmatterの中に closed: <timestamp> を追加/更新（--- ～ --- を厳密検出、空白許容）
# 2) 本文の最初の @progress/@focus/@hold/@awaiting/@later 等を done:<timestamp> … に置換
#    （frontmatter外・コードフェンス外のみ、@done は対象外）
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
  case "$FILE" in [A-Za-z]:\\*) FILE="$(cygpath -u "$FILE")" ;; esac
fi
[ -f "$FILE" ] || { echo "usage: $0 <markdown-file>  (not found: $FILE_IN -> $FILE)" >&2; exit 1; }

# タイムスタンプ（環境変数 CLOSE_TASK_TZ があればそれを優先）
if [ -n "${CLOSE_TASK_TZ:-}" ]; then
  TS="$(TZ="$CLOSE_TASK_TZ" date '+%Y-%m-%dT%H:%M:%S%z')"
else
  TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

awk -v ts="$TS" '
BEGIN{
  inFM=0; hasFM=0; closedDone=0; doneReplaced=0; inFence=0;
}
{
  # CR除去 + 先頭BOM除去（\357\273\277 = 0xEF,0xBB,0xBF）
  sub(/\r$/, "", $0);
  if (NR==1) sub(/^\357\273\277/, "", $0);
}

# 先頭が frontmatter 開始（--- だけ、末尾空白許容）
NR==1 && $0 ~ /^---[[:space:]]*$/ {
  inFM=1; hasFM=1; print $0; next
}

# frontmatter 内
inFM==1 {
  # 既存 closed: は置換
  if ($0 ~ /^[[:space:]]*closed:[[:space:]]*/) {
    print "closed: " ts;
    closedDone=1;
    next;
  }
  # frontmatter 終了
  if ($0 ~ /^---[[:space:]]*$/) {
    if (closedDone==0) print "closed: " ts;
    print $0;
    inFM=0;
    next;
  }
  # それ以外はそのまま
  print $0;
  next;
}

# frontmatter が無いファイル → 冒頭に作る（1回だけ）
hasFM==0 && NR==1 {
  print "---";
  print "closed: " ts;
  print "---";
  hasFM=1;
  # この行自体は本文として引き続き処理する（fallthrough）
}

# ここから本文処理
# コードフェンス（``` または ~~~、行頭空白許容）をトグルし、中はスキップ対象
{
  t=$0; sub(/^[[:space:]]+/, "", t);
  if (t ~ /^```/ || t ~ /^~~~/) {
    inFence = (inFence==0 ? 1 : 0);
    print $0;
    next;
  }
}

# 本文：最初の @タグ 行を done: に置換（コードフェンス外のみ／@doneは除外）
doneReplaced==0 && inFence==0 {
  # 先頭の空白→@タグを抽出
  if ($0 ~ /^[[:space:]]*@[A-Za-z0-9_-]+([[:space:]]+|$)/) {
    tmp=$0;
    sub(/^[[:space:]]*@/, "", tmp);           # 先頭@を外す
    tag=tmp; sub(/[[:space:]].*$/, "", tag);  # タグ名だけ抽出
    low=tag;
    # tolower は POSIX awk でも利用可
    gsub(/[A-Z]/, "", low); low=tolower(tag);

    if (low != "done") {
      sub(/^[[:space:]]*@[A-Za-z0-9_-]+[[:space:]]+/, "", $0);  # 先頭 @tag を落とす（後続は保持）
      print "done:" ts " " $0;
      doneReplaced=1;
      next;
    }
  }
}

# それ以外は素通し
{ print $0 }
' "$FILE" > "$TMP"

# 上書き
mv "$TMP" "$FILE"
echo "[INFO] closed: ${TS} を追加/更新し、先頭タスクを done 化しました -> ${FILE}"
