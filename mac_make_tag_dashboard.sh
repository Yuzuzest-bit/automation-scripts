#!/usr/bin/env bash
# make_tag_dashboard.sh
#
# 概要:
# - TAG が空なら「タグ無視＝全オープン（FMに close/closed/closed_at が無い）」を拾う
# - TAG を渡せば、そのタグを含むノートだけに絞る
# - 出力は 1行形式「due : YYYY-MM-DD  [[basename]]」
# - 先頭にサマリ（総件数/期限切れ/今週/未設定、生成時刻、ROOT、条件）
# - 本文はグルーピング：
#     ⛔ 期限切れ（今日より前）
#     📅 今週（今日〜日曜）
#     📆 来週以降
#     ⏳ 期限未設定（9999-99-99）
# - macOS/BSD の `find`/`mktemp` で動作（GNU不要）
# - `.git`, `.vscode`, `.obsidian`, `.foam`, `node_modules`, `templates`, `template`, `dashboards` を除外
# - 既定で basename "daily-note" を除外（環境変数 TAGDASH_SKIP_NAMES で上書き/追加可能）
#
# 使い方例:
#   ./make_tag_dashboard.sh "" "ignored" "/path/to/notes"   # タグ無指定＝全オープン
#   ./make_tag_dashboard.sh "daily" "ignored" "/path/to/notes"
#
# デバッグ:
#   DASH_DEBUG=1 ./make_tag_dashboard.sh "" "ignored" "/path"

set -euo pipefail

TAG="${1:-}"                  # ← 空ならタグ無視（全オープン）
NEEDED_STATUS="${2:-ignored}" # 互換のため残置・未使用
ROOT_ARG="${3:-}"

# ---------- ROOT解決（引数 > 環境変数 > gitルート > PWD） ----------
resolve_root() {
  local cand=""
  # 1) 引数
  if [ -n "${ROOT_ARG}" ] && [ -d "${ROOT_ARG}" ]; then
    echo "${ROOT_ARG}"
    return
  fi
  # 2) 環境変数
  for v in TAGDASH_ROOT WORKSPACE_ROOT; do
    cand="${!v:-}"
    if [ -n "${cand}" ] && [ -d "${cand}" ]; then
      echo "${cand}"
      return
    fi
  done
  # 3) gitルート（PWD起点）
  if command -v git >/dev/null 2>&1; then
    if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
      git -C "$PWD" rev-parse --show-toplevel
      return
    fi
  fi
  # 4) 最後は PWD
  echo "$PWD"
}
ROOT="$(resolve_root)"

OUTDIR="${ROOT}/dashboards"
TAG_LABEL="${TAG:-all_open}"      # ← TAG未指定時の出力ファイル名に使う
OUT="${OUTDIR}/${TAG_LABEL}_dashboard.md"
mkdir -p "${OUTDIR}"

# mktemp（mac/BSD互換）
tmpfile="$(mktemp "${TMPDIR:-/tmp}/tagdash.XXXXXX")"
trap 'rm -f "$tmpfile"' EXIT

# 日付（今日・今週末）を計算
TODAY="$(date +%F)"
DOW="$(date +%u)" # 1=Mon..7=Sun
DAYS_TO_SUN=$(( (7 - DOW) % 7 ))
# mac(BSD)の date -v があれば使用、なければ GNU date / 汎用にフォールバック
if date -v+0d +%F >/dev/null 2>&1; then
  WEEK_END="$(date -v+${DAYS_TO_SUN}d +%F)"
elif command -v gdate >/dev/null 2>&1; then
  WEEK_END="$(gdate -d "${TODAY} + ${DAYS_TO_SUN} day" +%F)"
elif date -d "0 day" +%F >/dev/null 2>&1; then
  WEEK_END="$(date -d "${TODAY} + ${DAYS_TO_SUN} day" +%F)"
else
  WEEK_END="$TODAY"
fi
NOW="$(date '+%Y-%m-%d %H:%M')"

# ソートのブレ回避
export LC_ALL=C

# ---------- 走査：除外ディレクトリをグルーピングして prune ----------
find "$ROOT" -type d \( -name 'dashboards' -o -name '.git' -o -name '.vscode' -o -name '.obsidian' -o -name '.foam' -o -name 'node_modules' -o -name 'templates' -o -name 'template' \) -prune \
  -o -type f -name '*.md' -print | \
while IFS= read -r f; do
  awk -v file="$f" -v tag="$TAG" '
  BEGIN{
    inFM=0; hasTag=0; hasClose=0; dueVal=""; basename="";
    wantTag = (tag!="")               # TAGが空ならタグ条件を無視
    debug   = (ENVIRON["DASH_DEBUG"]!="" ? 1 : 0)

    # 既定のスキップ名（環境変数で上書き/追加可能: "daily-note,README" など）
    skiplist = (ENVIRON["TAGDASH_SKIP_NAMES"] != "" ? ENVIRON["TAGDASH_SKIP_NAMES"] : "daily-note")
    nskip = split(skiplist, SKIP, /[ ,]+/)
  }
  function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
  function trim(s){ return rtrim(ltrim(s)) }
  # キー名だけを厳密取得（:の左側のみ、クォート除去、小文字化）
  function parse_key_lower(s,    t,p,k){
    t=ltrim(s); p=index(t,":"); if(p==0) return "";
    k=trim(substr(t,1,p-1));
    if ((substr(k,1,1)=="\"" && substr(k,length(k),1)=="\"") || (substr(k,1,1)=="\047" && substr(k,length(k),1)=="\047"))
      k=substr(k,2,length(k)-2);
    k=tolower(k);
    return k
  }
  function is_skipped(name,    i){
    for(i=1;i<=nskip;i++) if(name==SKIP[i]) return 1;
    return 0
  }

  {
    line=$0

    # ベース名（.md拡張子除去）
    if (basename=="") {
      n=split(file, parts, "/"); b=parts[n];
      if (length(b)>3 && substr(b, length(b)-2)==".md") b=substr(b,1,length(b)-3);
      basename=b
    }

    # Front Matter 境界（CR/LF混在に備えtrim比較）
    if (trim(line)=="---") { inFM = !inFM; next }

    if (inFM==1) {
      key = parse_key_lower(line)
      if (key=="tags" && wantTag) {
        if (index(tolower(line), tolower(tag))>0) hasTag=1
      }
      if (key=="close" || key=="closed" || key=="closed_at") hasClose=1
      if (key=="due") {
        p=index(line,":"); if (p>0) dueVal=trim(substr(line,p+1))
      }
    }
  }
  END{
    if (dueVal=="") dueVal="9999-99-99"

    if (debug) {
      printf("DBG hasTag=%d wantTag=%d hasClose=%d due=%s base=%s :: %s\n",
             hasTag, wantTag, hasClose, dueVal, basename, file) > "/dev/stderr"
    }

    # 条件: (タグ不要 or タグ一致) かつ close系キーが無い かつ basenameがスキップ対象でない
    if (((!wantTag) || hasTag) && !hasClose && !is_skipped(basename)) {
      printf("%s\t%s\n", dueVal, basename)
    }
  }' "$f"
done > "$tmpfile"

# ---------- 出力（サマリ＋グルーピング＋1行形式） ----------
{
  if [ ! -s "$tmpfile" ]; then
    printf "> 該当なし\n"
  else
    # いったん due 昇順で並べてから awk で集計＆グルーピング
    sort "$tmpfile" | awk -F '\t' -v today="$TODAY" -v wend="$WEEK_END" -v now="$NOW" -v root="$ROOT" -v tag="$TAG" -v label="$TAG_LABEL" '
      BEGIN{
        total=0; c_over=0; c_week=0; c_future=0; c_nodue=0;
      }
      function push(arr, idx, val){ arr[idx]=val }
      {
        due=$1; base=$2; line=sprintf("due : %s  [[%s]]", due, base)
        total++
        if (due=="9999-99-99") {
          c_nodue++; push(nodue, c_nodue, line)
        } else if (due < today) {
          c_over++;  push(over,  c_over,  line)
        } else if (due <= wend) {
          c_week++;  push(week,  c_week,  line)
        } else {
          c_future++;push(future,c_future,line)
        }
      }
      END{
        cond = (tag=="" ? "All Open（FMに close系キーなし）" : "Tag=" tag)
        printf("# ダッシュボード: %s\n\n", (tag=="" ? "全オープン" : ("Tag: " tag)))
        printf("- 生成時刻: %s\n", now)
        printf("- ROOT: %s\n", root)
        printf("- 条件: %s\n", cond)
        printf("- 総件数: %d / 期限切れ: %d / 今週: %d / 未設定: %d\n\n", total, c_over, c_week, c_nodue)

        if (c_over>0) {
          printf("## ⛔ 期限切れ（%s より前）\n\n", today)
          for(i=1;i<=c_over;i++) printf("%s\n", over[i]); printf("\n")
        }
        if (c_week>0) {
          printf("## 📅 今週（%s 〜 %s）\n\n", today, wend)
          for(i=1;i<=c_week;i++) printf("%s\n", week[i]); printf("\n")
        }
        if (c_future>0) {
          printf("## 📆 来週以降\n\n")
          for(i=1;i<=c_future;i++) printf("%s\n", future[i]); printf("\n")
        }
        if (c_nodue>0) {
          printf("## ⏳ 期限未設定\n\n")
          for(i=1;i<=c_nodue;i++) printf("%s\n", nodue[i]); printf("\n")
        }

        # 何もヒットしない場合の保険（通常は通らない）
        if (total==0) { printf("> 該当なし\n") }
      }
    '
  fi
} > "$OUT"

echo "[INFO] Wrote ${OUT}"
