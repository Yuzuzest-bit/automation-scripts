#!/usr/bin/env bash
# zk_extract_minutes_flat_v2.sh
#
# TREE_VIEW.md から「🕒(minutes) が付いた行」だけを残して平坦化する。
# Git Bash(特に mawk) の Unicode 正規表現不一致を避け、🕒検出は grep で行う。
#
# Safety:
# - 🕒が0件なら上書きしない（全刈り防止）

set -Eeuo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}"

OUTDIR_NAME="${OUTDIR_NAME:-dashboards}"
FIXED_FILENAME="${FIXED_FILENAME:-TREE_VIEW.md}"
ROOT="$(pwd -P)"
TARGET_FILE="${ROOT}/${OUTDIR_NAME}/${FIXED_FILENAME}"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] not found: $TARGET_FILE" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
SRC_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE" "$SRC_FILE"' EXIT

# CRLF対策（\r を除去したコピーを作る）
tr -d '\r' < "$TARGET_FILE" > "$SRC_FILE"

# 🕒が存在するか（grepで確認）
count="$(grep -a -F "🕒" "$SRC_FILE" | wc -l | tr -d ' ')"
if ! [[ "$count" =~ ^[0-9]+$ ]]; then count=0; fi
if (( count == 0 )); then
  echo "[ERR] 🕒 が1件も見つかりません。TREE_VIEW.md に 🕒 が付いていない可能性があります。" >&2
  echo "      確認: grep -a -n \"🕒\" \"$TARGET_FILE\" | head" >&2
  exit 1
fi

# 1) ヘッダ部（最初のリスト行が出るまで）をそのまま残す
awk '
  { print }
  $0 ~ /^[ ]*- / { exit }
' "$SRC_FILE" | awk '{
  # 上の awk は最初の "- " 行も出してしまうので削る
  # 末尾が "- " の直前までだけ残す
  if ($0 ~ /^[ ]*- /) exit
  print
}' > "$TMP_FILE"

# 2) 🕒 を含むリスト行だけ抜き出して、インデントを全部落として平坦化
#    ※「- 」自体は残す（見た目はリストのまま）
grep -a -F "🕒" "$SRC_FILE" \
  | grep -a -E '^[[:space:]]*- ' \
  | sed -E 's/^[[:space:]]+//' \
  >> "$TMP_FILE"

mv -f "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "[OK] minutes-only (flat) extracted: $TARGET_FILE"
if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
