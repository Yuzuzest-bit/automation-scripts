#!/usr/bin/env bash
# zk_can_close.sh (lite, robust Children parser + proper @done detection)
# ルール:
#  - "Children: open=N ..." の N>0 なら NG
#  - 本文の先頭に "@..." がある行は未完タスクとして数えるが、"@done" は除外
set -euo pipefail

IN="${1:-}"; [ -n "$IN" ] || { echo "usage: $0 <note.md>"; exit 2; }
FILE="$IN"
if command -v cygpath >/dev/null 2>&1; then
  case "$FILE" in
    [A-Za-z]:\\* ) FILE="$(cygpath -u "$FILE")" ;;
  esac
fi
[ -f "$FILE" ] || { echo "No such file: $IN (resolved: $FILE)"; exit 2; }

awk '
BEGIN{
  inFM=0        # frontmatter 内か
  fmDone=0      # frontmatter 処理が完了したか
  inFence=0     # ``` / ~~~ のコードブロック内か
  children=-1
  localOpen=0
}

{
  sub(/\r$/, "", $0);                      # CRLF除去
  if (NR==1) sub(/^\357\273\277/, "", $0); # BOM除去
}

# frontmatter トグル:
#   ファイル先頭の最初の "--- ... ---" だけを frontmatter として扱う
/^---[[:space:]]*$/ {
  if (fmDone==0) {
    if (inFM==0 && NR==1) {
      # 先頭行の --- -> frontmatter 開始
      inFM=1
      next
    } else if (inFM==1) {
      # frontmatter 終了
      inFM=0
      fmDone=1
      next
    }
  }
  # fmDone==1 のあとの --- は単なる水平線なので通常処理へ
}

# 本文処理
inFM==0 {
  # コードフェンス（``` or ~~~）：中はスキップ
  t=$0
  sub(/^[[:space:]]+/, "", t)
  if (t ~ /^```/ || t ~ /^~~~/) {
    inFence = 1 - inFence
    next
  }

  # Children: open=...
  if ($0 ~ /^Children:[[:space:]]*open=/) {
    s=$0
    sub(/^.*open=/, "", s)       # open= まで切り落とし
    gsub(/^[[:space:]]+/, "", s) # 先頭空白除去
    n=""
    for (i=1; i<=length(s); i++) {
      c=substr(s,i,1)
      if (c ~ /[0-9]/) n=n c; else break
    }
    if (n!="") children = n + 0
    next
  }

  # 未完 @行（@done は除外）
  if (inFence==0 && $0 ~ /^[[:space:]]*@/) {
    if ($0 ~ /^[[:space:]]*@done([[:space:]]|:|$)/) {
      # ignore
    } else {
      localOpen++
    }
  }
}

END{
  if (ENVIRON["VERBOSE"]=="1") {
    printf("children_open_from_line: %d\n", children<0?0:children)
    printf("local_open: %d\n", localOpen)
  }

  if ((children>=0 && children>0) || localOpen>0) {
    print "[NG] not closable."
    print "  - local open tasks: " localOpen
    print "  - children(open) by line: " (children<0?0:children)
    exit 1
  }

  print "[OK] closable."
  exit 0
}
' "$FILE"
