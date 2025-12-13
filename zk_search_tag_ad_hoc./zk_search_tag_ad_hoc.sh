#!/usr/bin/env bash
# zk_search_tag_ad_hoc.sh "<tag_query>" [<text_query>|<ROOT>] [ROOT]
#
# 目的:
# - ad hoc で入力したタグクエリを使って search_tag.sh を実行
# - さらに任意で「本文テキスト」を指定し、タグ一致したノートの中から絞り込む
# - 実行後に dashboards/tags_search.md を開く
# - 拡張なし / Pythonなし
#
# 使い方（互換）:
#   1) タグのみ（従来通り）
#     ./zk_search_tag_ad_hoc.sh "issue -zk-archive"
#
#   2) タグ + 本文テキスト
#     ./zk_search_tag_ad_hoc.sh "issue -zk-archive" "timeout"
#
#   3) タグのみ + ROOT
#     ./zk_search_tag_ad_hoc.sh "issue -zk-archive" "/path/to/indivi-valt"
#
#   4) タグ + 本文テキスト + ROOT
#     ./zk_search_tag_ad_hoc.sh "issue -zk-archive" "timeout" "/path/to/indivi-valt"
#
#   5) オプション形式（曖昧さ回避したい場合）
#     ./zk_search_tag_ad_hoc.sh "issue -zk-archive" --text "timeout" --root "/path"
#     ./zk_search_tag_ad_hoc.sh --text "timeout" --root "/path"   # タグなし=全件から本文で絞り込み

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  zk_search_tag_ad_hoc.sh "<tag_query>" [<text_query>|<ROOT>] [ROOT]
  zk_search_tag_ad_hoc.sh "<tag_query>" --text "<text_query>" --root "<ROOT>"
  zk_search_tag_ad_hoc.sh --text "<text_query>" --root "<ROOT>"
EOF
}

TAG_QUERY=""
TEXT_QUERY=""
ROOT="$PWD"

# --- 引数パース（オプション + 後方互換の位置引数） ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# まずオプションを雑に拾う（指定があれば優先）
# 残りは位置引数として解釈
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root|-r)
      # 値がない / 次が別オプションなら無視（既定の ROOT を維持）
      if [[ $# -ge 2 && "${2:-}" != "--text" && "${2:-}" != "-t" && "${2:-}" != "--root" && "${2:-}" != "-r" ]]; then
        ROOT="$2"
        shift 2
      else
        shift 1
      fi
      ;;
    --text|-t)
      # 値がない / 次が別オプションなら TEXT_QUERY は空扱い
      if [[ $# -ge 2 && "${2:-}" != "--text" && "${2:-}" != "-t" && "${2:-}" != "--root" && "${2:-}" != "-r" ]]; then
        TEXT_QUERY="$2"
        shift 2
      else
        TEXT_QUERY=""
        shift 1
      fi
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

# 位置引数の解釈（互換）
# positional[0]=TAG_QUERY
# positional[1]=TEXT_QUERY or ROOT
# positional[2]=ROOT
if [[ ${#positional[@]} -ge 1 && -z "$TAG_QUERY" ]]; then
  # 先頭が "--text" ではない場合、1個目は tag_query とみなす（ただし既に --text が来ていれば tagなしでOK）
  if [[ "${positional[0]}" != "" ]]; then
    TAG_QUERY="${positional[0]}"
  fi
fi

if [[ ${#positional[@]} -ge 2 ]]; then
  if [[ -z "$TEXT_QUERY" && -d "${positional[1]}" ]]; then
    # 第2引数がディレクトリなら ROOT 扱い（テキストなし）
    ROOT="${positional[1]}"
  elif [[ -z "$TEXT_QUERY" ]]; then
    # 第2引数がディレクトリでなければ TEXT 扱い
    TEXT_QUERY="${positional[1]}"
  fi
fi

if [[ ${#positional[@]} -ge 3 ]]; then
  # 第3引数があれば ROOT
  ROOT="${positional[2]}"
fi

# --- 実行 ---
cd "$ROOT"

# 1) タグ検索（search_tag.sh が dashboards/tags_search.md を生成する想定）
if [[ -z "$TAG_QUERY" ]]; then
  ./search_tag.sh
else
  read -r -a tag_args <<< "$TAG_QUERY"
  ./search_tag.sh "${tag_args[@]}"
fi

RESULT_MD="dashboards/tags_search.md"

# 2) 本文テキストで絞り込み（任意）
if [[ -n "$TEXT_QUERY" ]]; then
  # 元結果を退避（必要なら見比べられる）
  cp -f "$RESULT_MD" "${RESULT_MD%.md}_tagonly.md" 2>/dev/null || true

  # wikiリンク [[...]] を抽出（リンク表示名 | の前まで）
  mapfile -t notes < <(
    awk '
      {
        line = $0
        while (match(line, /\[\[[^]]+\]\]/)) {
          s = substr(line, RSTART+2, RLENGTH-4)
          n = split(s, a, "[|]")  # | があれば手前だけ
          print a[1]
          line = substr(line, RSTART + RLENGTH)
        }
      }
    ' "$RESULT_MD" | awk 'NF' | sort -u
  )

  # ノート名→ファイルパス解決（ざっくり）
  resolve_note_path() {
    local name="$1"
    local p="$name"

    # そのまま存在
    if [[ -f "$p" ]]; then echo "$p"; return 0; fi

    # .md を付けて存在
    if [[ "$p" != *.md ]]; then
      if [[ -f "${p}.md" ]]; then echo "${p}.md"; return 0; fi
    fi

    # ルート直下
    if [[ -f "./$p" ]]; then echo "$p"; return 0; fi
    if [[ "$p" != *.md && -f "./$p.md" ]]; then echo "$p.md"; return 0; fi

    # 最後の手段: 同名ファイルを find（dashboards/.foam は除外）
    local base="${name##*/}"
    local cand
    cand="$(find . -type f \
      -not -path "./dashboards/*" \
      -not -path "./.foam/*" \
      \( -name "${base}.md" -o -name "${base}" \) \
      -print -quit 2>/dev/null || true)"
    if [[ -n "$cand" ]]; then
      echo "${cand#./}"
      return 0
    fi
    return 1
  }

  # 検索コマンド（rg優先、なければgrep）
  has_rg=0
  if command -v rg >/dev/null 2>&1; then
    has_rg=1
  fi

  tmp="$(mktemp)"
  {
    echo "# tags_search (filtered)"
    echo
    echo "- tag_query: \`${TAG_QUERY:-<all>}\`"
    echo "- text_query: \`$TEXT_QUERY\`"
    echo "- note_count(tag hit): ${#notes[@]}"
    echo

    hit_count=0

    for n in "${notes[@]}"; do
      if ! fpath="$(resolve_note_path "$n")"; then
        continue
      fi

      if [[ $has_rg -eq 1 ]]; then
        # fixed string + smart-case（大文字含むなら大文字小文字区別）
        if rg --fixed-strings --smart-case --line-number --no-heading --color never -- "$TEXT_QUERY" "$fpath" >/dev/null 2>&1; then
          hit_count=$((hit_count+1))
          echo "- [[${n}]]"
          rg --fixed-strings --smart-case --line-number --no-heading --color never -- "$TEXT_QUERY" "$fpath" \
            | head -n 3 \
            | sed 's/^/  > /'
          echo
        fi
      else
        if grep -n -F -- "$TEXT_QUERY" "$fpath" >/dev/null 2>&1; then
          hit_count=$((hit_count+1))
          echo "- [[${n}]]"
          grep -n -F -- "$TEXT_QUERY" "$fpath" | head -n 3 | sed 's/^/  > /'
          echo
        fi
      fi
    done

    echo "---"
    echo "**Hit:** ${hit_count}"
    echo
    echo "> ※ 元のタグのみ結果は ${RESULT_MD%.md}_tagonly.md に退避しています（テキスト指定時のみ）。"
  } > "$tmp"

  mv -f "$tmp" "$RESULT_MD"
fi

# 結果を開く（code がある環境だけ）
if command -v code >/dev/null 2>&1; then
  code -r "$RESULT_MD"
fi
