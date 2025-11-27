#!/usr/bin/env bash
# search_tag.sh
#
# frontmatter の tags: を使って、指定したタグを条件にマッチするノートを一覧化するダッシュボード。
# さらに、「そのノート群に含まれているタグの種類と件数」を末尾にサマリ表示する。
#
# 使い方:
#   search_tag.sh                       → タグ条件なし（全部のノート）
#   search_tag.sh nwsp                  → "nwsp" を含むノートだけ
#   search_tag.sh nwsp daily            → "nwsp" AND "daily" を両方含むノートだけ
#   search_tag.sh issue -zk-archive     → "issue" を含み、"zk-archive" を含まないノートだけ
#
# 引数ルール:
#   - 先頭に "-" が付いていないタグ …「含んでいること」が必須 (AND条件)
#   - 先頭に "-" が付いているタグ   …「含んでいないこと」が必須 (NOT条件)
#
# 前提:
#   - カレントディレクトリがノートのルート
#   - dashboards/tags_search.md に出力
#
# 並び順:
#   - frontmatter に created: があるノート → created の降順（新しい created が上）
#   - created: が無いノート                → 一番古い扱いで最後に並ぶ

set -euo pipefail

ROOT="$PWD"
TAG_STR="$*"   # 引数全部を空白区切りで1本の文字列に

OUTDIR="${ROOT}/dashboards"
mkdir -p "${OUTDIR}"
OUT="${OUTDIR}/tags_search.md"

tmp_files="$(mktemp)"
tmp_matches="$(mktemp)"   # basename \t "tag1 tag2 ..." \t created
tmp_base="$(mktemp)"      # ソート済み basename だけ
tmp_summary="$(mktemp)"   # count \t tag
trap 'rm -f "$tmp_files" "$tmp_matches" "$tmp_base" "$tmp_summary"' EXIT

# 対象となる Markdown ファイル一覧
find "${ROOT}" -type f -name '*.md' ! -path "${OUTDIR}/*" > "${tmp_files}"

# 1) 対象ファイルを走査して、条件に合うノートを抽出
#    -> basename \t "tag1 tag2 ..." \t created を tmp_matches に出力
awk -v tags="${TAG_STR}" '
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
  nPos = 0
  nNeg = 0

  if (tags != "") {
    nTag = split(tags, rawTags, /[[:space:]]+/)
    for (i = 1; i <= nTag; i++) {
      t = rawTags[i]
      if (t == "") continue

      # 小文字化
      t = tolower_str(t)

      if (substr(t, 1, 1) == "-") {
        # 除外タグ（先頭の - を外す）
        t2 = substr(t, 2)
        if (t2 != "") {
          nNeg++
          negTags[nNeg] = t2
        }
      } else {
        # 必須タグ
        nPos++
        posTags[nPos] = t
      }
    }
  }
}

# filelist を1行ずつ読む
NR==FNR {
  file = $0
  gsub(/\r$/, "", file)
  if (file == "") next

  inFM   = 0
  fmDone = 0
  noteTags = ""                  # このノートに付いているタグ（空白区切り文字列）
  created  = ""                  # frontmatter の created: の値

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
      if (inFM == 0 && fmDone == 0) {
        inFM = 1
        continue
      } else if (inFM == 1 && fmDone == 0) {
        inFM = 0
        fmDone = 1
        break
      }
    }

    if (inFM == 1) {
      low = tolower_str(line)

      # created: 行（先頭に created: が来る想定）
      if (match(low, /^created[ \t]*:/)) {
        # オリジナル行から : の後ろを取り、そのまま trim
        val = substr(line, index(line, ":") + 1)
        created = trim(val)
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
    }
  }
  close(file)

  # ---- タグフィルタ判定 ----
  hasTag = 1

  # 1) 必須タグ（正のタグ）がある場合: すべて含んでいるか？
  if (nPos > 0) {
    hasTag = 1
    nt2 = split(noteTags, tagsArr, /[[:space:]]+/)
    for (pi = 1; pi <= nPos; pi++) {
      t = posTags[pi]
      found = 0
      for (j = 1; j <= nt2; j++) {
        if (tagsArr[j] == t) {
          found = 1
          break
        }
      }
      if (!found) {
        hasTag = 0
        break
      }
    }
  }

  # 2) 除外タグ（負のタグ）がある場合: ひとつも含んでいないか？
  if (hasTag && nNeg > 0) {
    nt2 = split(noteTags, tagsArr, /[[:space:]]+/)
    for (ni = 1; ni <= nNeg; ni++) {
      t = negTags[ni]
      for (j = 1; j <= nt2; j++) {
        if (tagsArr[j] == t) {
          hasTag = 0
          break
        }
      }
      if (!hasTag) break
    }
  }

  # フィルタを通ったノートだけ出力
  if (hasTag) {
    # basename \t "tag1 tag2 ..." \t created
    print basename "\t" noteTags "\t" created
  }

  next
}
' "${tmp_files}" > "${tmp_matches}"

# 2) 抽出したノートを created でソートして basename のみ tmp_base に出力
#    - created があるノート: created 降順
#    - created がないノート: "0000-00-00" として扱い、一番最後に回る
awk -F '\t' '
{
  base    = $1
  tags    = $2  # ここでは使わない
  created = $3

  key = (created != "" ? created : "0000-00-00")

  print key "\t" base
}
' "${tmp_matches}" | sort -r -k1,1 -k2,2 | cut -f2 > "${tmp_base}"

# タグサマリ用: 第2フィールド (tags) だけを使うので従来通り
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
  CONDITION_TEXT="- 検索条件: 指定タグ（例: issue -zk-archive）をすべて満たすノート（通常タグ=含む, 先頭が\"-\"のタグ=含まない / AND 条件）"
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
    # 検索結果のノート一覧（created 降順）
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
