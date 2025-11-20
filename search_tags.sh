#!/usr/bin/env bash
# dash_by_tags.sh <tag or -exclude> [...]
# frontmatter tags: に指定されたタグ群をもとに、
# 「指定した必須タグをすべて含み、かつ、除外タグを含まない」ノートのダッシュボードを作成する
#
# 仕様:
# - 引数:
#     通常の単語   → 必須タグ (AND 条件)
#     -xxxx       → 除外タグ (NOT 条件)
#   例:
#     dash_by_tags.sh design              # design を含むノート
#     dash_by_tags.sh design -decision    # design かつ decision なし（= 検討中）
#     dash_by_tags.sh design proj-aaa -decision
#
# - ルートディレクトリ:
#     この .sh が置かれているフォルダをルートとする
# - その配下のサブフォルダを find で再帰的に探索
# - dashboards/tags_search.md に毎回上書き出力
# - 並び順:
#     ZK_TAG_SORT=asc  (デフォルト) ... ファイル名昇順
#     ZK_TAG_SORT=desc             ... ファイル名降順
#     ZK_TAG_SORT=none             ... ソートなし（find 順）

set -euo pipefail

# ---------- ROOT 解決 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"

OUTDIR="${ROOT_DIR}/dashboards"
mkdir -p "${OUTDIR}"
OUT="${OUTDIR}/tags_search.md"

# ---------- 引数パース（必須タグ / 除外タグ） ----------
REQ_TAGS=""   # 必須
EXC_TAGS=""   # 除外

if [ "$#" -eq 0 ]; then
  echo "usage: dash_by_tags.sh <tag or -exclude> [...]" >&2
  exit 2
fi

for arg in "$@"; do
  if [[ "$arg" == -* ]]; then
    tag="${arg#-}"
    [ -z "$tag" ] && continue
    if [ -z "${EXC_TAGS}" ]; then
      EXC_TAGS="${tag}"
    else
      EXC_TAGS="${EXC_TAGS},${tag}"
    fi
  else
    tag="${arg}"
    [ -z "$tag" ] && continue
    if [ -z "${REQ_TAGS}" ]; then
      REQ_TAGS="${tag}"
    else
      REQ_TAGS="${REQ_TAGS},${tag}"
    fi
  fi
done

# ---------- 対象 Markdown 一覧 ----------
tmp_files="$(mktemp)"
trap 'rm -f "$tmp_files" "$tmp_list"' EXIT

find "${ROOT_DIR}" -type f -name '*.md' ! -path "${OUTDIR}/*" > "${tmp_files}"

# ---------- ファイルごとのタグ判定 ----------
tmp_list="$(mktemp)"  # マッチした basename を一時保存

awk -v req="${REQ_TAGS}" -v exc="${EXC_TAGS}" '
function tolower_str(s,    i,c) {
  for (i=1; i<=length(s); i++) {
    c = substr(s,i,1)
    if (c >= "A" && c <= "Z") {
      s = substr(s,1,i-1) "" tolower(c) "" substr(s,i+1)
    }
  }
  return s
}

BEGIN{
  n_req = split(req, REQ, ",")
  n_exc = split(exc, EXC, ",")

  # 空要素の削除（split の都合で入ることがある）
  for (i=1;i<=n_req;i++) if (REQ[i]=="") REQ[i]="\001"
  for (i=1;i<=n_exc;i++) if (EXC[i]=="") EXC[i]="\002"
}

{
  file = $0
  gsub(/\r$/, "", file)
  if (file == "") next

  # frontmatter を読む
  inFM   = 0
  fmDone = 0
  hasTagsLine = 0
  hasAllReq = (n_req==0 ? 1 : 0)   # 必須タグなしなら最初からOK
  hasExc = 0

  # basename 取得
  n = split(file, parts, "/")
  b = parts[n]
  if (length(b) > 3 && substr(b, length(b)-2) == ".md") {
    b = substr(b, 1, length(b)-3)
  }
  basename = b

  while ((getline line < file) > 0) {
    sub(/\r$/, "", line)

    # frontmatter 境界
    if (line ~ /^---[ \t]*$/) {
      if (inFM == 0 && fmDone == 0) {
        inFM = 1
        continue
      } else if (inFM == 1 && fmDone == 0) {
        inFM = 0
        fmDone = 1
        break   # frontmatter 終了したらそれ以上読まない
      }
    }

    if (inFM == 1) {
      low = tolower_str(line)

      if (index(low, "tags:") > 0) {
        hasTagsLine = 1

        # 必須タグチェック
        if (n_req > 0) {
          hasAllReq = 1
          for (i=1; i<=n_req; i++) {
            if (REQ[i] == "\001") continue
            # 単純に部分一致（tag 名は衝突しない前提）
            if (index(low, REQ[i]) == 0) {
              hasAllReq = 0
              break
            }
          }
        }

        # 除外タグチェック
        if (n_exc > 0) {
          for (j=1; j<=n_exc; j++) {
            if (EXC[j] == "\002") continue
            if (index(low, EXC[j]) > 0) {
              hasExc = 1
              break
            }
          }
        }
      }
    }
  }
  close(file)

  # tags: 行が一度も出てこなければ、どのみち必須タグを満たさないので対象外
  if (!hasTagsLine) next

  if (hasAllReq && !hasExc) {
    print basename
  }
}
' "${tmp_files}" > "${tmp_list}"

# ---------- 出力 ----------
{
  echo "# Tags Dashboard"
  echo
  echo "- ROOT: ${ROOT_DIR}"
  echo "- 必須タグ: ${REQ_TAGS:-<なし>}"
  echo "- 除外タグ: ${EXC_TAGS:-<なし>}"
  echo "- 生成時刻: $(date '+%Y-%m-%d %H:%M')"
  echo

  if [ ! -s "${tmp_list}" ]; then
    echo "> 該当するノートはありませんでした。"
  else
    # 並び順
    case "${ZK_TAG_SORT:-asc}" in
      desc)
        sort_cmd="sort -r"
        ;;
      none)
        sort_cmd="cat"
        ;;
      *)
        sort_cmd="sort"
        ;;
    esac

    echo "## ノート一覧"
    echo
    ${sort_cmd} "${tmp_list}" | while IFS= read -r base; do
      [ -z "${base}" ] && continue
      echo "- [[${base}]]"
    done
    echo
  fi
} > "${OUT}"

echo "[INFO] Wrote ${OUT}"
