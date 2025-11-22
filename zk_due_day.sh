#!/usr/bin/env bash
# zk_due_day.sh <file> [today|tomorrow]
# frontmatter 内の due: を指定した日に更新する（なければ追加）
# 第二引数:
#   today     : 今日
#   tomorrow  : 明日（デフォルト）
#
# mac(BSD date) / Linux / Git Bash を想定

set -euo pipefail

FILE="${1:-}"
MODE="${2:-tomorrow}"   # デフォルトは「明日」

if [[ -z "${FILE}" ]]; then
  echo "usage: $0 <markdown-file> [today|tomorrow]" >&2
  exit 2
fi

if [[ ! -f "${FILE}" ]]; then
  echo "Not a regular file: ${FILE}" >&2
  exit 2
fi

# 目標日付を決定
case "${MODE}" in
  today)
    # 今日の日付（どの環境でも共通）
    TARGET_DATE="$(date '+%Y-%m-%d')"
    ;;
  tomorrow|*)
    # 明日の日付（mac と GNU date で切り替え）
    if date -v+1d '+%Y-%m-%d' >/dev/null 2>&1; then
      # macOS (BSD date)
      TARGET_DATE="$(date -v+1d '+%Y-%m-%d')"
    else
      # GNU date / Git Bash
      TARGET_DATE="$(date -d 'tomorrow' '+%Y-%m-%d')"
    fi
    ;;
esac

TMP="$(mktemp "${FILE}.XXXXXX")"

cleanup() {
  rm -f "${TMP}"
}
trap cleanup EXIT

awk -v d="${TARGET_DATE}" '
BEGIN {
  in_fm = 0
  found_due = 0
}
# frontmatter の境界 --- を検出
/^---[ \t]*$/ {
  if (in_fm == 0) {
    # 開始側 ---
    in_fm = 1
    found_due = 0
    print
  } else {
    # 終了側 ---
    if (found_due == 0) {
      # due: がまだ無ければここで追加してから閉じる
      print "due: " d
    }
    in_fm = 0
    print
  }
  next
}

{
  if (in_fm == 1 && $0 ~ /^due:[ \t]*[0-9]{4}-[0-9]{2}-[0-9]{2}[ \t]*$/) {
    # frontmatter 内の due: YYYY-MM-DD 行だけを置き換える
    print "due: " d
    found_due = 1
  } else {
    print
  }
}
' "${FILE}" > "${TMP}"

mv "${TMP}" "${FILE}"
trap - EXIT
