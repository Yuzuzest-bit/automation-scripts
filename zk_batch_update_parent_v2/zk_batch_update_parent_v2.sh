#!/usr/bin/env bash
set -uo pipefail

# ------------------------------------------------------------
# zk_batch_update_parent_v2.sh (win-optimized)
# Windows Git Bash 対応版
# ------------------------------------------------------------

INPUT_FILE="${1:-}"

if [[ -z "$INPUT_FILE" ]]; then
  echo "Usage: $(basename "$0") <parent_note_file>"
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "[ERR] File not found: $INPUT_FILE"
  exit 1
fi

# ============================================================
# 0. パスの絶対パス化と位置特定
# ============================================================
PARENT_DIR="$(cd "$(dirname "$INPUT_FILE")" && pwd)"
PARENT_FILENAME="$(basename "$INPUT_FILE")"
PARENT_FILE_FULL="${PARENT_DIR}/${PARENT_FILENAME}"

if command -v git >/dev/null 2>&1 && git -C "$PARENT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  WORKSPACE_ROOT="$(git -C "$PARENT_DIR" rev-parse --show-toplevel)"
else
  WORKSPACE_ROOT="$PARENT_DIR"
fi

# ============================================================
# 1. 親ノート(このファイル)のIDを取得する
# ============================================================
# 【重要】tr -d '\r' でCRを除去しないと、sedでの置換時にファイルが破損する原因になる
NEW_PARENT_ID=$(grep "^id:" "$PARENT_FILE_FULL" | head -n 1 | sed 's/^id:[[:space:]]*//' | tr -d '\r')

if [[ -z "$NEW_PARENT_ID" ]]; then
  echo "[ERR] Could not find 'id:' field in $PARENT_FILENAME."
  exit 1
fi

echo "[INFO] Processing: $PARENT_FILE_FULL"
echo "[INFO] New Parent ID: $NEW_PARENT_ID"

# ============================================================
# 2. リンク抽出とファイル探索
# ============================================================

# 【重要】ここでも \r を除去
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

  # --- ファイル探索 ---
  TARGET_FILE=""

  if [[ -f "${PARENT_DIR}/${LINK_NAME}.md" ]]; then
    TARGET_FILE="${PARENT_DIR}/${LINK_NAME}.md"
  else
    FOUND_PATH=$(find "$WORKSPACE_ROOT" -name "${LINK_NAME}.md" -print -quit 2>/dev/null)
    if [[ -n "$FOUND_PATH" ]]; then
      TARGET_FILE="$FOUND_PATH"
    fi
  fi

  # --- 更新実行 ---
  if [[ -z "$TARGET_FILE" ]]; then
    echo "[SKIP] Not found in workspace: ${LINK_NAME}.md"
    continue
  fi

  # ============================================================
  # 3. parentフィールドの書き換え
  # ============================================================
  echo "-------------------------------------------------------"
  echo "[PROC] Updating: ${LINK_NAME}"

  if grep -q "^parent:" "$TARGET_FILE"; then
    # Git Bash (MSYS/MINGW) は GNU sed ベースなので Linux と同じ構文でOK
    # ただし uname が "MINGW64..." 等になるため、Darwin 分岐には入らない
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s/^parent: .*/parent: ${NEW_PARENT_ID}/" "$TARGET_FILE"
    else
      # Windows (Git Bash) / Linux
      sed -i "s/^parent: .*/parent: ${NEW_PARENT_ID}/" "$TARGET_FILE"
    fi
    echo "[SUCCESS] Updated parent to: $NEW_PARENT_ID"
  else
    echo "[WARN] No 'parent:' field found. Skipping."
  fi

done

echo "-------------------------------------------------------"
echo "[DONE] Batch update finished."
