#!/usr/bin/env bash
# zk_extract_minutes_tree_v4.sh
#
# TREE_VIEW.md から「🕒付きの箇条書き行」を抽出し、
# 平坦化せず「階層構造（親子関係）」を維持して残します。
#
# 特徴:
# - 絵文字の Variation Selector-16 (U+FE0F) を除去してから検索（見た目が同じでも一致しない問題を回避）
# - 逆走査により、マークがある行の「親・先祖」も自動的に保持
#
set -Eeuo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}"

# --- 設定 ---
MARK_BASE="${MINUTES_MARK_BASE:-🕒}"
DBG="${ZK_DEBUG:-0}"

# エラーハンドリング
trap 'rc=$?; printf "[ERR] exit=%d line=%d cmd=%s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

dbg(){ if [[ "$DBG" != 0 ]]; then printf '[DBG] %s\n' "$*" >&2; fi; }

# ファイル探索関数
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
  exit 1
fi

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

dbg "TARGET_FILE=$TARGET_FILE"
dbg "MARK_BASE=$MARK_BASE"

# --- AWK 処理 ---
# 1. 行ごとの正規化（VS16除去）とマーク判定
# 2. 逆走査で「自分か子孫にマークがあるか」を判定して剪定
awk -v MARK="$MARK_BASE" -v INDENT_UNIT=2 '
function norm(s){
  gsub(/\r/, "", s)
  gsub(/\xEF\xB8\x8F/, "", s) # VS16 (U+FE0F) 除去
  return s
}
BEGIN {
  max_depth = 0
  hit_count = 0
}
{
  # 原文保持
  raw_line = $0
  lines[NR] = raw_line
  
  # 判定用正規化
  check_line = norm(raw_line)

  # リストアイテム判定 (- * +)
  if (check_line ~ /^[[:space:]]*[-*+][[:space:]]/) {
    is_list[NR] = 1
    
    # インデント深さ計算
    match(check_line, /^[[:space:]]*/)
    # インデントスペース数 / 単位(2) = 深さ
    d = int(RLENGTH / INDENT_UNIT)
    depth[NR] = d
    if (d > max_depth) max_depth = d

    # マーカー判定
    if (index(check_line, MARK) > 0) {
      has_mark[NR] = 1
      hit_count++
    } else {
      has_mark[NR] = 0
    }
  } else {
    # ヘッダーや空行などはリストではない
    is_list[NR] = 0
    depth[NR] = 0
    has_mark[NR] = 0
  }
}
END {
  # マーカーが1つもなければエラー終了（上書き防止）
  if (hit_count == 0) {
    exit 2
  }

  # --- 逆走査 (Reverse Scan) ---
  # 下から上にスキャンし、子が有効なら親も有効にする
  for (i = NR; i >= 1; i--) {
    if (!is_list[i]) {
      # リスト以外（ヘッダー等）は常に表示
      keep[i] = 1
      continue
    }

    d = depth[i]
    
    # 自分の直下(d+1)の階層で、有効なものがあったか？
    child_kept = agg[d + 1]

    # 自分にマークがある OR 子孫が有効なら、この行は残す
    is_kept = (has_mark[i] || child_kept) ? 1 : 0
    keep[i] = is_kept

    # 親への伝播用に集計 (兄弟のどれか一つでも有効なら親は有効)
    agg[d] = (agg[d] || is_kept) ? 1 : 0

    # 自分より深い階層の情報は、別の枝に影響しないようリセット
    # (現在の深さ d 以下の agg はクリアするが、実装上は d+1 以降をクリアで十分)
    for (k = d + 1; k <= max_depth + 1; k++) agg[k] = 0
  }

  # --- 出力 ---
  for (i = 1; i <= NR; i++) {
    if (keep[i]) print lines[i]
  }
}
' "$TARGET_FILE" > "$TMP_OUT" || rc=$?

# 終了コード判定
rc="${rc:-0}"
if (( rc == 2 )); then
  echo "[ERR] '${MARK_BASE}' を含む行が 1件も見つかりません（上書きしません）。" >&2
  echo "      grep等で確認してください。" >&2
  exit 1
fi
(( rc == 0 )) || exit "$rc"

# 空ファイルチェック
if [[ ! -s "$TMP_OUT" ]]; then
  echo "[ERR] 出力が空になりました（上書きしません）。" >&2
  exit 1
fi

# 上書き実行
mv -f "$TMP_OUT" "$TARGET_FILE"
trap - EXIT

echo "[OK] minutes extracted (tree structure preserved): $TARGET_FILE"

if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
