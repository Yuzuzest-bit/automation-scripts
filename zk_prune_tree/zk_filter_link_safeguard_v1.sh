#!/usr/bin/env bash
# zk_filter_drop_link_keep_children_v1.sh
#
# - Active(進行中) が「自分 or 子孫」にある枝だけ残す（完全剪定）
# - 🔗 を含む “行だけ” は必ず削除（📖🔗でも削除）
# - 🔗 行の配下（子孫）は削除しない
#   └ ツリーが崩れないよう、子孫のインデントを1段持ち上げて出力する

set -Eeuo pipefail
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

OUTDIR_NAME="dashboards"
FIXED_FILENAME="TREE_VIEW.md"
ROOT="$(pwd)"

# 引数があればそれを処理。無ければ dashboards/TREE_VIEW.md
TARGET_FILE="${1:-${ROOT}/${OUTDIR_NAME}/${FIXED_FILENAME}}"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] file not found: $TARGET_FILE" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT

# 🔗 と 🔁 は Active にしない（元運用踏襲）
ACTIVE_ICON_RE="${ACTIVE_ICON_RE:-📖|🎯|⏳|🧱|⚠️}"
# 削除対象（行だけ消す）
DROP_ICON_RE="${DROP_ICON_RE:-🔗}"
# インデント幅（あなたのツリーが2スペースなので既定2）
INDENT_UNIT="${INDENT_UNIT:-2}"

awk -v INDENT_UNIT="$INDENT_UNIT" \
    -v ACTIVE_RE="(${ACTIVE_ICON_RE})" \
    -v DROP_RE="(${DROP_ICON_RE})" '
BEGIN {
  indent_unit = INDENT_UNIT + 0
  active_re   = ACTIVE_RE
  drop_re     = DROP_RE
  max_depth   = 0
}
{
  sub(/\r$/, "", $0)
  lines[NR] = $0

  if ($0 ~ /^[ ]*- /) {
    is_list[NR] = 1

    match($0, /^[ ]*-/)
    depth[NR] = int((RLENGTH - 1) / indent_unit)
    if (depth[NR] > max_depth) max_depth = depth[NR]

    has_drop[NR] = ($0 ~ drop_re) ? 1 : 0
    is_active_self[NR] = ($0 ~ active_re) ? 1 : 0
  } else {
    is_list[NR] = 0
    depth[NR] = 0
    has_drop[NR] = 0
    is_active_self[NR] = 0
  }
}
END {
  # --- 逆走査で「そのノード配下に Active があるか」を O(N) で確定 ---
  for (i = NR; i >= 1; i--) {
    if (!is_list[i]) {
      should_show[i] = 1
      continue
    }

    d = depth[i]
    child_active = agg[d + 1]
    active_subtree = (is_active_self[i] || child_active) ? 1 : 0

    should_show[i] = active_subtree

    agg[d] = (agg[d] || active_subtree) ? 1 : 0
    for (k = d + 1; k <= max_depth + 1; k++) agg[k] = 0
  }

  # --- 前走査で出力（🔗行だけ消して、子孫はインデントを持ち上げる） ---
  drop_top = 0
  for (i = 1; i <= NR; i++) {
    if (!should_show[i]) continue

    if (!is_list[i]) {
      print lines[i]
      continue
    }

    d = depth[i]

    # 枝を抜けたら drop スタックを戻す
    while (drop_top > 0 && d <= drop_depth[drop_top]) drop_top--

    # 何段持ち上げるか（drop祖先の数）
    shift = drop_top
    new_depth = d - shift
    if (new_depth < 0) new_depth = 0

    if (has_drop[i]) {
      # 🔗行は必ず消す（📖🔗でも消す）
      # ただし配下は残すので、以降を1段持ち上げるために深さを積む
      drop_top++
      drop_depth[drop_top] = d
      continue
    }

    # リスト項目をインデント調整して出力
    line = lines[i]
    if (match(line, /^[ ]*-[ ]/)) {
      item = substr(line, RLENGTH + 1)
      out_indent = new_depth * indent_unit
      printf("%*s- %s\n", out_indent, "", item)
    } else {
      print line
    }
  }
}
' "$TARGET_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "[OK] Active path strictly filtered (+ drop 🔗 lines, keep children)."

if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
