#!/usr/bin/env bash
# zk_extract_minutes_flat_v3_1.sh
#
# TREE_VIEW.md から「🕒 が付いたリスト行」だけ抽出して平坦化。
# - pipefail でも grep 0件で落ちない
# - 🕒が0件なら上書きしない（全刈り防止）
# - 失敗時は必ず [ERR] line=... cmd=... を出す

set -Eeuo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}"

trap 'rc=$?; printf "[ERR] exit=%d line=%d cmd=%s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

MARK="${MINUTES_MARK:-🕒}"
DBG="${ZK_DEBUG:-0}"
dbg(){ if [[ "$DBG" != 0 ]]; then printf '[DBG] %s\n' "$*" >&2; fi; }

find_tree_file() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  if [[ -f "./dashboards/TREE_VIEW.md" ]]; then printf '%s\n' "./dashboards/TREE_VIEW.md"; return 0; fi
  if [[ -f "./TREE_VIEW.md" ]]; then printf '%s\n' "./TREE_VIEW.md"; return 0; fi

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
}

TARGET_FILE="$(find_tree_file "${1:-}")"
if [[ -z "$TARGET_FILE" || ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] TREE_VIEW.md が見つかりません。" >&2
  echo "      例: bash zk_extract_minutes_flat_v3_1.sh dashboards/TREE_VIEW.md" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
SRC_FILE="$(mktemp)"
OUT_BODY="$(mktemp)"
trap 'rm -f "$TMP_FILE" "$SRC_FILE" "$OUT_BODY"' EXIT

# CRLF対策
tr -d '\r' < "$TARGET_FILE" > "$SRC_FILE"

dbg "TARGET_FILE=$TARGET_FILE"
dbg "MARK=$MARK"

# pipefail 対策：grep が 0件でも落ちないように ( ... || true ) を挟む
list_count="$(
  { grep -a -E '^[[:space:]]*- ' "$SRC_FILE" || true; } \
  | wc -l | tr -d ' '
)"
hit_count="$(
  { grep -a -E '^[[:space:]]*- ' "$SRC_FILE" || true; } \
  | { grep -a -F "$MARK" || true; } \
  | wc -l | tr -d ' '
)"

dbg "list_lines=$list_count"
dbg "hit_count=$hit_count"

if ! [[ "${hit_count:-0}" =~ ^[0-9]+$ ]]; then hit_count=0; fi
if (( hit_count == 0 )); then
  echo "[ERR] '${MARK}' を含むリスト行が 1件も見つかりません（上書きしません）。" >&2
  echo "      確認: grep -a -n \"${MARK}\" \"$TARGET_FILE\" | head" >&2
  echo "" >&2
  echo "      参考: リスト先頭10行:" >&2
  { grep -a -E '^[[:space:]]*- ' "$SRC_FILE" || true; } | head -n 10 | sed 's/^/[INFO] /' >&2
  exit 1
fi

# ヘッダ部（最初のリスト行が出るまで）を残す
awk '
  /^[ ]*- / { exit }
  { print }
' "$SRC_FILE" > "$TMP_FILE"

# 🕒付きリスト行のみ → 平坦化して別TMPへ
{ grep -a -E '^[[:space:]]*- ' "$SRC_FILE" || true; } \
  | { grep -a -F "$MARK" || true; } \
  | sed -E 's/^[[:space:]]+//' \
  > "$OUT_BODY"

out_lines="$(wc -l < "$OUT_BODY" | tr -d ' ')"
dbg "out_lines=$out_lines"

# 最終安全策：抽出が0なら上書きしない
if ! [[ "${out_lines:-0}" =~ ^[0-9]+$ ]]; then out_lines=0; fi
if (( out_lines == 0 )); then
  echo "[ERR] 抽出結果が 0 行になりました（上書きしません）。" >&2
  echo "      MARK='${MARK}' の文字コード/記号が想定と違う可能性があります。" >&2
  exit 1
fi

cat "$OUT_BODY" >> "$TMP_FILE"
mv -f "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "[OK] minutes-only(flat) extracted: $TARGET_FILE"

if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
