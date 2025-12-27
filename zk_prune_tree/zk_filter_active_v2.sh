#!/usr/bin/env bash
# zk_filter_active_v2.sh
#
# 完璧な剪定:
# 「自分自身が進行中」または「子孫に進行中が含まれる」行だけを残し、
# 全てが ✅ で埋まった不要な枝を完全に削除します。
#
# 修正点:
# - 🔗 (already shown) は「進行中」ではないので Active 判定から除外
# - 🔁 (infinite loop) も進行中ではない扱いにしてノイズを減らす
# - 子孫探索を逆走査の O(N) に変更（高速＆安定）

set -Eeuo pipefail

# macOS で C.UTF-8 が無い環境でも落とさない
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# --- 設定 ---
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

# Active 扱いするアイコン（必要なら環境変数で上書き可能）
# 重要: 🔗 と 🔁 は Active にしない
ACTIVE_ICON_RE="${ACTIVE_ICON_RE:-📖|🎯|⏳|🧱|⚠️}"

# --- フィルタリング処理 (AWK) ---
awk -v INDENT_UNIT=2 -v ACTIVE_RE="(${ACTIVE_ICON_RE})" '
BEGIN {
  indent_unit = INDENT_UNIT
  active_re   = ACTIVE_RE
  max_depth   = 0
}
{
  sub(/\r$/, "", $0)
  lines[NR] = $0

  # リストアイテム（ノート）かどうか判定
  if ($0 ~ /^[ ]*- /) {
    is_list[NR] = 1

    match($0, /^[ ]*-/)
    depth[NR] = int((RLENGTH - 1) / indent_unit)
    if (depth[NR] > max_depth) max_depth = depth[NR]

    # その行単体で「進行中(Active)」かどうか判定
    # ✅ でも 🎯 / ⏳ などが付いていれば Active とみなす（あなたの運用に合わせる）
    if ($0 ~ active_re) {
      is_active_self[NR] = 1
    } else {
      is_active_self[NR] = 0
    }
  } else {
    is_list[NR] = 0
    depth[NR] = 0
    is_active_self[NR] = 0
  }
}
END {
  # 逆走査で「そのノード配下に Active があるか」を O(N) で確定する
  # agg[d] = 現在の親コンテキストにおける depth d の子孫側 Active 集計
  for (i = NR; i >= 1; i--) {
    if (!is_list[i]) {
      should_show[i] = 1
      continue
    }

    d = depth[i]
    child_active = agg[d + 1]
    active_subtree = (is_active_self[i] || child_active) ? 1 : 0

    should_show[i] = active_subtree

    # 自分を親側の集計に OR で足す（兄弟を畳み込む）
    agg[d] = (agg[d] || active_subtree) ? 1 : 0

    # これより深い階層は、別枝へ移ると漏れるのでクリア
    for (k = d + 1; k <= max_depth + 1; k++) agg[k] = 0
  }

  # 出力
  for (i = 1; i <= NR; i++) {
    if (should_show[i]) print lines[i]
  }
}
' "$TARGET_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "[OK] Active path strictly filtered."

if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
