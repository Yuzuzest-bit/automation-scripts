#!/usr/bin/env bash
# open_hub.sh <hub-key> [ROOT_DIR]
# ハブ名（nwsp / pm / work など）に応じて、対応するハブノートを VS Code で開く
# macOS / Windows(Git Bash) 共通

set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: $0 <hub-key> [ROOT_DIR]

hub-key:
  nwsp   - NWSP 対策用ハブノート
  pm     - PM / プロジェクトマネジメント系ハブ
  work   - 仕事全般ハブ

ROOT_DIR:
  省略時は ZK_ROOT, WORKSPACE_ROOT, PWD の順で使用
EOF
  exit 2
}

HUB_KEY="${1:-}"
ROOT_ARG="${2:-}"

if [ -z "${HUB_KEY}" ]; then
  usage
fi

# ---------- ROOT解決 ----------
if [ -n "${ROOT_ARG}" ]; then
  ROOT="${ROOT_ARG}"
elif [ -n "${ZK_ROOT:-}" ]; then
  ROOT="${ZK_ROOT}"
elif [ -n "${WORKSPACE_ROOT:-}" ]; then
  ROOT="${WORKSPACE_ROOT}"
else
  ROOT="$PWD"
fi

# ---------- ハブキー→相対パスのマッピング ----------
# ★ここを自分の実際の構成に合わせて変更してください
case "${HUB_KEY}" in
  nwsp)
    # 例: ROOT/NWSP_HUB.md
    HUB_REL="NWSP_HUB.md"
    ;;
  pm)
    # 例: ROOT/PM_HUB.md
    HUB_REL="PM_HUB.md"
    ;;
  work)
    # 例: ROOT/WORK_HUB.md
    HUB_REL="WORK_HUB.md"
    ;;
  *)
    echo "Unknown hub key: ${HUB_KEY}" >&2
    usage
    ;;
esac

HUB_PATH="${ROOT}/${HUB_REL}"

if [ ! -f "${HUB_PATH}" ]; then
  echo "Hub note not found: ${HUB_PATH}" >&2
  exit 1
fi

# ---------- VS Code で開く ----------
# 既存ウィンドウを再利用 (-r)
code -r "${HUB_PATH}"
