#!/usr/bin/env bash
# close_task_safe.sh <file> [--force]
set -eu

FILE_IN="${1:-}"; [ -n "$FILE_IN" ] || { echo "usage: $0 <markdown-file> [--force]"; exit 2; }
FORCE="${2:-}"

# Windowsパス→POSIX
FILE="$FILE_IN"
if command -v cygpath >/dev/null 2>&1; then
  [[ "$FILE" =~ ^[A-Za-z]:\\ ]] && FILE="$(cygpath -u "$FILE")"
fi
[ -f "$FILE" ] || { echo "No such file: $FILE_IN (resolved: $FILE)"; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROLL_NOTE="$HERE/note_rollup.sh"
ROLL_CHILD="$HERE/zk_children_rollup.sh"
CHK="$HERE/zk_can_close.sh"
CLOSE="$HERE/close_task.sh"

# ワークスペース根（VS Code から環境変数で渡すと安定）
ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "$FILE")" && pwd -P)}"
export WORKSPACE_ROOT="$ROOT"

# 1) 常に最新化（Rollup / Children）
"$ROLL_NOTE"   "$FILE"
"$ROLL_CHILD"  "$FILE"

# 2) 判定（--force が無ければブロック）
if [ "$FORCE" != "--force" ]; then
  if ! "$CHK" "$FILE"; then
    echo "[ABORT] Open tasks/children remain. Use --force to override."
    exit 1
  fi
fi

# 3) クローズ実行
"$CLOSE" "$FILE"
