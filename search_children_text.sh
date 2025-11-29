#!/usr/bin/env bash
# search_children_from_list.sh <current_file> <keywords_md> [ROOT_DIR]
#
# 今開いているノートの wikilink ([[...]]) を子ノートとみなし、
# 別の Markdown ファイルに列挙した「検索ワード」のどれかを含む
# 子ノートだけをダッシュボードに出力する。
#
# - キーワード Markdown には frontmatter が付いていてもよい（無視する）
# - frontmatter 以降の本文部分の「各行」が検索ワード定義
# - 1行に複数単語がある場合は、空白で分割して OR 検索
#   （＝全部まとめて「どれか1つでも含まれればOK」）
#
# 並び順:
#   - 子ノートの frontmatter に created: があれば、その日付 (YYYY-MM-DD) の降順
#   - created: が無いノートは "0000-00-00" 扱いで最後に並ぶ
#
# 出力:
#   dashboards/children_search.md

set -euo pipefail

CUR_FILE="${1:-}"
KEY_MD="${2:-}"
ROOT="${3:-$PWD}"

if [[ -z "$CUR_FILE" || -z "$KEY_MD" ]]; then
  echo "usage: $0 <current_file> <keywords_md> [ROOT_DIR]" >&2
  exit 2
fi

if [[ ! -f "$CUR_FILE" ]]; then
  echo "Not a regular file: $CUR_FILE" >&2
  exit 1
fi

if [[ ! -f "$KEY_MD" ]]; then
  echo "Keyword markdown not found: $KEY_MD" >&2
  exit 1
fi

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
tmp_results="$(mktemp)"   # ★ created \t basename を貯める
tmp_kw_raw="$(mktemp)"
tmp_kw="$(mktemp)"
trap 'rm -f "$tmp_links" "$tmp_results" "$tmp_kw_raw" "$tmp_kw"' EXIT

# ---------------------------------------------
# 1) キーワード Markdown からパターン抽出
#    - frontmatter(---〜---)は無視
#    - frontmatter の外側の各行を空白分割し、単語ごとに1パターン
# ---------------------------------------------
awk '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

BEGIN {
  inFM   = 0
  fmDone = 0
}

{
  # CR除去
  sub(/\r$/, "", $0)
  line = $0

  # frontmatter 境界判定
  if (line ~ /^---[ \t]*$/) {
    if (inFM == 0 && fmDone == 0) {
      inFM = 1
      next
    } else if (inFM == 1 && fmDone == 0) {
      inFM = 0
      fmDone = 1
      next
    }
  }

  # frontmatter 内は無視
  if (inFM == 1) next

  # frontmatter 終了後のみ処理
  if (fmDone == 0) next

  txt = trim(line)
  if (txt == "") next

  # 行を空白分割して単語ごとに出力（OR 検索用）
  n = split(txt, arr, /[[:space:]]+/)
  for (i = 1; i <= n; i++) {
    w = trim(arr[i])
    if (w != "") {
      print w
    }
  }
}
' "$KEY_MD" > "$tmp_kw_raw"

# 重複を削除して確定版に
awk 'NF>0 && !seen[$0]++' "$tmp_kw_raw" > "$tmp_kw"

if [[ ! -s "$tmp_kw" ]]; then
  {
    echo "# Children Search – ${CUR_TITLE}"
    echo
    echo "> キーワードファイルから有効な検索ワードが取得できませんでした。"
    echo
  } > "$OUT"
  echo "[INFO] Wrote ${OUT}"
  exit 0
fi

# ---------------------------------------------
# 2) 親ノートから wikilink ([[...]]）を抽出 → タイトル一覧
# ---------------------------------------------
grep -o '\[\[[^]]*]]' "$CUR_FILE" 2>/dev/null \
  | sed 's/^\[\[\(.*\)\]\]$/\1/' \
  | sed 's/|.*$//' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | awk 'NF>0 && !seen[$0]++' > "$tmp_links"

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
# 3) 各子ノートについて、「いずれかのキーワードを含むか」を判定
#    - grep -Fi -f パターンファイル で OR 検索
#    - さらに frontmatter の created: (YYYY-MM-DD) を拾って並び替えに使う
# ---------------------------------------------
while IFS= read -r title; do
  [[ -z "$title" ]] && continue

  # タイトルに対応する "<title>.md" を ROOT 配下から探す
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    # いずれかのキーワードを含むか？
    if grep -Fiq -f "$tmp_kw" "$f"; then
      base="$(basename "$f")"
      if [[ "$base" == *.md ]]; then
        base="${base%.md}"
      fi

      # ★ このファイルの frontmatter から created: を取得
      created="$(
        awk '
        function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
        function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
        function trim(s){ return rtrim(ltrim(s)) }
        function tolower_str(s,    i,c) {
          for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c >= "A" && c <= "Z") {
              s = substr(s, 1, i-1) "" tolower(c) "" substr(s, i+1)
            }
          }
          return s
        }

        BEGIN {
          inFM   = 0
          fmDone = 0
          created = ""
        }

        {
          sub(/\r$/, "", $0)
          line = $0

          # frontmatter 境界
          if (line ~ /^---[ \t]*$/) {
            if (inFM == 0 && fmDone == 0) {
              inFM = 1
              next
            } else if (inFM == 1 && fmDone == 0) {
              inFM = 0
              fmDone = 1
              next
            }
          }

          if (inFM == 1) {
            low = tolower_str(line)
            if (match(low, /^created[ \t]*:/)) {
              val = substr(line, index(line, ":") + 1)
              created = trim(val)
            }
          }
        }

        END {
          if (created ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) {
            print substr(created, 1, 10)
          } else {
            print ""
          }
        }
        ' "$f"
      )"

      # created が無い場合は最古扱いの "0000-00-00" にする
      if [[ -z "$created" ]]; then
        created="0000-00-00"
      fi

      # created \t basename を保存
      printf '%s\t%s\n' "$created" "$base" >> "$tmp_results"
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
# 4) Markdown に整形して出力
# ---------------------------------------------
{
  echo "# Children Search – ${CUR_TITLE}"
  echo
  echo "- 親ノート: [[${CUR_TITLE}]]"
  echo "- キーワードファイル: $(basename "$KEY_MD")"
  echo "- 検索条件: このノートがリンクしている子ノートのうち、"
  echo "  キーワード Markdown の本文に書かれた単語の **いずれかを含む** ノート"
  echo "- 並び順: 子ノートの created: (YYYY-MM-DD) 降順（未指定は最後）"
  echo "- 実行時刻: $(date '+%Y-%m-%d %H:%M')"
  echo

  echo "## 使用キーワード"
  echo
  while IFS= read -r kw; do
    [[ -z "$kw" ]] && continue
    echo "- \`$kw\`"
  done < "$tmp_kw"
  echo

  if [[ ! -s "$tmp_results" ]]; then
    echo "## マッチした子ノート"
    echo
    echo "> 該当する子ノートはありませんでした。"
    echo
  else
    echo "## マッチした子ノート"
    echo
    # ★ created 降順・basename 降順でソートしつつ、basename でユニーク化
    sort -t $'\t' -k1,1r -k2,2r "$tmp_results" \
      | awk -F '\t' '!seen[$2]++ { print "- [[" $2 "]]" }'
    echo
  fi
} > "$OUT"

echo "[INFO] Wrote ${OUT}"
