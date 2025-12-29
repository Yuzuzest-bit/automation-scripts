#!/usr/bin/env bash
# zk_extract_decision_flat_v1.sh
#
# TREE_VIEW.md から「🗳️付きの箇条書き行」だけを抽出して平坦化して残す。
# - VS16 (U+FE0F / UTF-8: EF B8 8F) を除去してから検索（🗳️️問題対策）
# - 0件なら上書きしない
#
set -Eeuo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}"
trap 'rc=$?; printf "[ERR] exit=%d line=%d cmd=%s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

MARK_BASE="${DECISION_MARK_BASE:-🗳️}"
DBG="${ZK_DEBUG:-0}"
dbg(){ if [[ "$DBG" != 0 ]]; then printf '[DBG] %s\n' "$*" >&2; fi; }

find_tree_file() {
  if [[ -n "${1:-}" ]]; then printf '%s\n' "$1"; return 0; fi
  [[ -f "./dashboards/TREE_VIEW.md" ]] && { printf '%s\n' "./dashboards/TREE_VIEW.md"; return 0; }
  [[ -f "./TREE_VIEW.md" ]] && { printf '%s\n' "./TREE_VIEW.md"; return 0; }

  local d
  d="$(pwd -P)"
  for _ in 1 2 3 4 5 6; do
    [[ -f "$d/dashboards/TREE_VIEW.md" ]] && { printf '%s\n' "$d/dashboards/TREE_VIEW.md"; return 0; }
    [[ "$d" == "/" ]] && break
    d="$(cd "$d/.." && pwd -P)"
  done
  printf '%s\n' ""
}

TARGET_FILE="$(find_tree_file "${1:-}")"
if [[ -z "$TARGET_FILE" || ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] TREE_VIEW.md が見つかりません。" >&2
  echo "      例: bash zk_extract_decision_flat_v1.sh dashboards/TREE_VIEW.md" >&2
  exit 1
fi

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

dbg "TARGET_FILE=$TARGET_FILE"
dbg "MARK_BASE=$MARK_BASE"

awk -v MARK="$MARK_BASE" '
function norm(s){
  gsub(/\r/, "", s)
  gsub(/\xEF\xB8\x8F/, "", s)  # VS16除去（🗳️️ -> 🗳️ に寄せる）
  return s
}
BEGIN{
  in_list = 0
  hit = 0
  h = 0
}
{
  line = norm($0)

  # ヘッダ（最初の箇条書きが出るまで）は保持
  if(!in_list){
    if(line ~ /^[[:space:]]*[-*+][[:space:]]/){
      in_list = 1
    } else {
      header[++h] = line
      next
    }
  }

  # 箇条書き行のみ対象
  if(line ~ /^[[:space:]]*[-*+][[:space:]]/){
    if(index(line, MARK) > 0){
      hit++
      sub(/^[[:space:]]+/, "", line)  # 平坦化
      out[hit] = line
    }
  }
}
END{
  if(hit == 0){
    exit 2
  }
  for(i=1;i<=h;i++) print header[i]
  for(i=1;i<=hit;i++) print out[i]
}
' "$TARGET_FILE" > "$TMP_OUT" || rc=$?

rc="${rc:-0}"
if (( rc == 2 )); then
  echo "[ERR] '${MARK_BASE}' を含む箇条書き行が 1件も見つかりません（上書きしません）。" >&2
  echo "      まずは次で実物を確認してください:" >&2
  echo "        grep -a -n \"${MARK_BASE}\" \"$TARGET_FILE\" | head" >&2
  exit 1
fi
(( rc == 0 )) || exit "$rc"

out_lines="$(wc -l < "$TMP_OUT" | tr -d ' ')"
if ! [[ "${out_lines:-0}" =~ ^[0-9]+$ ]] || (( out_lines == 0 )); then
  echo "[ERR] 出力が空になりました（上書きしません）。" >&2
  exit 1
fi

mv -f "$TMP_OUT" "$TARGET_FILE"
trap - EXIT

echo "[OK] decision-only(flat) extracted: $TARGET_FILE"

if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
