#!/usr/bin/env bash
# zk_make_dashboard_open.sh [TAG...]
# - cwd は Tasks 側で workspace に固定されている前提
# - ここでは cd しない
# - TAG を渡せばタグ条件で、無ければ全体

set -euo pipefail

if [[ $# -eq 0 ]]; then
  ./make_tag_dashboard.sh
elif [[ $# -eq 1 ]]; then
  ./make_tag_dashboard.sh "$1"
else
  # 複数タグは旧形式互換でANDを安全に表現
  TAGS="$*"
  ./make_tag_dashboard.sh "$TAGS" "ignored" "$PWD"
fi

if command -v code >/dev/null 2>&1; then
  code -r dashboards/default_dashboard.md
fi
