#!/usr/bin/env bash
# zk_search_tag_text_from_pick.sh "<label | query>" "<text>" [ROOT]
# - 拡張なし / Pythonなし
# - Tasks inputs を橋渡しするだけ

set -euo pipefail

RAW="${1:-}"
TEXT="${2:-}"
ROOT="${3:-$PWD}"

if [[ -z "$RAW" ]]; then
  echo "usage: zk_search_tag_text_from_pick.sh \"label | query\" \"text\" [ROOT]" >&2
  exit 2
fi

cd "$ROOT"

trim() {
  local s="$1"
  s="${s#"${s%%[!$' \t\r\n']*}"}"
  s="${s%"${s##*[!$' \t\r\n']}"}"
  printf '%s' "$s"
}

QUERY="$(
  printf '%s' "$RAW" |
    awk -F'|' '{
      if (NF >= 2) print $2;
      else print $0;
    }'
)"
QUERY="$(trim "$QUERY")"
TEXT="$(trim "$TEXT")"

if [[ -z "$TEXT" ]]; then
  # テキスト条件なしでも新スクリプトで統一してOK
  # shellcheck disable=SC2086
  ./search_tag_text.sh $QUERY
else
  # shellcheck disable=SC2086
  ./search_tag_text.sh --text "$TEXT" $QUERY
fi

if command -v code >/dev/null 2>&1; then
  code -r dashboards/tags_text_search.md
fi
