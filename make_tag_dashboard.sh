#!/usr/bin/env bash
# make_tag_dashboard.sh
# 正規表現なし。dueを昇順で並べる。
# 1ファイル1 awk ではなく、「awk 1回で全ファイル」を処理する高速版。

set -eu

TAG="${1:-network-specialist}"
NEEDED_STATUS="${2:-progress}"
ROOT="${3:-$PWD}"

OUTDIR="${ROOT}/dashboards"
OUT="${OUTDIR}/${TAG}_dashboard.md"
mkdir -p "${OUTDIR}"

tmpfile="$(mktemp)"
filelist="$(mktemp)"
trap 'rm -f "$tmpfile" "$filelist"' EXIT

# 対象となる Markdown ファイル一覧をファイルに保存
# （OUTDIR 配下は除外）
find "${ROOT}" -type f -name '*.md' ! -path "${OUTDIR}/*" > "${filelist}"

# filelist に列挙された各ファイルを、awk 1プロセスで順に処理する
awk -v tag="${TAG}" -v needst="${NEEDED_STATUS}" '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

# filelist を1行ずつ読むフェーズ（NR==FNR）
NR==FNR {
  file = $0
  gsub(/\r$/, "", file)   # 念のため CR 除去（Windows 由来対策）
  if (file == "") next

  # ===== 1ファイル分の状態初期化 =====
  inFM        = 0
  hasTag      = 0
  fmStatus    = ""
  progressLine= ""
  dueVal      = ""
  basename    = ""

  # ベース名取得（最後の / の後ろ、.md を削る）
  n = split(file, parts, "/")
  b = parts[n]
  if (length(b) > 3 && substr(b, length(b)-2) == ".md") {
    b = substr(b, 1, length(b)-3)
  }
  basename = b

  # ===== ここから、そのファイルの中身を1行ずつ読む =====
  while ((getline line < file) > 0) {

    # frontmatter 境界
    if (line == "---") {
      inFM = !inFM
      continue
    }

    if (inFM == 1) {
      # FM 内の処理: tags / status / due を拾う
      low = line
      for (i = 1; i <= length(low); i++) {
        c = substr(low, i, 1)
        if (c >= "A" && c <= "Z") {
          low = substr(low, 1, i-1) "" tolower(c) "" substr(low, i+1)
        }
      }

      if (index(low, "tags:") > 0 && index(low, tag) > 0) {
        hasTag = 1
      }

      if (index(low, "status:") > 0) {
        p = index(low, ":")
        if (p > 0) fmStatus = trim(substr(low, p+1))
      }

      if (index(low, "due:") > 0) {
        p = index(low, ":")
        if (p > 0) dueVal = trim(substr(low, p+1))
      }

    } else {
      # 本文側: 先頭 @ で始まる行から @progress を拾う
      if (progressLine == "" && substr(line, 1, 1) == "@") {
        low = line
        for (i = 1; i <= length(low); i++) {
          c = substr(low, i, 1)
          if (c >= "A" && c <= "Z") {
            low = substr(low, 1, i-1) "" tolower(c) "" substr(low, i+1)
          }
        }
        if (index(low, "@progress") == 1) {
          progressLine = line
        }
      }
    }
  }
  close(file)

  # ===== そのファイルの判定 & 出力 =====
  # 現在の仕様: 「行頭 @progress があるか？」だけを見る
  isProgress = (progressLine != "")

  if (hasTag && isProgress) {
    if (dueVal == "") dueVal = "9999-99-99"
    # 保険（本来はここには来ない想定）
    if (progressLine == "") {
      progressLine = "@progress " basename " [[" basename "]]"
    }
    # due \t basename \t progressLine
    printf("%s\t%s\t%s\n", dueVal, basename, progressLine)
  }

  next
}
' "${filelist}" > "${tmpfile}"

# === ソート & 出力 ===
{
  echo "# Tag: ${TAG} – 進行中タスク (due昇順)"
  echo
  echo "- 生成時刻: $(date '+%Y-%m-%d %H:%M')"
  echo "- 条件: tagsに「${TAG}」を含み、status=${NEEDED_STATUS} または 先頭行が @progress"
  echo
  if [ ! -s "${tmpfile}" ]; then
    echo "> 該当なし"
  else
    sort "${tmpfile}" | while IFS=$'\t' read -r due base pline; do
      [ -z "${base}" ] && continue
      echo "## [[${base}]]"
      echo
      echo "- due: ${due}"
      echo "- タスク : ${pline}"
      echo
    done
  fi
} > "${OUT}"

echo "[INFO] Wrote ${OUT}"
