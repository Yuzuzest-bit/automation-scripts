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

# 引数1個が「存在するディレクトリ」なら ROOT 扱い（タグ無し）
if [ "$#" -eq 1 ] && [ -d "${1}" ]; then
  ROOT="${1}"
else
  if [ "$#" -eq 0 ]; then
    ROOT="$PWD"
  elif [ "$#" -eq 1 ]; then
    ROOT="$PWD"
    TAG_ARGS+=("$1")
  else
    # 2個以上: 最後の引数を ROOT, それ以外をタグとみなす
    eval "ROOT=\${$#}"
    i=1
    last=$(( $# - 1 ))
    while [ "$i" -le "$last" ]; do
      eval "arg=\${$i}"

      if [ "$i" -eq 1 ] && [ "$#" -ge 3 ] && [ "${2-}" = "ignored" ]; then
        # 旧形式互換: "a b c" を空白分割してタグAND
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

TODAY="$(date '+%Y-%m-%d')"

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
# 対象 markdown 列挙（dashboards/ などは除外）
# ------------------------------------------------------------
find "${ROOT}" -type f -name '*.md' \
  ! -path "${OUTDIR}/*" \
  ! -path "${ROOT}/.foam/*" \
  ! -path "${ROOT}/.git/*" \
  ! -path "${ROOT}/.vscode/*" \
  ! -path "${ROOT}/node_modules/*" \
  > "${filelist}"

# ------------------------------------------------------------
# Stage1: frontmatter抽出 → tmp_nodes
# 出力TSV:
# id, parent, closed(0/1), due(YYYY-MM-DD or ""), pri(1-3), bd(0/1), gate(0/1),
# src(self/other), wgt(soft/hard), basename, tagOK(0/1)
# ------------------------------------------------------------
awk -v tag="${TAG}" '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

BEGIN{
  nTag = 0
  if (tag != "") nTag = split(tag, wantedTags, /[[:space:]]+/)
}

NR==FNR {
  file=$0
  gsub(/\r$/, "", file)
  if (file=="") next

  inFM=0; fmDone=0; nonHead=0

  idVal=""; parentVal=""
  hasDue=0; dueVal=""
  isClosed=0
  isBrainDump=0
  isGate=0
  priVal=3
  srcVal="self"
  wgtVal="soft"
  tagOK=(tag=="" ? 1 : 0)

  # basename
  n = split(file, parts, "/")
  b = parts[n]
  if (length(b) > 3 && substr(b, length(b)-2) == ".md") b = substr(b, 1, length(b)-3)
  basename=b

  while ((getline line < file) > 0) {
    sub(/\r$/, "", line)

    tmpLine=line
    gsub(/[ \t]/, "", tmpLine)
    if (fmDone==0 && inFM==0) {
      if (tmpLine != "" && line !~ /^[[:space:]]*---[[:space:]]*$/) nonHead=1
    }

    if (line ~ /^[[:space:]]*---[[:space:]]*$/) {
      if (inFM==0 && fmDone==0) { inFM=1; continue }
      else if (inFM==1 && fmDone==0) { inFM=0; fmDone=1; continue }
    }

    if (inFM==1) {
      low = tolower(line)
      copy = low; gsub(/[ \t]/, "", copy)

      # tags AND（tags行に全部含まれるかの簡易判定）
      if (tag != "" && low ~ /tags:/) {
        allOK=1
        for (ti=1; ti<=nTag; ti++) {
          t = wantedTags[ti]
          if (t=="") continue
          if (index(low, tolower(t)) == 0) { allOK=0; break }
        }
        if (allOK) tagOK=1
      }

      # BrainDump / gate-
      if (low ~ /tags:/ && low ~ /braindump/) isBrainDump=1
      if (low ~ /tags:/ && low ~ /gate-/)     isGate=1

      # id:
      if (low ~ /^[[:space:]]*id:[[:space:]]*/) {
        tmp=line
        sub(/^[[:space:]]*id:[[:space:]]*/, "", tmp)
        idVal=trim(tmp)
        gsub(/^["'\''`]+|["'\''`]+$/, "", idVal)
      }

      # parent:
      if (low ~ /^[[:space:]]*parent:[[:space:]]*/) {
        tmp=line
        sub(/^[[:space:]]*parent:[[:space:]]*/, "", tmp)
        parentVal=trim(tmp)
        gsub(/^["'\''`]+|["'\''`]+$/, "", parentVal)
      }

      # due:
      if (copy ~ /^due:/) {
        tmp=line
        sub(/^[[:space:]]*due:[[:space:]]*/, "", tmp)
        tmp=trim(tmp)
        if (tmp ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) {
          dueVal = substr(tmp, 1, 10)
          hasDue = 1
        }
      }

      # closed:
      if (copy ~ /^closed:/) isClosed=1

      # priority:
      if (low ~ /^[[:space:]]*priority:[[:space:]]*/) {
        tmp=line
        sub(/^[[:space:]]*priority:[[:space:]]*/, "", tmp)
        tmp=tolower(trim(tmp))
        sub(/^#/, "", tmp)
        tmp=trim(tmp)

        if (tmp ~ /^1/ || tmp ~ /^high/ || tmp ~ /^p1/) priVal=1
        else if (tmp ~ /^2/ || tmp ~ /^mid/ || tmp ~ /^medium/ || tmp ~ /^p2/) priVal=2
        else if (tmp ~ /^3/ || tmp ~ /^low/ || tmp ~ /^p3/) priVal=3
      }

      # due_source:
      if (low ~ /^[[:space:]]*due_source:[[:space:]]*/) {
        tmp=tolower(line)
        sub(/^[[:space:]]*due_source:[[:space:]]*/, "", tmp)
        tmp=trim(tmp)
        if (tmp ~ /^other/) srcVal="other"
        else srcVal="self"
      }

      # due_weight:
      if (low ~ /^[[:space:]]*due_weight:[[:space:]]*/) {
        tmp=tolower(line)
        sub(/^[[:space:]]*due_weight:[[:space:]]*/, "", tmp)
        tmp=trim(tmp)
        if (tmp ~ /^hard/) wgtVal="hard"
        else wgtVal="soft"
      }
    }
  }
  close(file)

  if (!fmDone || nonHead) next

  printf("%s\t%s\t%d\t%s\t%d\t%d\t%d\t%s\t%s\t%s\t%d\n",
         idVal, parentVal, isClosed, (hasDue?dueVal:""), priVal, isBrainDump, isGate,
         srcVal, wgtVal, basename, tagOK)
}' "${filelist}" > "${tmp_nodes}"

if [ "${DEBUG}" = "1" ]; then
  echo "[DBG] nodes lines: $(wc -l < "${tmp_nodes}" | tr -d " ")"
fi

# ------------------------------------------------------------
# Stage2: show集合（未クローズ + 祖先）を作り、並びキーを決める → tmp_show
# tmp_show TSV:
# idKey, parentKey, key(YYYY-MM-DD or 9999-99-99), openDesc, closed, due, pri, bd, gate, src, wgt, base, active
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
  base=$10
  tagOK=$11+0

  if (id=="") id="base:" base

  ids[++N]=id
  baseById[id]=base
  idByBase[base]=id

  rawParent[id]=parentRaw
  closedById[id]=closed
  dueById[id]=due
  priById[id]=pri
  bdById[id]=bd
  gateById[id]=gate
  srcById[id]=src
  wgtById[id]=wgt
  tagOKById[id]=tagOK
}

END{
  # parent解決
  for (i=1; i<=N; i++) {
    id=ids[i]
    p = norm_ref(rawParent[id])

    if (p=="" || p=="-") { parentOf[id]=ROOT; continue }

    if (p in baseById)        parentOf[id]=p
    else if (p in idByBase)   parentOf[id]=idByBase[p]
    else                      parentOf[id]=ROOT
  }

  # active = (tagOK && !closed)
  for (i=1; i<=N; i++) {
    id=ids[i]
    if (tagOKById[id]==1 && closedById[id]==0) active[id]=1
  }

  # show = active + 祖先
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

  # showノードの出力（TSV）
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
          "\t" wgtById[id] "\t" baseById[id] "\t" af
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
# Stage3: Markdown出力
# ------------------------------------------------------------
{
  echo "# Structure – 親子インデント（週次整理用）"
  echo
  echo "- 生成時刻: $(date '+%Y-%m-%d %H:%M')"
  if [ -z "${TAG}" ]; then
    echo "- 条件: 未クローズ（+祖先ノートを表示）"
  else
    echo "- 条件: tags に「${TAG}」すべてを含む未クローズ（+祖先ノートを表示）"
  fi
  echo "- 並び: 親ブロックは「配下の最短 due」で概ね前へ、子はその中で同様に並ぶ（完全な全体ソートはしない）"
  echo "- 記号: 🔴🟠🟢 priority / 🚧 gate / 🔥 BrainDump / 🤝 other / ⚠️ hard / ✅ closed / ⚠️✅＝閉じてるのに未完了の子がいる疑い"
  echo

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
    if (gate>0) s="🚧" s
    if (bd>0)   s="🔥" s
    return s
  }

  # showファイルを読む
  NR==FNR{
    id=$1; parent=$2; key=$3
    openDesc=$4+0
    closed=$5+0
    due=$6
    pri=$7+0
    bd=$8+0
    gate=$9+0
    src=$10
    wgt=$11
    base=$12
    active=$13+0

    parent=trim(parent)

    parentOf[id]=parent
    closedById[id]=closed
    dueById[id]=due
    priById[id]=pri
    bdById[id]=bd
    gateById[id]=gate
    srcById[id]=src
    wgtById[id]=wgt
    baseById[id]=base
    openDescById[id]=openDesc
    activeById[id]=active
    next
  }

  # edges（ソート済み）を読む：親ごとに子リストを作る
  {
    p=trim($1); id=$4
    if (children[p]=="") children[p]=id
    else children[p]=children[p] "\n" id
  }

  function print_node(id, depth,    line,mi,icon,title,mark){
    if (vis[id]) {
      print indent(depth) "- 🔁 [[" baseById[id] "]] (cycle?)"
      return
    }
    vis[id]=1

    mi = meta_icon(srcById[id], wgtById[id])
    icon = combo_icon(priById[id], gateById[id], bdById[id])

    if (closedById[id]==1) {
      mark = "✅"
      if (openDescById[id] > 0) mark = "⚠️✅"
      title = "~~[[" baseById[id] "]]~~"
    } else {
      mark = ""
      title = "[[" baseById[id] "]]"
    }

    if (dueById[id] != "") line = "- " dueById[id] " " icon
    else                   line = "- " icon

    if (mark != "") line = line " " mark
    if (mi != "")   line = line " " mi
    line = line " " title

    print indent(depth) line

    if (children[id] != "") {
      n = split(children[id], arr, "\n")
      for (i = 1; i <= n; i++) {
        cid = arr[i]
        if (cid=="") continue
        print_node(cid, depth+1)
      }
    }
  }

  END{
    if (children["ROOT"]=="") {
      print "> 該当なし"
      exit
    }
    print "## 🧭 ROOT"
    print ""
    n = split(children["ROOT"], arr, "\n")
    for (i = 1; i <= n; i++) {
      id = arr[i]
      if (id=="") continue
      print_node(id, 0)
      print ""
    }
  }
  ' "${tmp_show}" "${tmp_edges_sorted}"

} > "${OUT}"

echo "[INFO] Wrote ${OUT}"

# ------------------------------------------------------------
# 生成後にダッシュボードを開く（VS Code優先）
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
