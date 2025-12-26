#!/usr/bin/env bash
# zk_prune_tree.sh
#
# 使い方: ./zk_prune_tree.sh 2
# 指定した階層（インデント）より深い「枝」を切り落とします。

set -Eeuo pipefail
export LC_ALL=C.UTF-8

# --- 設定 ---
OUTDIR_NAME="dashboards"
FIXED_FILENAME="TREE_VIEW.md"
ROOT="$(pwd)"
TARGET_FILE="${ROOT}/${OUTDIR_NAME}/${FIXED_FILENAME}"

# 引数チェック
MAX_DEPTH="${1:-}"
if [[ -z "$MAX_DEPTH" ]]; then
  echo "usage: $0 <depth_number>" >&2
  echo "example: $0 2 (質問番号のレベルまで表示し、その下のログは隠す)" >&2
  exit 1
fi

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] ${FIXED_FILENAME} が見つかりません。" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"

# --- フィルタリング処理 (AWK) ---
# あなたのマークダウン例に基づき、2スペース = 1インデントとして計算します。
awk -v max_d="$MAX_DEPTH" '
function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
BEGIN {
  indent_unit = 2
}
{
  # 改行コード \r を除去
  sub(/\r$/, "", $0)

  # 1. フロントマターやヘッダー、区切り線はそのまま通す
  if ($0 !~ /^[ ]*- /) {
    print $0
    next
  }

  # 2. 行頭のスペース数を正確にカウント
  match($0, /^[ ]*-/)
  space_count = RLENGTH - 1
  
  # 3. 現在の階層を計算 (第0階層 = 起点ノート)
  # 0スペース = 0, 2スペース = 1, 4スペース = 2...
  current_depth = space_count / indent_unit

  # 4. 指定した階層以内なら出力
  if (current_depth <= max_d) {
    print $0
  }
}
' "$TARGET_FILE" > "$TMP_FILE"

# 上書き保存
mv "$TMP_FILE" "$TARGET_FILE"

echo "[OK] Tree pruned to depth: $MAX_DEPTH"

# VS Code で開き直して反映
if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
