#!/usr/bin/env bash
# search_tag_text.sh
#
# タグ条件でノートを絞り込み、さらに本文に指定テキストを含むものへ絞る。
#
# 使い方:
#   search_tag_text.sh [tag...]
#   search_tag_text.sh --text "keyword" [tag...]
#   search_tag_text.sh --text "keyword" --case-sensitive [tag...]
#
# 仕様:
# - frontmatter がある .md のみ対象（既存 search_tag.sh と同等）
# - tags 条件:
#     先頭 "-" なし = 含む(AND)
#     先頭 "-" あり = 含まない(NOT)
# - text 条件:
#     本文（frontmatter以降）に部分一致
# - 出力:
#     dashboards/tags_text_search.md
#
# 並び順:
# - created があるノート: created 降順
# - created が無いノート: 最後

set -euo pipefail

ROOT="$PWD"
OUTDIR="${ROOT}/dashboards"
TEMPLATES_DIR="${ROOT}/.foam/templates"

mkdir -p "${OUTDIR}"
OUT="${OUTDIR}/tags_text_search.md"

TEXT=""
CASE_SENSITIVE=0

# ---- option parse ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --text)
      TEXT="${2:-}"
      shift 2
      ;;
    --case-sensitive)
      CASE_SENSITIVE=1
      shift 1
      ;;
    --out)
      OUT="${2:-$OUT}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

# 残りはタグ条件
TAG_STR="$*"

tmp_files="$(mktemp)"
tmp_matches="$(mktemp)"   # basename \t "tag1 tag2 ..." \t created
tmp_base="$(mktemp)"      # ソート済み basename
tmp_summary="$(mktemp)"   # count \t tag
trap 'rm -f "$tmp_files" "$tmp_matches" "$tmp_base" "$tmp_summary"' EXIT

# 対象となる Markdown ファイル一覧
find "${ROOT}" -type f -name '*.md' \
  ! -path "${OUTDIR}/*" \
  ! -path "${TEMPLATES_DIR}/*" \
  > "${tmp_files}"

awk -v tags="${TAG_STR}" -v text="${TEXT}" -v cs="${CASE_SENSITIVE}" '
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

  # text の比較用
  needle = text
  if (cs == 0) needle_low = tolower_str(needle)
  else needle_low = needle

  if (tags != "") {
    nTag = split(tags, rawTags, /[[:space:]]+/)
    for (i = 1; i <= nTag; i++) {
      t = rawTags[i]
      if (t == "") continue

      t = tolower_str(t)

      if (substr(t, 1, 1) == "-") {
        t2 = substr(t, 2)
        if (t2 != "") {
          nNeg++
          negTags[nNeg] = t2
        }
      } else {
        nPos++
        posTags[nPos] = t
      }
    }
  }
}

NR==FNR {
  file = $0
  gsub(/\r$/, "", file)
  if (file == "") next

  inFM   = 0
  fmDone = 0
  noteTags = ""
  created  = ""

  # basename
  n = split(file, parts, "/")
  b = parts[n]
  if (length(b) > 3 && substr(b, length(b)-2) == ".md") {
    b = substr(b, 1, length(b)-3)
  }
  basename = b

  # ---- frontmatter だけ読む ----
  while ((getline line < file) > 0) {
    sub(/\r$/, "", line)

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

      if (low ~ /^created[ \t]*:/) {
        val = substr(line, index(line, ":") + 1)
        created = trim(val)
      }

      if (index(low, "tags:") > 0) {
        p = index(low, "tags:")
        tmp = substr(low, p + 5)
        gsub(/[\[\]]/, "", tmp)
        nt = split(tmp, arr, ",")
        for (j = 1; j <= nt; j++) {
          t = trim(arr[j])
          if (t != "") {
            t = tolower_str(t)
            if (noteTags != "") noteTags = noteTags " "
            noteTags = noteTags t
          }
        }
      }
    }
  }
  close(file)

  # frontmatter が無いファイルは除外
  if (!fmDone) next

  # ---- タグフィルタ判定 ----
  hasTag = 1

  # 必須タグ
  if (nPos > 0) {
    hasTag = 1
    nt2 = split(noteTags, tagsArr, /[[:space:]]+/)
    for (pi = 1; pi <= nPos; pi++) {
      t = posTags[pi]
      found = 0
      for (j = 1; j <= nt2; j++) {
        if (tagsArr[j] == t) { found = 1; break }
      }
      if (!found) { hasTag = 0; break }
    }
  }

  # 除外タグ
  if (hasTag && nNeg > 0) {
    nt2 = split(noteTags, tagsArr, /[[:space:]]+/)
    for (ni = 1; ni <= nNeg; ni++) {
      t = negTags[ni]
      for (j = 1; j <= nt2; j++) {
        if (tagsArr[j] == t) { hasTag = 0; break }
      }
      if (!hasTag) break
    }
  }

  if (!hasTag) next

  # ---- text 条件（本文のみ）----
  if (needle != "") {
    inFM2 = 0
    fmDone2 = 0
    foundText = 0

    while ((getline line2 < file) > 0) {
      sub(/\r$/, "", line2)

      if (line2 ~ /^---[ \t]*$/) {
        if (inFM2 == 0 && fmDone2 == 0) {
          inFM2 = 1
          continue
        } else if (inFM2 == 1 && fmDone2 == 0) {
          inFM2 = 0
          fmDone2 = 1
          continue
        }
      }

      # frontmatter 終了後だけ検索
      if (fmDone2) {
        hay = line2
        if (cs == 0) hay = tolower_str(hay)

        if (index(hay, needle_low) > 0) {
          foundText = 1
          break
        }
      }
    }
    close(file)

    # 本文に見つからなければ除外
    if (!foundText) next
  }

  # ここまで来たらヒット
  print basename "\t" noteTags "\t" created

  next
}
' "${tmp_files}" > "${tmp_matches}"

# created ソート（降順）
awk -F '\t' '
{
  base    = $1
  created = $3
  key = (created != "" ? created : "0000-00-00")
  print key "\t" base
}
' "${tmp_matches}" | sort -r -k1,1 -k2,2 | cut -f2 > "${tmp_base}"

# タグサマリ（絞り込み後の集合に対して）
awk -F '\t' '
{
  n = split($2, a, /[[:space:]]+/)
  for (i = 1; i <= n; i++) {
    t = a[i]
    if (t != "") cnt[t]++
  }
}
END {
  for (t in cnt) print cnt[t] "\t" t
}
' "${tmp_matches}" | sort -nr > "${tmp_summary}"

# ---- 見出し文 ----
if [ -z "${TAG_STR}" ]; then
  TAG_TITLE="Tag Search – All notes"
  TAG_COND="- 検索条件(タグ): 指定なし（全ノート）"
else
  TAG_TITLE="Tag Search – ${TAG_STR}"
  TAG_COND="- 検索条件(タグ): 通常タグ=含む(AND), 先頭\"-\"タグ=含まない(NOT)"
fi

if [ -z "${TEXT}" ]; then
  TEXT_COND="- 検索条件(本文): 指定なし"
else
  if [ "${CASE_SENSITIVE}" -eq 1 ]; then
    TEXT_COND="- 検索条件(本文): \"${TEXT}\" を含む（大小文字区別）"
  else
    TEXT_COND="- 検索条件(本文): \"${TEXT}\" を含む（大小文字区別なし）"
  fi
fi

{
  echo "# ${TAG_TITLE}"
  echo
  echo "${TAG_COND}"
  echo "${TEXT_COND}"
  echo

  if [ ! -s "${tmp_base}" ]; then
    echo "> 該当なし"
    echo
  else
    while IFS= read -r base; do
      [ -z "$base" ] && continue
      echo "- [[${base}]]"
    done < "${tmp_base}"
    echo

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
