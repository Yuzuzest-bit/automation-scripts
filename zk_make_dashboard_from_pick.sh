#!/usr/bin/env bash
# zk_make_dashboard_from_pick.sh "<label | desc | tags>" [ROOT]
# 3列 pick を受け取り、タグ部分だけ抜いて make_tag_dashboard.sh を実行
# 依存なし / AWKのみ

set -euo pipefail

RAW="${1:-}"
ROOT="${2:-$PWD}"

cd "$ROOT"

# 3列目があればそれを、なければ1列目を使う
# 例:
#   "issue | 説明 | issue"
#   "life | 説明 | ctx-life -zk-archive" でもOK
TAGS="$(
  printf '%s' "$RAW" |
    awk -F'|' '{
      if (NF >= 3) print $3;
      else if (NF == 2) print $1;
      else print $0;
    }' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
)"

if [[ -z "$TAGS" ]]; then
  ./make_tag_dashboard.sh
else
  # 空白区切りの複数タグにも対応
  # ※このスクリプト仕様上、複数タグを渡すと最後がROOT扱いになるので
  #    ここでは「旧形式互換」を使って安全にANDを表現する
  #    つまり: "tag1 tag2" "ignored" "$PWD"
  if [[ "$TAGS" == *" "* ]]; then
    ./make_tag_dashboard.sh "$TAGS" "ignored" "$PWD"
  else
    ./make_tag_dashboard.sh "$TAGS"
  fi
fi

if command -v code >/dev/null 2>&1; then
  code -r dashboards/default_dashboard.md
fi
