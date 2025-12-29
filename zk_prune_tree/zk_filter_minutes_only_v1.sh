#!/usr/bin/env bash
# zk_extract_minutes_flat_v3.sh
#
# TREE_VIEW.md から「🕒 が付いたリスト行」だけを抽出して、インデントを落として平坦化。
# - ファイル場所を自動検出（どこから実行しても動きやすい）
# - 🕒が0件なら上書きしない（全刈り防止）
# - 何が起きてるか診断ログを出す

set -Eeuo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}"

MARK="${MINUTES_MARK:-🕒}"   # 変更したい場合は環境変数で: MINUTES_MARK="🕒"
DBG="${ZK_DEBUG:-0}"
dbg(){ if [[ "$DBG" != 0 ]]; then printf '[DBG] %s\n' "$*" >&2; fi; }

find_tree_file() {
  # 1) 引数で指定されたらそれ
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return 0
  fi

  # 2) よくある場所
  if [[ -f "./dashboards/TREE_VIEW.md" ]]; then printf '%s\n' "./dashboards/TREE_VIEW.md"; return 0; fi
  if [[ -f "./TREE_VIEW.md" ]]; then printf '%s\n' "./TREE_VIEW.md"; return 0; fi

  # 3) 親へ最大6階層探索（vault root から外れて実行したケース救済）
  local d
  d="$(pwd -P)"
  for _ in 1 2 3 4 5 6; do
    if [[ -f "$d/dashboards/TREE_VIEW.md" ]]; then
      printf '%s\n' "$d/dashboards/TREE_VIEW.md"
      return 0
    fi
    [[ "$d" == "/" ]] && break
    d="$(cd "$d/.." && pwd -P)"
  done

  printf '%s\n' ""
  return 0
}

TARGET_FILE="$(find_tree_file "${1:-}")"
if [[ -z "$TARGET_FILE" || ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] TREE_VIEW.md が見つかりません。" >&2
  echo "      例: ./zk_extract_minutes_flat_v3.sh /path/to/dashboards/TREE_VIEW.md" >&2
  exit 1
fi

dbg "TARGET_FILE=$TARGET_FILE"

TMP_FILE="$(mktemp)"
SRC_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE" "$SRC_FILE"' EXIT

# CRLF対策（\r を除去したコピーを作る）
tr -d '\r' < "$TARGET_FILE" > "$SRC_FILE"

# まずリスト行だけの総数
list_count="$(grep -a -E '^[[:space:]]*- ' "$SRC_FILE" | wc -l | tr -d ' ')"
dbg "list_lines=$list_count"

# 🕒付きのリスト行だけ数える（awkのUnicode問題を避けて grep で）
hit_count="$(grep -a -E '^[[:space:]]*- ' "$SRC_FILE" | grep -a -F "$MARK" | wc -l | tr -d ' ')"
dbg "hit_count(mark=$MARK)=$hit_count"

if ! [[ "$hit_count" =~ ^[0-9]+$ ]]; then hit_count=0; fi
if (( hit_count == 0 )); then
  echo "[ERR] '${MARK}' を含むリスト行が 1件も見つかりません（上書きしません）。" >&2
  echo "      まず実データを確認してください:" >&2
  echo "      grep -a -n \"${MARK}\" \"$TARGET_FILE\" | head" >&2
  echo "" >&2
  echo "      参考: リスト先頭10行:" >&2
  grep -a -E '^[[:space:]]*- ' "$SRC_FILE" | head -n 10 | sed 's/^/[INFO] /' >&2
  exit 1
fi

# 1) ヘッダ部（最初のリスト行が出るまで）を残す
awk '
  { print }
  $0 ~ /^[ ]*- / { exit }
' "$SRC_FILE" | awk '{
  if ($0 ~ /^[ ]*- /) exit
  print
}' > "$TMP_FILE"

# 2) 🕒付きリスト行のみ抜き出し → インデント落として平坦化
grep -a -E '^[[:space:]]*- ' "$SRC_FILE" \
  | grep -a -F "$MARK" \
  | sed -E 's/^[[:space:]]+//' \
  >> "$TMP_FILE"

mv -f "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "[OK] minutes-only(flat) extracted: $TARGET_FILE"
if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
