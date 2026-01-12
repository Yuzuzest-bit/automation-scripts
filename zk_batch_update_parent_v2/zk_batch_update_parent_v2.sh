#!/usr/bin/env bash
set -uo pipefail

# ------------------------------------------------------------
# zk_batch_update_parent_v2.sh (v3-win-fix)
# Windows Git Bash 対応版 (パス変換・ルート自動検出・iname検索)
# ------------------------------------------------------------

RAW_INPUT="${1:-}"

# --- ヘルプ / 引数チェック ---
if [[ -z "$RAW_INPUT" ]]; then
  echo "Usage: $(basename "$0") <parent_note_file>"
  exit 1
fi

# ============================================================
# 1. パス変換 (Windows -> Unix)
# VS Codeから渡される "C:\Users\..." を "/c/Users/..." に変換
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

# ============================================================
# 2. 強力なルートフォルダ検出ロジック
# Gitコマンドが失敗する場合に備え、.git/.obsidianを探して遡る
# ============================================================
PARENT_DIR="$(cd "$(dirname "$INPUT_FILE")" && pwd)"
PARENT_FILENAME="$(basename "$INPUT_FILE")"
PARENT_FILE_FULL="${PARENT_DIR}/${PARENT_FILENAME}"

# 関数: .git または .obsidian がある場所まで親を遡る
find_project_root() {
  local dir="$1"
  local root="/"
  
  # ルートに到達するまでループ
  while [[ "$dir" != "$root" && "$dir" != "." && "$dir" != "/" ]]; do
    if [[ -d "$dir/.git" || -d "$dir/.obsidian" ]]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done
  
  # 見つからなかった場合は元の親ディレクトリを返す
  echo "$1"
}

WORKSPACE_ROOT=$(find_project_root "$PARENT_DIR")

# ============================================================
# 3. 親ノート(このファイル)のIDを取得する
# ============================================================
# 【重要】tr -d '\r' でCRを除去しないと、sedでの置換時にファイルが破損する
NEW_PARENT_ID=$(grep "^id:" "$PARENT_FILE_FULL" | head -n 1 | sed 's/^id:[[:space:]]*//' | tr -d '\r')

if [[ -z "$NEW_PARENT_ID" ]]; then
  echo "[ERR] Could not find 'id:' field in $PARENT_FILENAME."
  exit 1
fi

echo "[INFO] Processing: $PARENT_FILE_FULL"
echo "[INFO] Workspace Root: $WORKSPACE_ROOT"
echo "[INFO] New Parent ID: $NEW_PARENT_ID"

# ============================================================
# 4. リンク抽出とファイル探索
# ============================================================

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

  # --- ファイル探索 (修正版) ---
  TARGET_FILE=""

  # 1. 親ファイルと同じディレクトリ
  if [[ -f "${PARENT_DIR}/${LINK_NAME}.md" ]]; then
    TARGET_FILE="${PARENT_DIR}/${LINK_NAME}.md"
  else
    # 2. ワークスペース全体 (ルートから -iname で検索)
    #    Git Bashのfindは大文字小文字を区別するため -iname を使用
    FOUND_PATH=$(find "$WORKSPACE_ROOT" -iname "${LINK_NAME}.md" -print -quit 2>/dev/null)
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
  # 5. parentフィールドの書き換え
  # ============================================================
  echo "-------------------------------------------------------"
  echo "[PROC] Updating: ${LINK_NAME}"

  if grep -q "^parent:" "$TARGET_FILE"; then
    if [[ "$(uname)" == "Darwin" ]]; then
      # Mac
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
