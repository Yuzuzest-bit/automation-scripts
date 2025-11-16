#!/usr/bin/env bash
# open_nwsp_hub.sh [ROOT_DIR]
# NWSP対策用ハブノートを VS Code で開く（mac / Windows Git Bash 両対応）

set -euo pipefail

ROOT_ARG="${1:-}"

# ROOT 解決ロジック
if [ -n "$ROOT_ARG" ]; then
  ROOT="$ROOT_ARG"
elif [ -n "${ZK_ROOT:-}" ]; then
  ROOT="$ZK_ROOT"
elif [ -n "${WORKSPACE_ROOT:-}" ]; then
  ROOT="$WORKSPACE_ROOT"
else
  ROOT="$PWD"
fi

# ★ここだけ自分の実際のパスに合わせて変更してください
# 例: ルート直下の nwsp フォルダにハブノートを置く場合
HUB_REL="nwsp/NWSP_HUB.md"

HUB_PATH="$ROOT/$HUB_REL"

if [ ! -f "$HUB_PATH" ]; then
  echo "Hub note not found: $HUB_PATH" >&2
  exit 1
fi

# VS Code の既存ウィンドウを再利用して開く
code -r "$HUB_PATH"
