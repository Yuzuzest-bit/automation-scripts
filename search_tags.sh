#!/usr/bin/env bash
# search_tag.sh
#
# frontmatter の tags: を使って、指定したタグをすべて含むノートを一覧化するダッシュボード。
# さらに、「そのノート群に含まれているタグの種類と件数」を末尾にサマリ表示する。
#
# 使い方:
#   search_tag.sh                 → タグ条件なし（全部のノート）
#   search_tag.sh nwsp            → "nwsp" を含むノートだけ
#   search_tag.sh nwsp daily      → "nwsp" AND "daily" を両方含むノートだけ
#
# 前提:
#   - カレントディレクトリがノートのルート
#   - dashboards/tags_search.md に出力

set -euo pipefail

ROOT="$PWD"
TAG_STR="$*"   # 引数全部を空白区切りで1本の文字列に（AND条件）

OUTDIR="${ROOT}/dashboards"
mkdir -p "${OUTDIR}"
OUT="${OUTDIR}/tags_search.md"

tmp_files="$(mktemp)"
tmp_matches="$(mktemp)"   # basename \t "tag1 tag2 ..."
tmp_base="$(mktemp)"      # basename だけ
tmp_summary="$(mktemp)"   # count \t tag
trap 'rm -f "$tmp_files" "$tmp_matches" "$tmp_base" "$tmp_summary"' EXIT

# 対象となる Markdown ファイル一覧
find "${ROOT}" -type f -name '*.md' ! -path "${OUTDIR}/*" > "${tmp_files}"

# 1) 対象ファイルを走査して、条件に合うノートを抽出
#    -> basename \t "tag1 tag2 ..." を tmp_matches に出力
awk -v tags="${TAG_STR}" '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

BEGIN {
  nTag = 0
  if (tags != "") {
    nTag = split(tags, wantedTags, /[[:space:]]+/)
  }
}

# filelist を1行ずつ読む
NR==FNR {
  file = $0
  gsub(/\r$/, "", file)
  if (file == "") next

  inFM   = 0
  fmDone = 0
  hasTag = (nTag == 0 ? 1 : 0)   # タグ指定なしなら最初からOK
  noteTags = ""                  # このノートに付いているタグ（空白区切り文字列）

  # ベース名（.md を取る）
  n = split(file, parts, "/")
  b = parts[n]
  if (length(b) > 3 && substr(b, length(b)-2) == ".md") {
    b = substr(b, 1, length(b)-3)
  }
  basename = b

  # ファイル本体を読みながら frontmatter だけ見る
  while ((getline line < file) > 0) {
    sub(/\r$/, "", line)

    # frontmatter の境界
    if (line ~ /^---[ \t]*$/) {
      if (inFM == 0 && fmDone == 0) { inFM = 1; continue }
      else if (inFM == 1 && fmDone == 0) { inFM = 0; fmDone = 1; break }
    }

    if (inFM == 1) {
      low = line
      # 小文字化
      for (i = 1; i <= length(low); i++) {
        c = substr(low, i, 1)
        if (c >= "A" && c <= "Z") {
          low = substr(low, 1, i-1) "" tolower(c) "" substr(low, i+1)
        }
      }

      # tags: 行を見つけたら、タグ一覧を noteTags に溜める
      if (index(low, "tags:") > 0) {
        p = index(low, "tags:")
        tmp = substr(low, p + 5)     # "tags:" の後ろ
        gsub(/[\[\]]/, "", tmp)      # [ ] を削除
        nt = split(tmp, arr, ",")
        for (j = 1; j <= nt; j++) {
          t = trim(arr[j])
          if (t != "") {
            if (noteTags != "") noteTags = noteTags " "
            noteTags = noteTags t
          }
        }
      }

      # タグフィルタ（AND条件）
      if (nTag > 0 && index(low, "tags:") > 0) {
        allOK = 1
        for (ti = 1; ti <= nTag; ti++) {
          t = wantedTags[ti]
          if (t == "") continue
          if (index(low, t) == 0) {
            allOK = 0
            break
          }
        }
        if (allOK) {
          hasTag = 1
        }
      }
    }
  }
  close(file)

  if (hasTag) {
    # basename \t "tag1 tag2 ..."
    print basename "\t" noteTags
  }

  next
}
' "${tmp_files}" > "${tmp_matches}"

# 何もヒットしていない場合は、そのまま「該当なし」を作って終わり
cut -f1 "${tmp_matches}" | sort > "${tmp_base}"

awk -F '\t' '
{
  # 第2フィールドに "tag1 tag2 ..." が入っている想定
  n = split($2, a, /[[:space:]]+/)
  for (i = 1; i <= n; i++) {
    t = a[i]
    if (t != "") cnt[t]++
  }
}
END {
  for (t in cnt) {
    print cnt[t] "\t" t
  }
}
' "${tmp_matches}" | sort -nr > "${tmp_summary}"

# 3) Markdown に整形して OUT に書き出す

# 見出し用の文言を先に決めておく
if [ -z "${TAG_STR}" ]; then
  HEADER_TITLE="Tag Search – All notes"
  CONDITION_TEXT="- 検索条件: タグ指定なし（全ノート）"
else
  HEADER_TITLE="Tag Search – ${TAG_STR}"
  CONDITION_TEXT="- 検索条件: tags: に [${TAG_STR}] のすべてを含むノート (AND)"
fi

{
  echo "# ${HEADER_TITLE}"
  echo
  echo "${CONDITION_TEXT}"
  echo

  if [ ! -s "${tmp_base}" ]; then
    echo "> 該当なし"
    echo
  else
    # 検索結果のノート一覧
    while IFS= read -r base; do
      [ -z "$base" ] && continue
      echo "- [[${base}]]"
    done < "${tmp_base}"
    echo

    # タグサマリ
    echo "## Tag summary for these notes"
    echo
    if [ ! -s "${tmp_summary}" ]; then
      echo "> tags: (none)"
      echo
    else
      while IFS=$'\t' read -r count tag; do
        [ -z "$tag" ] && continue
        echo "- ${tag} (${count})"
      done < "${tmp_summary}"
      echo
    fi
  fi
} > "${OUT}"

echo "[INFO] Wrote ${OUT}"
