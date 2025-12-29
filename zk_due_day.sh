#!/usr/bin/env bash
# zk_due_day.sh <file> [today|tomorrow|3weeks|nextmonth]
# frontmatter 内の due: を指定した日に更新する（なければ追加）
#
# 第二引数:
#   today      : 今日
#   tomorrow   : 明日（デフォルト）
#   3weeks     : 3週間後（=21日後）
#   nextmonth  : 来月（=1か月後。月末などで日付が存在しない場合は date の挙動に従い繰り上がることがあります）
#
# mac(BSD date) / Linux(GNU date) / Git Bash を想定

set -euo pipefail

FILE="${1:-}"
MODE="${2:-tomorrow}"   # デフォルトは「明日」

if [[ -z "${FILE}" ]]; then
  echo "usage: $0 <markdown-file> [today|tomorrow|3weeks|nextmonth]" >&2
  exit 2
fi

if [[ ! -f "${FILE}" ]]; then
  echo "Not a regular file: ${FILE}" >&2
  exit 2
fi

# BSD date (mac) 判定: -v が使えるかどうか
is_bsd_date() {
  date -v+1d '+%Y-%m-%d' >/dev/null 2>&1
}

# 目標日付を決定
case "${MODE}" in
  today|0d)
    TARGET_DATE="$(date '+%Y-%m-%d')"
    ;;
  tomorrow|1d|"")
    if is_bsd_date; then
      TARGET_DATE="$(date -v+1d '+%Y-%m-%d')"
    else
      TARGET_DATE="$(date -d 'tomorrow' '+%Y-%m-%d')"
    fi
    ;;
  3weeks|3w|21d)
    if is_bsd_date; then
      TARGET_DATE="$(date -v+21d '+%Y-%m-%d')"
    else
      TARGET_DATE="$(date -d '+21 days' '+%Y-%m-%d')"
    fi
    ;;
  nextmonth|1m|month)
    if is_bsd_date; then
      TARGET_DATE="$(date -v+1m '+%Y-%m-%d')"
    else
      TARGET_DATE="$(date -d '+1 month' '+%Y-%m-%d')"
    fi
    ;;
  *)
    # 互換のため「未知=tomorrow扱い」に倒す（必要ならここで exit 2 に変更）
    if is_bsd_date; then
      TARGET_DATE="$(date -v+1d '+%Y-%m-%d')"
    else
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
  in_fm     = 0   # frontmatter の中かどうか
  fm_done   = 0   # 一番上の frontmatter を処理し終わったか
  found_due = 0   # その frontmatter 内に due: があったか
}

# frontmatter の境界 --- を検出
/^---[ \t]*$/ {
  if (fm_done == 0) {
    if (in_fm == 0) {
      in_fm = 1
      print
    } else {
      if (found_due == 0) {
        print "due: " d
      }
      in_fm   = 0
      fm_done = 1
      print
    }
  } else {
    print
  }
  next
}

{
  if (in_fm == 1 &&
      $0 ~ /^due:[ \t]*[0-9]{4}-[0-9]{2}-[0-9]{2}[ \t]*$/) {
    print "due: " d
    found_due = 1
  } else {
    print
  }
}
' "${FILE}" > "${TMP}"

mv "${TMP}" "${FILE}"
trap - EXIT
