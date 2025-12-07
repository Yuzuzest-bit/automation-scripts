#!/usr/bin/env bash
# zk_search_tag_ad_hoc.sh "<query>" [ROOT]
# - ad hoc で入力したタグクエリを使って search_tag.sh を実行
# - 実行後に dashboards/tags_search.md を開く
# - 拡張なし / Pythonなし

set -euo pipefail

QUERY="${1:-}"
ROOT="${2:-$PWD}"

cd "$ROOT"

if [[ -z "$QUERY" ]]; then
  # クエリ空なら全件検索
  ./search_tag.sh
else
  # "issue -zk-archive ..." を配列化して渡す
  read -r -a args <<< "$QUERY"
  ./search_tag.sh "${args[@]}"
fi

# 結果を開く（code がある環境だけ）
if command -v code >/dev/null 2>&1; then
  code -r dashboards/tags_search.md
fi
