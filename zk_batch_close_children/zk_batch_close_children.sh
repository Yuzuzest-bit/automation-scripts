#!/usr/bin/env bash
set -uo pipefail

# ------------------------------------------------------------
# zk_batch_close_children.sh
# ------------------------------------------------------------

# VSCodeから渡されるWindows形式のパスをUnix形式に変換
PARENT_FILE_RAW="${1:-}"
if [[ -z "$PARENT_FILE_RAW" ]]; then
  echo "Usage: $(basename "$0") <dashboard_file>"
  exit 1
fi
PARENT_FILE=$(SystemRoot=C: cygpath -u "$PARENT_FILE_RAW" 2>/dev/null || echo "$PARENT_FILE_RAW")

if [[ ! -f "$PARENT_FILE" ]]; then
  echo "[ERR] File not found: $PARENT_FILE"
  exit 1
fi

# スクリプト自身の場所を特定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOSE_SCRIPT="${SCRIPT_DIR}/close_task_safe.sh"

if [[ ! -f "$CLOSE_SCRIPT" ]]; then
  echo "[ERR] 'close_task_safe.sh' not found in $SCRIPT_DIR"
  exit 1
fi

# ワークスペースルートの特定
PARENT_DIR="$(cd "$(dirname "$PARENT_FILE")" && pwd)"
if command -v git >/dev/null 2>&1 && git -C "$PARENT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  WORKSPACE_ROOT="$(git -C "$PARENT_DIR" rev-parse --show-toplevel)"
else
  WORKSPACE_ROOT="$PARENT_DIR"
fi

echo "[INFO] Scanning $(basename "$PARENT_FILE")..."
echo "[INFO] Workspace Root: $WORKSPACE_ROOT"

# WikiLinkの抽出
LINKS_RAW=$(grep -oE '\[\[[^]|]+(\|[^]]+)?\]\]' "$PARENT_FILE" || true)

if [[ -z "$LINKS_RAW" ]]; then
  echo "[WARN] No wikilinks found."
  exit 0
fi

# 重複排除
SORTED_LINKS=$(echo "$LINKS_RAW" | sort -u)

IFS=$'\n'
for RAW_LINK in $SORTED_LINKS; do
  LINK_NAME=$(echo "$RAW_LINK" | sed -E 's/^\[\[//; s/\]\]$//; s/\|.*//')
  
  # 自分自身はスキップ
  if [[ "$LINK_NAME" == "$(basename "$PARENT_FILE" .md)" ]]; then continue; fi

  TARGET_FILE=""
  # 探索ロジック（findを使用）
  # Windows環境のfindと混同しないよう、Git Bashのfindを明示的に使う工夫
  FOUND_PATH=$(find "$WORKSPACE_ROOT" -name "${LINK_NAME}.md" -print -quit 2>/dev/null)

  if [[ -n "$FOUND_PATH" ]]; then
    TARGET_FILE="$FOUND_PATH"
  fi

  if [[ -z "$TARGET_FILE" ]]; then
    echo "[SKIP] Not found: ${LINK_NAME}.md"
    continue
  fi

  echo "-------------------------------------------------------"
  echo "[PROC] Closing: ${LINK_NAME}"

  # close_task_safe.sh を実行
  # 実行権限がない場合に備えて bash で呼び出す
  if bash "$CLOSE_SCRIPT" "$TARGET_FILE"; then
    echo "[SUCCESS] Closed: ${LINK_NAME}"
  else
    echo "[FAIL] Failed: ${LINK_NAME}"
  fi
done

echo "-------------------------------------------------------"
echo "[DONE] Finished."
