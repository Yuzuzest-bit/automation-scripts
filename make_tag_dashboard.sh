#!/usr/bin/env bash
# make_tag_dashboard.sh
# 正規表現なし。dueを昇順で並べる。

set -eu
TAG="${1:-network-specialist}"
NEEDED_STATUS="${2:-progress}"
ROOT="${3:-$PWD}"

OUTDIR="${ROOT}/dashboards"
OUT="${OUTDIR}/${TAG}_dashboard.md"
mkdir -p "${OUTDIR}"

tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT

find "${ROOT}" -type f -name '*.md' ! -path "${OUTDIR}/*" | while IFS= read -r f; do
  awk -v file="$f" -v tag="$TAG" -v needst="$NEEDED_STATUS" '
  BEGIN{
    inFM=0; hasTag=0; fmStatus=""; progressLine=""; dueVal=""; basename="";
  }
  function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
  function trim(s){ return rtrim(ltrim(s)) }

  {
    line=$0
    if (basename=="") {
      n=split(file, parts, "/"); b=parts[n];
      if (length(b)>3 && substr(b, length(b)-2) == ".md") b=substr(b,1,length(b)-3);
      basename=b
    }

    if (line=="---") { inFM = !inFM; next }

    if (inFM==1) {
      low=line
      for(i=1;i<=length(low);i++){ c=substr(low,i,1); if (c>="A" && c<="Z") low=substr(low,1,i-1) "" tolower(c) "" substr(low,i+1) }
      if (index(low,"tags:")>0 && index(low,tag)>0) hasTag=1
      if (index(low,"status:")>0) { p=index(low,":"); if (p>0) fmStatus=trim(substr(low,p+1)) }
      if (index(low,"due:")>0) { p=index(low,":"); if (p>0) dueVal=trim(substr(low,p+1)) }
    } else {
      if (progressLine=="" && substr(line,1,1)=="@") {
        low=line
        for(i=1;i<=length(low);i++){ c=substr(low,i,1); if (c>="A" && c<="Z") low=substr(low,1,i-1) "" tolower(c) "" substr(low,i+1) }
        if (index(low,"@progress")==1) progressLine=line
      }
    }
  }
  END{
    # ここを「行頭だけを見る」にする
    isProgress = (progressLine != "")

    if (hasTag && isProgress) {
      if (dueVal=="") dueVal="9999-99-99"
      # 本来はここには来ない想定だが保険として残すならこれでもOK
      if (progressLine=="") progressLine="@progress " basename " [[" basename "]]"
      printf("%s\t%s\t%s\n", dueVal, basename, progressLine)
    }
  }' "$f"
done > "$tmpfile"

# === ソート & 出力 ===
{
  echo "# Tag: ${TAG} – 進行中タスク (due昇順)"
  echo
  echo "- 生成時刻: $(date '+%Y-%m-%d %H:%M')"
  echo "- 条件: tagsに「${TAG}」を含み、status=${NEEDED_STATUS} または 先頭行が @progress"
  echo
  if [ ! -s "$tmpfile" ]; then
    echo "> 該当なし"
  else
    sort "$tmpfile" | while IFS=$'\t' read -r due base pline; do
      [ -z "$base" ] && continue
      echo "## [[${base}]]"
      echo
      echo "- due: ${due}"
      echo "- タスク : ${pline}"
      echo
    done
  fi
} > "$OUT"

echo "[INFO] Wrote ${OUT}"
