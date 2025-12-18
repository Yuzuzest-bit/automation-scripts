#!/usr/bin/env bash
# make_tag_structure_dashboard.sh
#
# 目的:
# - 未クローズタスク（+その祖先ノート）を parent: に基づいてツリー表示する（週次整理用）
#
# 出力:
# - dashboards/structure_dashboard.md
#
# 使い方:
#   1) ルートだけ指定（タグ無し）:
#      ./make_tag_structure_dashboard.sh /path/to/ROOT
#
#   2) タグだけ（ROOTはPWD）:
#      ./make_tag_structure_dashboard.sh "issue"
#
#   3) タグ + ROOT:
#      ./make_tag_structure_dashboard.sh issue /path/to/ROOT
#      ./make_tag_structure_dashboard.sh issue ctx-life /path/to/ROOT
#
#   4) 旧形式互換:
#      ./make_tag_structure_dashboard.sh "issue ctx-life" "ignored" /path/to/ROOT
#
# オプション環境変数:
#   OPEN_DASH=0  … 生成後に自動で開かない（デフォルトは開く）
#   DEBUG=1      … 一時ファイルを消さず、件数を表示

set -euo pipefail

OPEN_DASH="${OPEN_DASH:-1}"
DEBUG="${DEBUG:-0}"

# ------------------------------------------------------------
# 引数パース
# ------------------------------------------------------------
TAG_ARGS=()

if [ "$#" -eq 1 ] && [ -d "${1}" ]; then
  ROOT="${1}"
else
  if [ "$#" -eq 0 ]; then
    ROOT="$PWD"
  elif [ "$#" -eq 1 ]; then
    ROOT="$PWD"
    TAG_ARGS+=("$1")
  else
    eval "ROOT=\${$#}"
    i=1
    last=$(( $# - 1 ))
    while [ "$i" -le "$last" ]; do
      eval "arg=\${$i}"

      if [ "$i" -eq 1 ] && [ "$#" -ge 3 ] && [ "${2-}" = "ignored" ]; then
        for t in $arg; do
          [ -n "$t" ] && TAG_ARGS+=("$t")
        done
        break
      fi

      [ -n "$arg" ] && TAG_ARGS+=("$arg")
      i=$(( i + 1 ))
    done
  fi
fi

if [ "${#TAG_ARGS[@]}" -eq 0 ]; then
  TAG=""
else
  TAG="${TAG_ARGS[*]}"
fi

OUTDIR="${ROOT}/dashboards"
mkdir -p "${OUTDIR}"
OUT="${OUTDIR}/structure_dashboard.md"

tmp_nodes="$(mktemp)"
tmp_show="$(mktemp)"
tmp_edges="$(mktemp)"
tmp_edges_sorted="$(mktemp)"
filelist="$(mktemp)"

cleanup() {
  if [ "${DEBUG}" = "1" ]; then
    echo "[DBG] tmp_nodes=${tmp_nodes}"
    echo "[DBG] tmp_show=${tmp_show}"
    echo "[DBG] tmp_edges=${tmp_edges}"
    echo "[DBG] tmp_edges_sorted=${tmp_edges_sorted}"
    echo "[DBG] filelist=${filelist}"
  else
    rm -f "$tmp_nodes" "$tmp_show" "$tmp_edges" "$tmp_edges_sorted" "$filelist"
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------
# 対象 markdown 列挙（dashboards/.dashboardignore を反映）
# ------------------------------------------------------------
EXCLUDE_DIRS=()

# dashboards/.dashboardignore（1行=1項目, #コメント可）
IGNORE_FILE="${OUTDIR}/.dashboardignore"
if [ -f "${IGNORE_FILE}" ]; then
  while IFS= read -r line; do
    # コメント除去＋前後空白トリム
    line="$(printf '%s' "$line" | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$line" ] && EXCLUDE_DIRS+=("$line")
  done < "${IGNORE_FILE}"
fi

# prune 対象（デフォルト除外）
PRUNE_DIRS=(
  "${OUTDIR}"
  "${ROOT}/.foam"
  "${ROOT}/.git"
  "${ROOT}/.vscode"
  "${ROOT}/node_modules"
)

# .dashboardignore の除外（ROOT相対 or 絶対）
for ex in "${EXCLUDE_DIRS[@]}"; do
  ex="${ex%/}"
  [ -z "$ex" ] && continue

  # "templates/*" みたいな書き方も許容（親ディレクトリを除外）
  if [[ "$ex" == */\* ]]; then
    ex="${ex%/*}"
    ex="${ex%/}"
    [ -z "$ex" ] && continue
  fi

  if [[ "$ex" == /* ]]; then
    PRUNE_DIRS+=("$ex")
  else
    ex="${ex#./}"
    PRUNE_DIRS+=("${ROOT}/${ex}")
  fi
done

# find（-prune で除外）
FIND_CMD=(find "${ROOT}")
FIND_CMD+=("(" -type d "(")
first=1
for p in "${PRUNE_DIRS[@]}"; do
  if [ $first -eq 1 ]; then
    FIND_CMD+=(-path "$p")
    first=0
  else
    FIND_CMD+=(-o -path "$p")
  fi
done
FIND_CMD+=(")" -prune ")")
FIND_CMD+=(-o "(" -type f -name '*.md' -print ")")

"${FIND_CMD[@]}" > "${filelist}"

if [ "${DEBUG}" = "1" ]; then
  echo "[DBG] md files: $(wc -l < "${filelist}" | tr -d " ")"
  if [ -f "${IGNORE_FILE}" ]; then
    echo "[DBG] ignore file: ${IGNORE_FILE}"
    echo "[DBG] ignore dirs: ${EXCLUDE_DIRS[*]:-(none)}"
  else
    echo "[DBG] ignore file: (none)"
  fi
fi


# ------------------------------------------------------------
# Stage1: frontmatter抽出 → tmp_nodes
# 出力TSV:
# id, parent, closed(0/1), due, pri, bd, gate, src, wgt, focus, awaiting, awaitingWho, basename, tagOK, relpath
#   - frontmatter無しでも出力する（closed=0扱い）
#   - @focus / @awaiting は本文も含めて全文検索（awkのmatch第3引数は使わない＝BSD awk互換）
# ------------------------------------------------------------
awk -v tag="${TAG}" -v root="${ROOT}" '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

function strip_bom(s){
  sub(/^\357\273\277/, "", s)  # UTF-8 BOM
  return s
}
function relpath(p,    pre){
  pre = root
  if (substr(pre, length(pre), 1) != "/") pre = pre "/"
  if (index(p, pre) == 1) return substr(p, length(pre)+1)
  return p
}
function norm_tag(t,    s){
  s = tolower(trim(t))
  gsub(/^#+/, "", s)
  gsub(/^["'\''`]+|["'\''`]+$/, "", s)
  return s
}
function see_tag(t,    nt){
  nt = norm_tag(t)
  if (nt=="") return
  tagsSeen[nt]=1
  if (index(nt, "braindump")>0) isBrainDump=1
  if (nt ~ /^gate-/) isGate=1
}

BEGIN{
  nTag = 0
  if (tag != "") {
    nTag = split(tag, wantedRaw, /[[:space:]]+/)
    for (i=1; i<=nTag; i++) wanted[i] = norm_tag(wantedRaw[i])
  }
}

NR==FNR {
  file=$0
  gsub(/\r$/, "", file)
  if (file=="") next

  delete tagsSeen

  # defaults
  idVal=""; parentVal=""
  hasDue=0; dueVal=""
  isClosed=0
  isBrainDump=0
  isGate=0
  priVal=3
  srcVal="self"
  wgtVal="soft"

  isFocus=0
  isAwait=0
  awaitWho=""

  tagOK = (tag=="" ? 1 : 0)

  rp = relpath(file)

  # basename
  n = split(file, parts, "/")
  b = parts[n]
  if (length(b) > 3 && substr(b, length(b)-2) == ".md") b = substr(b, 1, length(b)-3)
  basename=b

  # frontmatter: 最初の非空行が --- ならFM
  inFM=0; hasFM=0; fmDone=0; inTags=0; firstNonEmptySeen=0

  while ((getline line < file) > 0) {
    sub(/\r$/, "", line)
    line = strip_bom(line)

    # --- 本文検索: @focus / @awaiting（FMの外でも中でもOK）
    lowline = tolower(line)

    if (!isFocus) {
      if (match(lowline, /@focus([^[:alnum:]_]|$)/)) isFocus=1
    }
    if (!isAwait) {
      if (match(lowline, /@awaiting[[:space:]]+/)) {
        isAwait=1
        who = substr(line, RSTART+RLENGTH)
        who = trim(who)
        gsub(/\t+/, " ", who)
        gsub(/[[:space:]]+$/, "", who)
        # 末尾のコメントっぽいものは軽く削る（必要ならここを外してもOK）
        sub(/[[:space:]]*<!--.*$/, "", who)
        sub(/[[:space:]]*#.*$/, "", who)
        who = trim(who)
        if (length(who) > 60) who = substr(who, 1, 60) "..."
        awaitWho = who
      }
    }

    tmp=line; gsub(/[ \t]/, "", tmp)

    if (!firstNonEmptySeen) {
      if (tmp=="") continue
      firstNonEmptySeen=1
      if (line ~ /^[[:space:]]*---[[:space:]]*$/) {
        hasFM=1
        inFM=1
        continue
      } else {
        # frontmatter無し → FM解析はしないが、本文検索は続ける
        hasFM=0
        inFM=0
        # ここから先も読む（@focus/@awaiting検出のため）
      }
    }

    if (hasFM && inFM==1) {
      low = tolower(line)
      copy = low; gsub(/[ \t]/, "", copy)

      # 終端: --- または ... を許可（壊れたFMで本文まで読まない）
      if (line ~ /^[[:space:]]*(---|\.\.\.)[[:space:]]*$/) {
        fmDone=1
        inFM=0
        inTags=0
        continue
      }

      # tags:（1行 / リスト両対応）
      if (low ~ /^[[:space:]]*tags:[[:space:]]*/) {
        rest=line
        sub(/^[[:space:]]*tags:[[:space:]]*/, "", rest)
        rest = trim(rest)

        inTags = 0
        if (rest=="") {
          inTags = 1
        } else {
          gsub(/[\[\],]/, " ", rest)
          gsub(/["'\''`]/, "", rest)
          nt = split(rest, toks, /[[:space:]]+/)
          for (k=1; k<=nt; k++) see_tag(toks[k])
        }
      } else if (inTags==1) {
        if (line ~ /^[[:space:]]*-[[:space:]]*/) {
          item=line
          sub(/^[[:space:]]*-[[:space:]]*/, "", item)
          item = trim(item)
          gsub(/["'\''`]/, "", item)
          see_tag(item)
        } else if (tmp=="") {
          # 空行はOK
        } else {
          inTags=0
        }
      }

      # id:
      if (low ~ /^[[:space:]]*id:[[:space:]]*/) {
        tmp2=line
        sub(/^[[:space:]]*id:[[:space:]]*/, "", tmp2)
        idVal=trim(tmp2)
        gsub(/^["'\''`]+|["'\''`]+$/, "", idVal)
      }

      # parent:
      if (low ~ /^[[:space:]]*parent:[[:space:]]*/) {
        tmp2=line
        sub(/^[[:space:]]*parent:[[:space:]]*/, "", tmp2)
        parentVal=trim(tmp2)
        gsub(/^["'\''`]+|["'\''`]+$/, "", parentVal)
      }

      # due:
      if (copy ~ /^due:/) {
        tmp2=line
        sub(/^[[:space:]]*due:[[:space:]]*/, "", tmp2)
        tmp2=trim(tmp2)
        if (tmp2 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) {
          dueVal = substr(tmp2, 1, 10)
          hasDue = 1
        }
      }

      # closed:
      if (copy ~ /^closed:/) isClosed=1

      # priority:
      if (low ~ /^[[:space:]]*priority:[[:space:]]*/) {
        tmp2=line
        sub(/^[[:space:]]*priority:[[:space:]]*/, "", tmp2)
        tmp2=tolower(trim(tmp2))
        sub(/^#/, "", tmp2)
        tmp2=trim(tmp2)

        if (tmp2 ~ /^1/ || tmp2 ~ /^high/ || tmp2 ~ /^p1/) priVal=1
        else if (tmp2 ~ /^2/ || tmp2 ~ /^mid/ || tmp2 ~ /^medium/ || tmp2 ~ /^p2/) priVal=2
        else if (tmp2 ~ /^3/ || tmp2 ~ /^low/ || tmp2 ~ /^p3/) priVal=3
      }

      # due_source:
      if (low ~ /^[[:space:]]*due_source:[[:space:]]*/) {
        tmp2=tolower(line)
        sub(/^[[:space:]]*due_source:[[:space:]]*/, "", tmp2)
        tmp2=trim(tmp2)
        if (tmp2 ~ /^other/) srcVal="other"
        else srcVal="self"
      }

      # due_weight:
      if (low ~ /^[[:space:]]*due_weight:[[:space:]]*/) {
        tmp2=tolower(line)
        sub(/^[[:space:]]*due_weight:[[:space:]]*/, "", tmp2)
        tmp2=trim(tmp2)
        if (tmp2 ~ /^hard/) wgtVal="hard"
        else wgtVal="soft"
      }
    }
  }
  close(file)

  # タグ条件評価（tagsSeen に全部あるか）
  if (tag != "") {
    allOK=1
    for (ti=1; ti<=nTag; ti++) {
      wt = wanted[ti]
      if (wt=="") continue
      if (!(wt in tagsSeen)) { allOK=0; break }
    }
    if (allOK) tagOK=1
  }

  # @focus があれば @awaiting 表示は抑制（優先）
  if (isFocus==1) {
    isAwait=0
    awaitWho=""
  }

  # awaitingWho のTSV安全化
  gsub(/\t+/, " ", awaitWho)
  gsub(/\r+/, " ", awaitWho)
  gsub(/\n+/, " ", awaitWho)
  awaitWho = trim(awaitWho)

  printf("%s\t%s\t%d\t%s\t%d\t%d\t%d\t%s\t%s\t%d\t%d\t%s\t%s\t%d\t%s\n",
         idVal, parentVal, isClosed, (hasDue?dueVal:""), priVal, isBrainDump, isGate,
         srcVal, wgtVal, isFocus, isAwait, awaitWho, basename, tagOK, rp)
}' "${filelist}" > "${tmp_nodes}"

if [ "${DEBUG}" = "1" ]; then
  echo "[DBG] nodes lines: $(wc -l < "${tmp_nodes}" | tr -d " ")"
fi

# ------------------------------------------------------------
# Stage2: show集合（未クローズ + 祖先） → tmp_show
# tmp_show TSV:
# id, parent, key, openDesc, closed, due, pri, bd, gate, src, wgt, focus, awaiting, awaitingWho, base, active, relpath
# ------------------------------------------------------------
awk -F'\t' '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

function norm_ref(s,    t) {
  t = trim(s)
  gsub(/^["'\''`]+|["'\''`]+$/, "", t)

  if (t ~ /^\[\[/) {
    sub(/^\[\[/, "", t)
    sub(/\]\]$/, "", t)
    sub(/\|.*/, "", t)
    t = trim(t)
  }
  sub(/\.md$/, "", t)
  return t
}

BEGIN{ ROOT="ROOT" }

{
  id=$1
  parentRaw=$2
  closed=$3+0
  due=$4
  pri=$5+0
  bd=$6+0
  gate=$7+0
  src=$8
  wgt=$9
  focus=$10+0
  awaiting=$11+0
  awho=$12
  base=$13
  tagOK=$14+0
  rel=$15

  if (id=="") id="path:" rel

  ids[++N]=id
  baseById[id]=base
  relById[id]=rel

  idByBase[base]=id

  rawParent[id]=parentRaw
  closedById[id]=closed
  dueById[id]=due
  priById[id]=pri
  bdById[id]=bd
  gateById[id]=gate
  srcById[id]=src
  wgtById[id]=wgt
  focusById[id]=focus
  awaitingById[id]=awaiting
  awaitWhoById[id]=awho
  tagOKById[id]=tagOK
}

END{
  for (i=1; i<=N; i++) {
    id=ids[i]
    p = norm_ref(rawParent[id])

    if (p=="" || p=="-") { parentOf[id]=ROOT; continue }

    if (p in baseById)        parentOf[id]=p
    else if (p in idByBase)   parentOf[id]=idByBase[p]
    else                      parentOf[id]=ROOT
  }

  for (i=1; i<=N; i++) {
    id=ids[i]
    if (tagOKById[id]==1 && closedById[id]==0) active[id]=1
  }

  for (i=1; i<=N; i++) {
    id=ids[i]
    if (!active[id]) continue

    show[id]=1
    k = (dueById[id]!="") ? dueById[id] : "9999-99-98"

    cur=id
    guard=0
    while (cur!=ROOT && guard<200) {
      if (!(cur in keyById) || k < keyById[cur]) keyById[cur]=k

      p=parentOf[cur]
      if (p==ROOT) break

      show[p]=1
      openDesc[p]++
      if (p==cur) break
      cur=p
      guard++
    }

    if (!(id in openDesc)) openDesc[id]=0
  }

  for (i=1; i<=N; i++) {
    id=ids[i]
    if (!show[id]) continue

    p = parentOf[id]
    k = (id in keyById) ? keyById[id] : "9999-99-99"

    od = 0
    if (id in openDesc) od = openDesc[id]

    af = 0
    if (active[id]) af = 1

    print id "\t" p "\t" k "\t" od "\t" closedById[id] "\t" dueById[id] \
          "\t" priById[id] "\t" bdById[id] "\t" gateById[id] "\t" srcById[id] \
          "\t" wgtById[id] "\t" focusById[id] "\t" awaitingById[id] "\t" awaitWhoById[id] \
          "\t" baseById[id] "\t" af "\t" relById[id]
  }
}' "${tmp_nodes}" > "${tmp_show}"

if [ "${DEBUG}" = "1" ]; then
  echo "[DBG] show lines: $(wc -l < "${tmp_show}" | tr -d " ")"
fi

# ------------------------------------------------------------
# edges作成＆ソート（parentごとに、配下最短due→priority→id の順）
# ------------------------------------------------------------
awk -F'\t' '{ print $2 "\t" $3 "\t" $7 "\t" $1 }' "${tmp_show}" > "${tmp_edges}"
sort -k1,1 -k2,2 -k3,3n -k4,4 "${tmp_edges}" > "${tmp_edges_sorted}"

# ------------------------------------------------------------
# Stage3: Markdown出力（空行なし / root-orphan分割なし）
# ------------------------------------------------------------
{
  echo "# Structure – 親子インデント（週次整理用）"
  echo "- 生成時刻: $(date '+%Y-%m-%d %H:%M')"
  if [ -z "${TAG}" ]; then
    echo "- 条件: 未クローズ（+祖先ノートを表示）"
  else
    echo "- 条件: tags に「${TAG}」すべてを含む未クローズ（+祖先ノートを表示）"
  fi
  echo "- 並び: 親ブロックは「配下の最短 due」で概ね前へ、子はその中で同様に並ぶ（完全な全体ソートはしない）"
  echo "- 記号: 🔴🟠🟢 priority / 🚧 gate / 🔥 BrainDump / 🤝 other / ⚠️ hard / ✅ closed / ⚠️✅＝閉じてるのに未完了の子がいる疑い / 🎯 @focus / ⏳ @awaiting"
  echo "## 🧭 ROOT"

  awk -F'\t' '
  function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
  function trim(s){ return rtrim(ltrim(s)) }

  function indent(n,    s,i){ s=""; for(i=0;i<n;i++) s=s"  "; return s }
  function pri_icon(p){
    if (p<=1) return "🔴"
    else if (p==2) return "🟠"
    else return "🟢"
  }
  function meta_icon(src,wgt,    s){
    s=""
    if (src=="other") s=s"🤝"
    if (wgt=="hard")  s=s"⚠️"
    return s
  }
  function combo_icon(pri, gate, bd,    s){
    s=pri_icon(pri)
    if (gate>0) s=("🚧" s)
    if (bd>0)   s=("🔥" s)
    return s
  }
  function wlink(id,    b,r){
    b=baseById[id]; r=relById[id]
    if (b=="") return "[[UNKNOWN]]"
    if (baseCount[b] > 1 && r!="") return "[[" r "|" b "]]"
    return "[[" b "]]"
  }
  function esc_inline(s){
    # 箇条書きの中で変に崩れない程度にタブだけ潰す（必要最低限）
    gsub(/\t+/, " ", s)
    return s
  }

  NR==FNR{
    id=$1; parent=$2
    openDesc=$4+0
    closed=$5+0
    due=$6
    pri=$7+0
    bd=$8+0
    gate=$9+0
    src=$10
    wgt=$11
    focus=$12+0
    awaiting=$13+0
    awho=$14
    base=$15
    active=$16+0
    rel=$17

    id=trim(id)
    parent=trim(parent)

    ids[++N]=id

    parentOf[id]=parent
    closedById[id]=closed
    dueById[id]=due
    priById[id]=pri
    bdById[id]=bd
    gateById[id]=gate
    srcById[id]=src
    wgtById[id]=wgt
    focusById[id]=focus
    awaitingById[id]=awaiting
    awaitWhoById[id]=awho
    baseById[id]=base
    relById[id]=rel
    openDescById[id]=openDesc
    activeById[id]=active

    baseCount[base]++
    next
  }

  {
    p=trim($1)
    id=trim($4)
    if (p=="" || id=="") next
    if (children[p]=="") children[p]=id
    else children[p]=children[p] "\n" id
  }

  function print_node(id, depth,    line,mi,icon,title,mark,em,aw,lk){
    if (vis[id]) {
      print indent(depth) "- 🔁 " wlink(id) " (cycle?)"
      return
    }
    vis[id]=1

    mi = meta_icon(srcById[id], wgtById[id])
    icon = combo_icon(priById[id], gateById[id], bdById[id])

    # emphasis marker (🎯 or ⏳)
    em=""
    if (focusById[id]==1) {
      em="🎯"
    } else if (awaitingById[id]==1) {
      aw = trim(awaitWhoById[id])
      aw = esc_inline(aw)
      if (aw!="") em="⏳(" aw ")"
      else        em="⏳"
    }

    lk = wlink(id)

    # closed mark & link formatting
    if (closedById[id]==1) {
      mark = "✅"
      if (openDescById[id] > 0) mark = "⚠️✅"
      lk = "~~" lk "~~"
    } else {
      mark = ""
    }

    # 強調：🎯/⏳ が付くノートはリンクを太字にする
    if (em!="") lk = "**" lk "**"

    title = lk

    if (dueById[id] != "") line = "- " dueById[id] " " icon
    else                   line = "- " icon

    if (mark != "") line = line " " mark
    if (mi != "")   line = line " " mi
    if (em != "")   line = line " " em
    line = line " " title

    print indent(depth) line

    if (children[id] != "") {
      n = split(children[id], arr, "\n")
      for (i = 1; i <= n; i++) {
        cid = trim(arr[i])
        if (cid=="") continue
        print_node(cid, depth+1)
      }
    }
  }

  END{
    if (N==0) { print "> 該当なし"; exit }

    # 1) parent=ROOT のものを先に出す
    if (children["ROOT"]!="") {
      n = split(children["ROOT"], arr, "\n")
      for (i=1; i<=n; i++) {
        rid = trim(arr[i])
        if (rid=="") continue
        print_node(rid, 0)
      }
    }

    # 2) ROOTに繋がらないノードも続けて出す（セクション分け無し）
    for (i=1; i<=N; i++) {
      id = ids[i]
      if (id=="" || id=="ROOT") continue
      if (vis[id]) continue
      print_node(id, 0)
    }
  }
  ' "${tmp_show}" "${tmp_edges_sorted}"

} > "${OUT}"

echo "[INFO] Wrote ${OUT}"

# ------------------------------------------------------------
# 生成後にダッシュボードを開く
# ------------------------------------------------------------
if [ "${OPEN_DASH}" != "0" ]; then
  if command -v code >/dev/null 2>&1; then
    code -r "${OUT}" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "${OUT}" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${OUT}" >/dev/null 2>&1 || true
  fi
fi
