#!/usr/bin/env bash
# zk_filter_link_safeguard_v1.sh
#
# - Active(進行中) が「自分 or 子孫」にある枝だけ残す（完全剪定）
# - 🔗 行は原則削除
# - ただし 🔗 行の子孫に Active がある場合は、🔗 行は削除しない（保険）

set -Eeuo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

OUTDIR_NAME="dashboards"
FIXED_FILENAME="TREE_VIEW.md"
ROOT="$(pwd)"
TARGET_FILE="${ROOT}/${OUTDIR_NAME}/${FIXED_FILENAME}"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] ${FIXED_FILENAME} が見つかりません: $TARGET_FILE" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT

# 🔗 と 🔁 は Active にしない（元運用踏襲）
ACTIVE_ICON_RE="${ACTIVE_ICON_RE:-📖|🎯|⏳|🧱|⚠️}"
DROP_ICON_RE="${DROP_ICON_RE:-🔗}"

awk -v INDENT_UNIT=2 \
    -v ACTIVE_RE="(${ACTIVE_ICON_RE})" \
    -v DROP_RE="(${DROP_ICON_RE})" '
BEGIN {
  indent_unit = INDENT_UNIT
  active_re   = ACTIVE_RE
  drop_re     = DROP_RE
  max_depth   = 0
}
{
  sub(/\r$/, "", $0)
  lines[NR] = $0

  has_drop[NR] = ($0 ~ drop_re) ? 1 : 0

  if ($0 ~ /^[ ]*- /) {
    is_list[NR] = 1
    match($0, /^[ ]*-/)
    depth[NR] = int((RLENGTH - 1) / indent_unit)
    if (depth[NR] > max_depth) max_depth = depth[NR]

    is_active_self[NR] = ($0 ~ active_re) ? 1 : 0
  } else {
    is_list[NR] = 0
    depth[NR] = 0
    is_active_self[NR] = 0
  }
}
END {
  # 逆走査で subtree active を確定（O(N)）
  for (i = NR; i >= 1; i--) {
    if (!is_list[i]) {
      should_show[i] = 1
      subtree_active[i] = 0
      continue
    }

    d = depth[i]
    child_active = agg[d + 1]
    active_subtree = (is_active_self[i] || child_active) ? 1 : 0

    subtree_active[i] = active_subtree
    should_show[i] = active_subtree

    agg[d] = (agg[d] || active_subtree) ? 1 : 0
    for (k = d + 1; k <= max_depth + 1; k++) agg[k] = 0
  }

  # 出力
  for (i = 1; i <= NR; i++) {
    if (!should_show[i]) continue

    # 🔗 行は原則消す。ただし「子孫に Active がある」なら残す（保険）
    if (has_drop[i] && subtree_active[i] == 0) continue

    print lines[i]
  }
}
' "$TARGET_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "[OK] Active path strictly filtered (+ drop 🔗 unless it protects active descendants)."

if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
