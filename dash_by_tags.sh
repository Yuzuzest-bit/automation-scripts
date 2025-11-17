#!/usr/bin/env bash
# dash_by_tags.sh <tag1> [tag2 ...]
# frontmatter tags: に指定されたタグ群をもとに、
# 指定したタグをすべて含むノートのダッシュボードを作成する
# macOS(Homebrew bash) / Windows Git Bash 想定
#
# 仕様:
# - ルートディレクトリはこの .sh が置かれているフォルダ
# - その配下のサブフォルダを find で再帰的に探索
# - dashboards/tags_search.md に毎回上書き出力
# - 並び順:
#     ZK_TAG_SORT=asc  (デフォルト) ... id 昇順（古い順）
#     ZK_TAG_SORT=desc             ... id 降順（新しい順）
#     ZK_TAG_SORT=none             ... ソートなし（find 順）

set -euo pipefail

# このスクリプト自身が置かれているディレクトリをルートにする
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$SCRIPT_DIR"

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 <tag1> [tag2 ...]" >&2
  exit 2
fi

# 引数でもらったタグ（大文字小文字は AWK 側で吸収）
TAGS=("$@")

OUTDIR="$ROOT/dashboards"
mkdir -p "$OUTDIR"

# ★ 出力ファイル名は固定（VS Code から常にこれを開けばOK）
OUTFILE="$OUTDIR/tags_search.md"

NOW="$(date '+%Y-%m-%d %H:%M')"
export LC_ALL=C

# タグリスト "tag1,tag2,..." にして AWK に渡す
TAG_STR=""
for t in "${TAGS[@]}"; do
  if [[ -z "$TAG_STR" ]]; then
    TAG_STR="$t"
  else
    TAG_STR="$TAG_STR,$t"
  fi
done

# 除外ディレクトリ（必要に応じて環境変数で追加も可）
DEFAULT_SKIPS=".git .vscode .obsidian .foam node_modules templates template dashboards"
EXTRA_SKIPS="${ZK_DASH_SKIP_DIRS:-}"
SKIP_DIRS="${DEFAULT_SKIPS} ${EXTRA_SKIPS}"

TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/zktags.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

# find の引数を配列で組み立て（サブフォルダも再帰的に探索）
FIND_ARGS=( "$ROOT" -type f -name '*.md' )
for s in $SKIP_DIRS; do
  FIND_ARGS+=( ! -path "*/$s/*" )
done

find "${FIND_ARGS[@]}" | \
while IFS= read -r f; do
  awk -v file="$f" -v wanted="$TAG_STR" '
  BEGIN{
    inFM=0
    id=""
    title=""
    basename=""
    n=split(file, parts, "/")
    b=parts[n]
    if (length(b) > 3 && substr(b, length(b)-2) == ".md") {
      b = substr(b, 1, length(b)-3)
    }
    basename = b

    # wanted tags
    wantCount=0
    split(wanted, wtmp, ",")
    for (i in wtmp) {
      if (wtmp[i] != "") {
        want[++wantCount] = tolower(wtmp[i])
      }
    }
  }
  function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
  function trim(s){ return rtrim(ltrim(s)) }
  function key_of(s,    t,p,k){
    t=ltrim(s); p=index(t,":"); if(p==0) return "";
    k=trim(substr(t,1,p-1));
    # 小文字化
    for(i=1;i<=length(k);i++){
      c=substr(k,i,1)
      if(c>="A"&&c<="Z") k=substr(k,1,i-1) "" tolower(c) "" substr(k,i+1)
    }
    return k
  }
  {
    line=$0
    # frontmatter の境界
    if (trim(line)=="---") { inFM = !inFM; next }

    if (inFM==1) {
      k=key_of(line)
      if (k=="id" && id=="") {
        p=index(line,":")
        if(p>0){ id=trim(substr(line,p+1)) }
      } else if (k=="tags") {
        # 1 行で tags: [ ... ] と書かれている前提（多少はゆるく見る）
        L=tolower(line)
        list=""
        s=index(L,"["); e=index(L,"]")
        if (s>0 && e>s) {
          list=substr(L,s+1,e-s-1)
        } else {
          p=index(L,":")
          if (p>0) { list=substr(L,p+1) }
        }

        # [, ], " を削除
        gsub(/\[/, "", list)
        gsub(/\]/, "", list)
        gsub(/"/, "", list)

        # カンマをスペースに
        gsub(/,/, " ", list)

        n2=split(list, arr, /[ \t]+/)
        for (j=1;j<=n2;j++) {
          if (arr[j]!="") tags[tolower(arr[j])] = 1
        }
      }
    } else {
      # 本文側、最初の "# " 行をタイトルとして拾う（今は使っていないが保持）
      if (title=="" && index(line, "# ")==1) {
        title=substr(line,3)
      }
    }
  }
  END{
    if (wantCount==0) exit 0
    # AND 条件：指定されたタグをすべて持っているか？
    ok=1
    for (i=1;i<=wantCount;i++) {
      t = want[i]
      if (!(t in tags)) { ok=0; break }
    }
    if (ok) {
      # 出力: id \t basename \t title \t file
      printf("%s\t%s\t%s\t%s\n", id, basename, title, file)
    }
  }' "$f"
done > "$TMP_FILE"

# id でソート（無い場合はそのまま）
if [ -s "$TMP_FILE" ]; then
  case "${ZK_TAG_SORT:-asc}" in
    desc)
      # 新しい順（id 降順）
      sort -t $'\t' -k1,1r "$TMP_FILE" -o "$TMP_FILE"
      ;;
    none)
      # ソートしない（find の順のまま）
      :
      ;;
    *)
      # デフォルト: 古い順（id 昇順）
      sort -t $'\t' -k1,1 "$TMP_FILE" -o "$TMP_FILE"
      ;;
  esac
fi

{
  printf "# Tag Dashboard: "
  first=1
  IFS=',' read -r -a disp <<< "$TAG_STR"
  for idx in "${!disp[@]}"; do
    t="${disp[$idx]}"
    [ -z "$t" ] && continue
    if [ $first -eq 0 ]; then
      printf " + "
    fi
    printf "%s", "$t"
    first=0
  done
  printf "\n\n"

  printf -- "- 生成時刻: %s\n" "$NOW"
  printf -- "- ROOT: %s\n\n" "$ROOT"

  if [ ! -s "$TMP_FILE" ]; then
    printf "> 該当なし\n"
  else
    while IFS=$'\t' read -r id base title path; do
      # タイトル表示はやめて、wikilink だけを出力
      printf -- "- [[%s]]\n" "$base"
    done < "$TMP_FILE"
  fi
} > "$OUTFILE"

echo "[OK] Wrote $OUTFILE"
