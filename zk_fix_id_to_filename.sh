#!/usr/bin/env bash
# zk_fix_id_to_filename.sh <file>
#
# frontmatter の id: 行を、
#   id: yyyymmdd-ファイル名(拡張子なし)
# の形で、ファイル名に合わせて更新する。
# yyyymmdd 部分は既存の id からそのまま流用する。

set -euo pipefail

FILE="${1:-}"

if [[ -z "$FILE" ]]; then
  echo "usage: zk_fix_id_to_filename.sh <file>" >&2
  exit 2
fi

if [[ ! -f "$FILE" ]]; then
  echo "Not a regular file: $FILE" >&2
  exit 2
fi

# ファイル名（拡張子なし）を取得
base="$(basename "$FILE")"
name_no_ext="${base%.*}"

tmp="$(mktemp)"

awk -v newbase="$name_no_ext" '
BEGIN {
  fixed = 0
}
# id: の行だけを書き換える（最初の1回だけ）
fixed == 0 && /^id:[[:space:]]*/ {
  # value 部分を取り出す
  val = $0
  sub(/^id:[[:space:]]*/, "", val)

  # 先頭8桁（yyyymmdd）だけ残す（ハイフン以降を削る）
  date = val
  sub(/-.*/, "", date)

  if (date ~ /^[0-9]{8}$/) {
    # 期待通りの形式なら、置き換え
    $0 = "id: " date "-" newbase
    fixed = 1
  }
  # 想定外形式の場合はそのまま（$0は変更しない）
}
{ print }
' "$FILE" > "$tmp"

mv "$tmp" "$FILE"
