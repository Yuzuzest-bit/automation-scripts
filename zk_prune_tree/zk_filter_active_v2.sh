#!/usr/bin/env bash
# zk_filter_active_v2.sh
#
# 完璧な剪定:
# 「自分自身が進行中」または「子孫に進行中が含まれる」行だけを残し、
# 全てが ✅ で埋まった不要な枝を完全に削除します。

set -Eeuo pipefail
export LC_ALL=C.UTF-8

# --- 設定 ---
OUTDIR_NAME="dashboards"
FIXED_FILENAME="TREE_VIEW.md"
ROOT="$(pwd)"
TARGET_FILE="${ROOT}/${OUTDIR_NAME}/${FIXED_FILENAME}"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] ${FIXED_FILENAME} が見つかりません。" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"

# --- フィルタリング処理 (AWK) ---
awk '
function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
BEGIN {
  indent_unit = 2
}
{
  sub(/\r$/, "", $0)
  lines[NR] = $0
  
  # リストアイテム（ノート）かどうか判定
  if ($0 ~ /^[ ]*- /) {
    is_list[NR] = 1
    match($0, /^[ ]*-/)
    depth[NR] = (RLENGTH - 1) / indent_unit
    
    # その行単体で「進行中(Active)」かどうか判定
    # ✅ 以外のアイコンがある場合は Active とみなす
    if ($0 ~ /📖|🎯|⏳|🧱|⚠️|🔁|🔗/) {
      is_active_self[NR] = 1
    } else {
      is_active_self[NR] = 0
    }
  } else {
    is_list[NR] = 0
    is_active_self[NR] = 0
  }
}
END {
  # 1. 全ての行について「自分自身または子孫が Active か」を判定
  for (i = 1; i <= NR; i++) {
    if (!is_list[i]) {
      should_show[i] = 1
      continue
    }

    # 自分が Active なら表示確定
    if (is_active_self[i]) {
      should_show[i] = 1
      continue
    }

    # 自分が ✅ でも、子孫に一つでも Active があれば表示する
    has_active_descendant = 0
    for (j = i + 1; j <= NR; j++) {
      # 自分の階層と同じか、それより浅い行が出てきたら枝の終了
      if (is_list[j] && depth[j] <= depth[i]) break
      
      # 子孫に Active 発見
      if (is_list[j] && is_active_self[j]) {
        has_active_descendant = 1
        break
      }
    }
    
    if (has_active_descendant) {
      should_show[i] = 1
    } else {
      should_show[i] = 0
    }
  }

  # 2. 確定した行のみを出力
  for (i = 1; i <= NR; i++) {
    if (should_show[i]) {
      print lines[i]
    }
  }
}
' "$TARGET_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$TARGET_FILE"

echo "[OK] Active path strictly filtered."

if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
