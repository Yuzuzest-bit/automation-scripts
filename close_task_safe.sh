#!/usr/bin/env bash
# close_task_safe.sh <file> [--force]
set -eu
FILE="${1:-}"; [ -n "$FILE" ] || { echo "usage: $0 <markdown-file> [--force]"; exit 2; }
FORCE="${2:-}"
[ -f "$FILE" ] || { echo "No such file: $FILE"; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd -P)"
CHK="$HERE/zk_can_close.sh"
CLOSE="$HERE/close_task.sh"  # あなたの既存スクリプト

if [ "$FORCE" != "--force" ]; then
  if ! "$CHK" "$FILE"; then
    echo "[ABORT] Open items remain. (use --force to override)"
    exit 1
  fi
fi

"$CLOSE" "$FILE"
