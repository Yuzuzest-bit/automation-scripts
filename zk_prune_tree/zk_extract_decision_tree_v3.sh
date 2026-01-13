#!/usr/bin/env bash
# zk_extract_decision_tree_v3.sh
#
# TREE_VIEW.md から「🗳️付きの箇条書き行」を抽出し、
# 平坦化せず「階層構造（親子関係）」を維持して残す。
#
# 特徴:
# - 絵文字の Variation Selector-16 (U+FE0F) を「行」と「検索キー」双方から除去して比較
# - 逆走査により、マークがある行の「親・先祖」も自動的に保持
#
set -Eeuo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}"

# --- 設定 ---
MARK_BASE="${DECISION_MARK_BASE:-🗳️}"
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
# 1. 正規化（VS16除去）を行い、検索キーと比較
# 2. 逆走査で「自分か子孫にマークがあるか」を判定して剪定
awk -v MARK_IN="$MARK_BASE" -v INDENT_UNIT=2 '
function strip_vs16(s){
  gsub(/\r/, "", s)
  gsub(/\xEF\xB8\x8F/, "", s)  # VS16除去（🗳️️問題対策）
  return s
}
BEGIN {
  # ★検索キー側も正規化（元のスクリプトの重要な修正を引き継ぎ）
  search_mark = strip_vs16(MARK_IN)
  
  max_depth = 0
  hit_count = 0
}
{
  # 原文保持
  raw_line = $0
  lines[NR] = raw_line
  
  # 判定用正規化
  check_line = strip_vs16(raw_line)

  # ヘッダー判定（リストが出るまではヘッダー扱いとして残す）
  if (check_line ~ /^[[:space:]]*[-*+][[:space:]]/) {
    is_list[NR] = 1
    
    # インデント深さ計算
    match(check_line, /^[[:space:]]*/)
    d = int(RLENGTH / INDENT_UNIT)
    depth[NR] = d
    if (d > max_depth) max_depth = d

    # マーカー判定
    if (index(check_line, search_mark) > 0) {
      has_mark[NR] = 1
      hit_count++
    } else {
      has_mark[NR] = 0
    }
  } else {
    # ヘッダーや空行などはリストではない（無条件で残す候補）
    is_list[NR] = 0
    keep[NR] = 1
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
      continue # ヘッダー等は既に keep=1
    }

    d = depth[i]
    
    # 直下の階層(d+1)で有効なものがあったか？
    child_kept = agg[d + 1]

    # 自分にマークがある OR 子孫が有効なら、この行は残す
    is_kept = (has_mark[i] || child_kept) ? 1 : 0
    keep[i] = is_kept

    # 親への伝播用に集計
    agg[d] = (agg[d] || is_kept) ? 1 : 0

    # 自分より深い階層の情報はクリア（別枝への干渉防止）
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
  echo "[ERR] '${MARK_BASE}'（decision）を含む行が 1件も見つかりません（上書きしません）。" >&2
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

echo "[OK] decision extracted (tree structure preserved): $TARGET_FILE"

if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
