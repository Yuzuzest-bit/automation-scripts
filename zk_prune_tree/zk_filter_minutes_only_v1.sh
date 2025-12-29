#!/usr/bin/env bash
# zk_filter_minutes_only_v1.sh
#
# minutes(🕒) だけ残す剪定:
# - 🕒 が付いた行、または「子孫に🕒が含まれる」行だけを残す
# - それ以外の枝は完全に削除
# - frontmatter/見出しなど「リスト行以外」は残す
#
# Optional env:
#   OUTDIR_NAME="dashboards"
#   FIXED_FILENAME="TREE_VIEW.md"
#   MINUTES_ICON_RE="🕒"   # 例: "🕒|📝" のように拡張も可能
#   INDENT_UNIT=2

set -Eeuo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

OUTDIR_NAME="${OUTDIR_NAME:-dashboards}"
FIXED_FILENAME="${FIXED_FILENAME:-TREE_VIEW.md}"
ROOT="$(pwd -P)"
TARGET_FILE="${ROOT}/${OUTDIR_NAME}/${FIXED_FILENAME}"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] ${FIXED_FILENAME} が見つかりません: $TARGET_FILE" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT

MINUTES_ICON_RE="${MINUTES_ICON_RE:-🕒}"
INDENT_UNIT="${INDENT_UNIT:-2}"

awk -v INDENT_UNIT="$INDENT_UNIT" -v MIN_RE="(${MINUTES_ICON_RE})" '
BEGIN{
  indent_unit = INDENT_UNIT + 0
  min_re = MIN_RE
  max_depth = 0
}
{
  sub(/\r$/, "", $0)
  lines[NR] = $0

  # ツリーのノート行（"- [[...]] ..."）判定：先頭 "- " を使う
  if ($0 ~ /^[ ]*- /) {
    is_list[NR] = 1

    match($0, /^[ ]*-/)
    depth[NR] = int((RLENGTH - 1) / indent_unit)
    if (depth[NR] > max_depth) max_depth = depth[NR]

    # 自分が minutes か？
    is_keep_self[NR] = ($0 ~ min_re) ? 1 : 0
  } else {
    is_list[NR] = 0
    depth[NR] = 0
    is_keep_self[NR] = 0
  }
}
END{
  # 逆走査: 子孫に minutes があるかを O(N) で集計
  for (i = NR; i >= 1; i--) {
    if (!is_list[i]) {
      should_show[i] = 1
      continue
    }

    d = depth[i]
    child_has = agg[d + 1]
    keep_subtree = (is_keep_self[i] || child_has) ? 1 : 0

    should_show[i] = keep_subtree

    agg[d] = (agg[d] || keep_subtree) ? 1 : 0

    for (k = d + 1; k <= max_depth + 1; k++) agg[k] = 0
  }

  for (i = 1; i <= NR; i++) {
    if (should_show[i]) print lines[i]
  }
}
' "$TARGET_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "[OK] Minutes-only tree filtered."

if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
