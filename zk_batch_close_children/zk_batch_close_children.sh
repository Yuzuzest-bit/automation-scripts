#!/usr/bin/env bash
set -uo pipefail

# ------------------------------------------------------------
# zk_batch_close_children.sh (v5-root-fix)
# Windows共有フォルダ等でGit判定が失敗する場合に対応した
# 「フォルダ遡り」によるルート検出版
# ------------------------------------------------------------

RAW_INPUT="${1:-}"

# --- 引数チェック ---
if [[ -z "$RAW_INPUT" ]]; then
  echo "Usage: $(basename "$0") <dashboard_file>"
  exit 1
fi

# ============================================================
# 1. パス変換 (Windows -> Unix)
# ============================================================
if command -v cygpath >/dev/null 2>&1; then
  INPUT_FILE="$(cygpath -u "$RAW_INPUT")"
else
  INPUT_FILE="$RAW_INPUT"
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "[ERR] File not found: $INPUT_FILE"
  exit 1
fi

# 依存スクリプト確認
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOSE_SCRIPT="${SCRIPT_DIR}/close_task_safe.sh"

if [[ ! -f "$CLOSE_SCRIPT" ]]; then
  echo "[ERR] 'close_task_safe.sh' not found in $SCRIPT_DIR"
  exit 1
fi

# ============================================================
# 2. 強力なルートフォルダ検出ロジック
# ============================================================
PARENT_DIR="$(cd "$(dirname "$INPUT_FILE")" && pwd)"
PARENT_FILENAME="$(basename "$INPUT_FILE")"
PARENT_FILE_FULL="${PARENT_DIR}/${PARENT_FILENAME}"

# 関数: .git または .obsidian がある場所まで親を遡る
find_project_root() {
  local dir="$1"
  local root="/"

  # Git Bash等のルートに到達するまでループ
  while [[ "$dir" != "$root" && "$dir" != "." && "$dir" != "/" ]]; do
    # .git または .obsidian があればそこをルートとみなす
    if [[ -d "$dir/.git" || -d "$dir/.obsidian" ]]; then
      echo "$dir"
      return
    fi
    # 親ディレクトリへ
    dir="$(dirname "$dir")"
  done

  # 見つからなかった場合は、元の親ディレクトリを返す
  echo "$1"
}

# ルート検出実行
WORKSPACE_ROOT=$(find_project_root "$PARENT_DIR")

echo "[DEBUG] Input(Win): $RAW_INPUT"
echo "[DEBUG] Input(Unix): $INPUT_FILE"
echo "[INFO] Workspace Root: $WORKSPACE_ROOT"
echo "[INFO] Scanning $PARENT_FILENAME..."

# ============================================================
# 3. リンク抽出とファイル探索
# ============================================================

# 改行コード除去
LINKS_RAW=$(grep -oE '\[\[[^]|]+(\|[^]]+)?\]\]' "$PARENT_FILE_FULL" | tr -d '\r' || true)

if [[ -z "$LINKS_RAW" ]]; then
  echo "[WARN] No wikilinks found in $PARENT_FILENAME."
  exit 0
fi

SORTED_LINKS=$(echo "$LINKS_RAW" | sort -u)

IFS=$'\n'
for RAW_LINK in $SORTED_LINKS; do
  LINK_NAME=$(echo "$RAW_LINK" | sed -E 's/^\[\[//; s/\]\]$//; s/\|.*//')

  PARENT_NAME_NO_EXT="${PARENT_FILENAME%.*}"
  if [[ "$LINK_NAME" == "$PARENT_NAME_NO_EXT" ]]; then
    continue
  fi

  # --- ファイル探索ロジック ---
  TARGET_FILE=""

  # 1. 同じフォルダにあるか？
  if [[ -f "${PARENT_DIR}/${LINK_NAME}.md" ]]; then
    TARGET_FILE="${PARENT_DIR}/${LINK_NAME}.md"

  # 2. ワークスペース全体から探す (ルートから -iname で検索)
  else
    # 検索範囲が正しくなったので見つかるはず
    FOUND_PATH=$(find "$WORKSPACE_ROOT" -iname "${LINK_NAME}.md" -print -quit 2>/dev/null)
    if [[ -n "$FOUND_PATH" ]]; then
      TARGET_FILE="$FOUND_PATH"
    fi
  fi

  # --- 実行 ---
  if [[ -z "$TARGET_FILE" ]]; then
    echo "[SKIP] Not found in workspace: ${LINK_NAME}.md"
    continue
  fi

  echo "-------------------------------------------------------"
  echo "[PROC] Closing: ${LINK_NAME}"

  if bash "$CLOSE_SCRIPT" "$TARGET_FILE"; then
    echo "[SUCCESS] Closed: ${LINK_NAME}"
  else
    echo "[FAIL] Could not close: ${LINK_NAME}"
  fi

done

echo "-------------------------------------------------------"
echo "[DONE] Batch close operation finished."
