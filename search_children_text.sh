#!/usr/bin/env bash
# search_children_text.sh <current_file> <query> [ROOT_DIR]
#
# 今見ているノート内の wikilink ([[...]]）を子ノートとみなし、
# その子ノートの中から「指定テキストを含むもの」だけをダッシュボードに出す。
#
# - 再帰しない：子ノートのさらに子…は検索しない
# - wikilink は [[title]] / [[title|alias]] の両方に対応
# - title に対応する "<title>.md" を ROOT 配下から探す
#
# 出力:
#   dashboards/children_search.md
#
# 使い方のイメージ（VS Code Command Runner など）:
#   search_children_text.sh "${file}" "通信方式" "${workspaceFolder}"

set -euo pipefail

CUR_FILE="${1:-}"
QUERY="${2:-}"
ROOT="${3:-$PWD}"

if [[ -z "$CUR_FILE" || -z "$QUERY" ]]; then
  echo "usage: $0 <current_file> <query> [ROOT_DIR]" >&2
  exit 2
fi

if [[ ! -f "$CUR_FILE" ]]; then
  echo "Not a regular file: $CUR_FILE" >&2
  exit 1
fi

# 絶対パスに寄せておく（見た目用）
CUR_BASENAME="$(basename "$CUR_FILE")"
if [[ "$CUR_BASENAME" == *.md ]]; then
  CUR_TITLE="${CUR_BASENAME%.md}"
else
  CUR_TITLE="$CUR_BASENAME"
fi

OUTDIR="${ROOT}/dashboards"
mkdir -p "$OUTDIR"
OUT="${OUTDIR}/children_search.md"

tmp_links="$(mktemp)"
tmp_results="$(mktemp)"
trap 'rm -f "$tmp_links" "$tmp_results"' EXIT

# ---------------------------------------------
# 1) 親ノートから wikilink ([[...]]）を抽出 → タイトル部分だけにする
#    [[foo]] / [[foo|alias]] → "foo"
#    重複は awk でユニーク化
# ---------------------------------------------
# grep -o で "[[...]]" 部分だけ抜き出し、sed で中身を取り出し、"|alias" を落とす
grep -o '\[\[[^]]*]]' "$CUR_FILE" 2>/dev/null \
  | sed 's/^\[\[\(.*\)\]\]$/\1/' \
  | sed 's/|.*$//' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | awk 'NF>0 && !seen[$0]++' > "$tmp_links"

# 子リンクが無ければその旨を出して終了
if [[ ! -s "$tmp_links" ]]; then
  {
    echo "# Children Search – ${CUR_TITLE}"
    echo
    echo "> このノートには wikilink ([[...]]) がありません。"
    echo
  } > "$OUT"
  echo "[INFO] Wrote ${OUT}"
  exit 0
fi

# ---------------------------------------------
# 2) 各タイトルに対応する "<title>.md" を ROOT 配下から探し、
#    そのファイルに QUERY を含むかどうかを grep で判定
#
#    マッチしたものは:
#      basename\tfullpath
#    の形式で tmp_results に出力する
# ---------------------------------------------
while IFS= read -r title; do
  [[ -z "$title" ]] && continue

  # タイトルに対応するファイルを探す
  # 例: foo → foo.md
  # .git や .vscode, dashboards などは除外
  while IFS= read -r f; do
    # 念のため regular file だけ
    [[ -f "$f" ]] || continue

    # 中身に QUERY を含むか？ (大文字小文字は区別しないなら -i)
    if grep -qi -- "$QUERY" "$f"; then
      base="$(basename "$f")"
      if [[ "$base" == *.md ]]; then
        base="${base%.md}"
      fi
      printf '%s\t%s\n' "$base" "$f" >> "$tmp_results"
    fi
  done < <(
    find "$ROOT" -type f -name "${title}.md" \
      ! -path "${ROOT}/.git/*" \
      ! -path "${ROOT}/.vscode/*" \
      ! -path "${ROOT}/.foam/*" \
      ! -path "${ROOT}/node_modules/*" \
      ! -path "${OUTDIR}/*" 2>/dev/null
  )

done < "$tmp_links"

# ---------------------------------------------
# 3) Markdown に整形
# ---------------------------------------------
{
  echo "# Children Search – ${CUR_TITLE}"
  echo
  echo "- 親ノート: [[${CUR_TITLE}]]"
  echo "- 検索キーワード: \`$QUERY\`"
  echo "- 対象: このノートが wikilink している子ノートのみ（再帰なし）"
  echo "- 実行時刻: $(date '+%Y-%m-%d %H:%M')"
  echo

  if [[ ! -s "$tmp_results" ]]; then
    echo "> 該当する子ノートはありませんでした。"
    echo
  else
    echo "## マッチした子ノート"
    echo
    # basename でソートして、重複があればユニーク化して出力
    sort -t $'\t' -k1,1 "$tmp_results" \
      | awk -F '\t' '!seen[$1]++ { print "- [[" $1 "]]" }'
    echo
  fi
} > "$OUT"

echo "[INFO] Wrote ${OUT}"
