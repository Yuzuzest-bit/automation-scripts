#!/usr/bin/env bash
set -uo pipefail

# ------------------------------------------------------------
# zk_batch_close_children.sh (v3-win-debug)
# Windows Git Bash 対応 + 検索ロジック強化版
# ------------------------------------------------------------

INPUT_FILE="${1:-}"

# --- ヘルプ / 引数チェック ---
if [[ -z "$INPUT_FILE" ]]; then
  echo "Usage: $(basename "$0") <dashboard_file>"
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "[ERR] File not found: $INPUT_FILE"
  exit 1
fi

# --- 依存スクリプト (close_task_safe.sh) の場所特定 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOSE_SCRIPT="${SCRIPT_DIR}/close_task_safe.sh"

if [[ ! -f "$CLOSE_SCRIPT" ]]; then
  echo "[ERR] 'close_task_safe.sh' not found in $SCRIPT_DIR"
  exit 1
fi

# ============================================================
# 0. パス設定
# ============================================================
PARENT_DIR="$(cd "$(dirname "$INPUT_FILE")" && pwd)"
PARENT_FILENAME="$(basename "$INPUT_FILE")"
PARENT_FILE_FULL="${PARENT_DIR}/${PARENT_FILENAME}"

# ワークスペースルートの特定（ここでも改行コードを除去）
if [ -z "${WORKSPACE_ROOT:-}" ]; then
  if command -v git >/dev/null 2>&1 && git -C "$PARENT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    WORKSPACE_ROOT="$(git -C "$PARENT_DIR" rev-parse --show-toplevel | tr -d '\r')"
  else
    WORKSPACE_ROOT="$PARENT_DIR"
  fi
fi

echo "[INFO] Scanning $PARENT_FILENAME..."
echo "[INFO] Workspace Root: $WORKSPACE_ROOT"

# ============================================================
# 1. リンク抽出とファイル探索
# ============================================================

# 改行コード(\r)を除去してリンク抽出
LINKS_RAW=$(grep -oE '\[\[[^]|]+(\|[^]]+)?\]\]' "$PARENT_FILE_FULL" | tr -d '\r' || true)

if [[ -z "$LINKS_RAW" ]]; then
  echo "[WARN] No wikilinks found in $PARENT_FILENAME."
  exit 0
fi

SORTED_LINKS=$(echo "$LINKS_RAW" | sort -u)

IFS=$'\n'
for RAW_LINK in $SORTED_LINKS; do
  # [[Link|Alias]] -> Link に整形
  LINK_NAME=$(echo "$RAW_LINK" | sed -E 's/^\[\[//; s/\]\]$//; s/\|.*//')

  # ファイル名自身の場合はスキップ
  PARENT_NAME_NO_EXT="${PARENT_FILENAME%.*}"
  if [[ "$LINK_NAME" == "$PARENT_NAME_NO_EXT" ]]; then
    continue
  fi

  # --- ファイル探索ロジック (強化版) ---
  TARGET_FILE=""

  # 1. 親ファイルと同じディレクトリにあるか？
  if [[ -f "${PARENT_DIR}/${LINK_NAME}.md" ]]; then
    TARGET_FILE="${PARENT_DIR}/${LINK_NAME}.md"

  # 2. ワークスペース全体から探す
  else
    # [DEBUG] どこを探しているか表示（不要ならコメントアウトしてください）
    # echo "[DEBUG] Searching for '${LINK_NAME}.md' in '$WORKSPACE_ROOT'..."

    # 修正点: -name ではなく -iname を使用（大文字小文字を無視）
    FOUND_PATH=$(find "$WORKSPACE_ROOT" -iname "${LINK_NAME}.md" -print -quit 2>/dev/null)
    
    if [[ -n "$FOUND_PATH" ]]; then
      TARGET_FILE="$FOUND_PATH"
    fi
  fi

  # --- 実行 ---
  if [[ -z "$TARGET_FILE" ]]; then
    # 見つからない場合、何を探してダメだったか詳細を出す
    echo "[SKIP] Not found: ${LINK_NAME}.md"
    continue
  fi

  echo "-------------------------------------------------------"
  echo "[PROC] Closing: ${LINK_NAME}"
  # echo "[DEBUG] Path: $TARGET_FILE"

  if bash "$CLOSE_SCRIPT" "$TARGET_FILE"; then
    echo "[SUCCESS] Closed: ${LINK_NAME}"
  else
    echo "[FAIL] Could not close: ${LINK_NAME}"
  fi

done

echo "-------------------------------------------------------"
echo "[DONE] Batch close operation finished."
