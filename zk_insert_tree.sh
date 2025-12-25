#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="${1:-}"
ROOT="${ZK_ROOT:-$PWD}"
MAX_DEPTH=20
SECTION_TITLE="## Tree"
MARK_BEGIN="<!--TREE:BEGIN-->"
MARK_END="<!--TREE:END-->"
IGNORE_FILE=".dashboardignore"

usage() {
  cat >&2 <<'EOF'
usage: zk_insert_tree.sh <current.md> [--root ROOT] [--max-depth N] [--title "## Tree"]
- TARGET_FILE: VS Code の ${file} を想定
- 子ノートは frontmatter の parent: で親を指す（id推奨 / ファイル名でも可）
EOF
  exit 2
}

to_posix() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    # Windows(Git Bash) っぽいときだけ変換
    if [[ "$p" =~ ^[A-Za-z]:[\\/]|\\ ]]; then
      cygpath -u "$p"
      return
    fi
  fi
  printf '%s\n' "$p"
}

abs_path() {
  local p
  p="$(to_posix "$1")"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
  else
    local d b
    d="$(dirname "$p")"
    b="$(basename "$p")"
    (cd "$d" && printf '%s/%s\n' "$(pwd -P)" "$b")
  fi
}

# ---- args ----
[[ -z "$TARGET_FILE" ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2;;
    --max-depth) MAX_DEPTH="${2:-20}"; shift 2;;
    --title) SECTION_TITLE="${2:-## Tree}"; shift 2;;
    -h|--help) usage;;
    *) shift 1;;
  esac
done

TARGET_FILE="$(abs_path "$TARGET_FILE")"
ROOT="$(abs_path "$ROOT")"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] File not found: $TARGET_FILE" >&2
  exit 1
fi

# root からの相対パス（wikiリンク用）
rel_from_root() {
  local full="$1"
  full="$(abs_path "$full")"
  local r="$ROOT"
  # 末尾 / を揃える
  r="${r%/}/"
  full="${full#"$r"}"
  printf '%s\n' "$full"
}

strip_md() {
  local p="$1"
  p="${p%.md}"
  printf '%s\n' "$p"
}

# frontmatterから id/parent を拾う（先頭の --- ... --- の間だけ）
extract_frontmatter() {
  local file="$1"
  awk '
    BEGIN{in=0; id=""; parent=""; seen=0}
    NR==1 && $0=="---" {in=1; next}
    in==1 && $0=="---" {in=0; seen=1; exit}
    in==1 {
      if ($0 ~ /^id:[[:space:]]*/) {
        sub(/^id:[[:space:]]*/, "", $0); id=$0
      }
      if ($0 ~ /^parent:[[:space:]]*/) {
        sub(/^parent:[[:space:]]*/, "", $0); parent=$0
      }
    }
    END{
      # 出力: id \t parent
      printf("%s\t%s\n", id, parent)
    }
  ' "$file"
}

# ignore判定（.dashboardignore の「部分一致」でも弾く：雑だが運用が楽）
should_ignore() {
  local rel="$1"

  # よくある除外
  case "$rel" in
    .git/*|**/.git/*) return 0;;
    node_modules/*|**/node_modules/*) return 0;;
    .obsidian/*|**/.obsidian/*) return 0;;
    dashboards/*|**/dashboards/*) return 0;;
    templates/*|**/templates/*) return 0;;
  esac

  local ig="$ROOT/$IGNORE_FILE"
  if [[ -f "$ig" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"             # コメント除去
      line="${line#"${line%%[![:space:]]*}"}" # trim left
      line="${line%"${line##*[![:space:]]}"}" # trim right
      [[ -z "$line" ]] && continue
      # 行が含まれていたら除外（ディレクトリ名でもファイルでもOK）
      if [[ "$rel" == *"$line"* ]]; then
        return 0
      fi
    done < "$ig"
  fi

  return 1
}

ROOT_REL="$(rel_from_root "$TARGET_FILE")"
ROOT_LINK="$(strip_md "$ROOT_REL")"

fm="$(extract_frontmatter "$TARGET_FILE")"
ROOT_ID="${fm%%$'\t'*}"
ROOT_BASE="$(basename "$TARGET_FILE")"
ROOT_BASE="${ROOT_BASE%.md}"

if [[ -z "$ROOT_ID" ]]; then
  # idが無い運用もあり得るのでフォールバック
  ROOT_ID="$ROOT_BASE"
fi

# ---- 全ノートを走査して、(canon, aliases, parent, link) をTSVにする ----
MAP_TSV="$(mktemp)"
trap 'rm -f "$MAP_TSV" "$TREE_MD" "$OUT_TMP" 2>/dev/null || true' EXIT

# TSV列:
# canon   parent_raw   link(path without .md)   basename   id
while IFS= read -r -d '' f; do
  rel="$(rel_from_root "$f")"
  should_ignore "$rel" && continue

  fm="$(extract_frontmatter "$f")"
  id="${fm%%$'\t'*}"
  parent="${fm#*$'\t'}"

  base="$(basename "$f")"
  base="${base%.md}"
  link="$(strip_md "$rel")"

  canon="$id"
  [[ -z "$canon" ]] && canon="$link"  # idが無いなら path をcanonに

  printf '%s\t%s\t%s\t%s\t%s\n' "$canon" "$parent" "$link" "$base" "$id" >> "$MAP_TSV"
done < <(find "$ROOT" -type f -name '*.md' -print0)

# ---- ツリー生成（awkで2パス：alias→canon解決してから children を組む） ----
TREE_MD="$(mktemp)"

awk -v rootCanon="$ROOT_ID" -v rootBase="$ROOT_BASE" -v rootLink="$ROOT_LINK" -v maxDepth="$MAX_DEPTH" '
BEGIN {
  FS="\t"
}
{
  canon=$1; parent=$2; link=$3; base=$4; id=$5

  # alias -> canon を登録（id / basename / link(path) を全部alias扱い）
  if (id != "") alias2canon[id]=canon
  if (base != "") alias2canon[base]=canon
  if (link != "") alias2canon[link]=canon

  # canon情報
  canon2link[canon]=link
  canon2base[canon]=base
  canon2id[canon]=id

  # 後で2パスするため保持
  lines[++n]= $0
}
END {
  # root を alias 解決（id優先だが、無ければ basename / link でも拾えるようにする）
  root = rootCanon
  if (!(root in canon2link) && (rootCanon in alias2canon)) root = alias2canon[rootCanon]
  if (!(root in canon2link) && (rootBase in alias2canon)) root = alias2canon[rootBase]
  if (!(root in canon2link) && (rootLink in alias2canon)) root = alias2canon[rootLink]

  # 2パス目：children を作る
  for (i=1; i<=n; i++) {
    split(lines[i], a, "\t")
    canon=a[1]; parent=a[2]
    if (parent=="" || parent=="-") continue

    p = parent
    if (p in alias2canon) p = alias2canon[p]
    children[p] = children[p] canon "\n"
  }

  # 出力
  print "- **[[" canon2link[root] "]]**"

  visited[root]=1
  total = print_tree(root, 1)

  print ""
  print "> descendants: " total
}

function print_tree(node, depth,   list, j, child, cnt, arrn, k, key) {
  if (depth > maxDepth) return 0

  list = children[node]
  if (list == "") return 0

  # 子をソートっぽく安定させる（linkで重複しづらい）
  arrn = split(list, tmp, "\n")
  # tmp[1..arrn] のうち空を除去しつつ、簡易ソート（O(n^2)だが数が少ない前提）
  m=0
  for (j=1; j<=arrn; j++) if (tmp[j]!="") arr[++m]=tmp[j]
  for (j=1; j<=m; j++) {
    for (k=j+1; k<=m; k++) {
      if (canon2link[arr[j]] > canon2link[arr[k]]) {
        t=arr[j]; arr[j]=arr[k]; arr[k]=t
      }
    }
  }

  cnt=0
  for (j=1; j<=m; j++) {
    child = arr[j]
    if (child=="") continue
    if (visited[child]) continue
    visited[child]=1

    indent = ""
    for (k=0; k<depth; k++) indent = indent "  "

    print indent "- [[" canon2link[child] "]]"
    cnt += 1
    cnt += print_tree(child, depth+1)
  }
  return cnt
}
' "$MAP_TSV" > "$TREE_MD"

# ---- ノートへ挿入（マーカーがあれば置換、無ければ末尾に追記） ----
OUT_TMP="$(mktemp)"

if grep -qF "$MARK_BEGIN" "$TARGET_FILE" && grep -qF "$MARK_END" "$TARGET_FILE"; then
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v tf="$TREE_MD" '
    function dump_tree(   l) {
      while ((getline l < tf) > 0) print l
      close(tf)
    }
    BEGIN{inblk=0}
    index($0,b)>0 { print; inblk=1; dump_tree(); next }
    index($0,e)>0 { inblk=0; print; next }
    inblk==1 { next }
    { print }
  ' "$TARGET_FILE" > "$OUT_TMP"
else
  # frontmatter直下を避けつつ、末尾にセクション追加
  {
    cat "$TARGET_FILE"
    echo ""
    echo "$SECTION_TITLE"
    echo "$MARK_BEGIN"
    cat "$TREE_MD"
    echo "$MARK_END"
    echo ""
  } > "$OUT_TMP"
fi

mv "$OUT_TMP" "$TARGET_FILE"
echo "[OK] Tree updated: $TARGET_FILE"
