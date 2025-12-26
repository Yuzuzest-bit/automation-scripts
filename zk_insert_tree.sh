#!/usr/bin/env bash
set -euo pipefail

# =========================
# Defaults: 引数最小
# =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="${ZK_ROOT:-$SCRIPT_DIR}"   # ← Vaultルートは「スクリプトがあるフォルダ」
MAX_DEPTH=0                      # ← 0 = 無制限
SECTION_TITLE="## Tree"
MARK_BEGIN="<!--TREE:BEGIN-->"
MARK_END="<!--TREE:END-->"
IGNORE_FILE=".dashboardignore"

usage() {
  cat >&2 <<'EOF'
usage: zk_insert_wikilink_tree.sh <current.md> [--root ROOT] [--max-depth N] [--title "## Tree"]

- current.md を起点に、本文中の [[wikilink]] を辿って「前向きリンクのツリー」を生成して挿入
- 循環参照は 🔁 (cycle) を表示してその枝を中断
- rg 不要
EOF
  exit 2
}

TARGET_FILE="${1:-}"
[[ -z "$TARGET_FILE" ]] && usage
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2;;
    --max-depth) MAX_DEPTH="${2:-0}"; shift 2;;
    --title) SECTION_TITLE="${2:-## Tree}"; shift 2;;
    -h|--help) usage;;
    *) shift 1;;
  esac
done

# =========================
# Path helpers (Git Bash対応)
# =========================
to_posix() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
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

ROOT="$(abs_path "$ROOT")"
TARGET_FILE="$(abs_path "$TARGET_FILE")"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] File not found: $TARGET_FILE" >&2
  exit 1
fi

strip_md() { local p="$1"; printf '%s\n' "${p%.md}"; }

rel_from_root() {
  local full
  full="$(abs_path "$1")"
  local r="${ROOT%/}/"
  printf '%s\n' "${full#"$r"}"
}

# =========================
# Ignore
# =========================
should_ignore() {
  local rel="$1"
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
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      [[ "$rel" == *"$line"* ]] && return 0
    done < "$ig"
  fi
  return 1
}

# =========================
# Extract wikilinks from a file (frontmatter / code fence 除外)
# - [[file]]
# - [[path/to/file|alias]]
# - [[file#heading]] などは file 部分だけ使う
# - ![[embed]] は除外
# =========================
extract_wikilinks() {
  local file="$1"
  awk '
    function push(x) { if (x != "" && !seen[x]++) print x }
    BEGIN{in_fm=0; in_code=0}
    NR==1 && $0=="---" {in_fm=1; next}
    in_fm==1 && $0=="---" {in_fm=0; next}

    # code fence toggle (``` or ~~~)
    /^[[:space:]]*```/ { in_code = !in_code; next }
    /^[[:space:]]*~~~/ { in_code = !in_code; next }

    (in_fm||in_code) { next }

    {
      line=$0
      # find [[...]] repeatedly
      while (match(line, /\[\[[^][]+\]\]/)) {
        s = substr(line, RSTART, RLENGTH)
        # skip embed: if char before [[ is !
        if (RSTART > 1 && substr(line, RSTART-1, 1) == "!") {
          line = substr(line, RSTART+RLENGTH)
          continue
        }
        inner = substr(s, 3, length(s)-4)   # remove [[ ]]
        # drop alias after |
        p = index(inner, "|")
        if (p > 0) inner = substr(inner, 1, p-1)
        # drop heading/block after #
        p = index(inner, "#")
        if (p > 0) inner = substr(inner, 1, p-1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", inner)
        push(inner)
        line = substr(line, RSTART+RLENGTH)
      }
    }
  ' "$file"
}

# =========================
# Resolve a wikilink to a file
# - path/to/name  -> ROOT/path/to/name(.md)
# - name          -> まず同フォルダ、無ければ Vault 内を find（最初に見つかったもの）
# =========================
declare -A RESOLVE_CACHE  # key=fromDir|link -> absfile or ""

resolve_link() {
  local link="$1"
  local from_dir="$2"
  local key="${from_dir}|${link}"

  if [[ -n "${RESOLVE_CACHE[$key]+x}" ]]; then
    printf '%s\n' "${RESOLVE_CACHE[$key]}"
    return 0
  fi

  local cand=""

  # 1) link にスラッシュがあるなら ROOT 基準で解決
  if [[ "$link" == */* ]]; then
    cand="$ROOT/$link"
    [[ "$cand" != *.md ]] && cand="${cand}.md"
    if [[ -f "$cand" ]]; then
      RESOLVE_CACHE["$key"]="$cand"
      printf '%s\n' "$cand"
      return 0
    fi
  fi

  # 2) 同フォルダを最優先
  cand="$from_dir/$link"
  [[ "$cand" != *.md ]] && cand="${cand}.md"
  if [[ -f "$cand" ]]; then
    RESOLVE_CACHE["$key"]="$cand"
    printf '%s\n' "$cand"
    return 0
  fi

  # 3) Vault 内をファイル名で探索（重いが “必要なときだけ”）
  local name="$link"
  [[ "$name" != *.md ]] && name="${name}.md"

  # pruneで少し軽くする
  cand="$(find "$ROOT" \
      \( -path "$ROOT/.git" -o -path "$ROOT/.git/*" \
         -o -path "$ROOT/node_modules" -o -path "$ROOT/node_modules/*" \
         -o -path "$ROOT/.obsidian" -o -path "$ROOT/.obsidian/*" \
         -o -path "$ROOT/dashboards" -o -path "$ROOT/dashboards/*" \
         -o -path "$ROOT/templates" -o -path "$ROOT/templates/*" \
      \) -prune -o \
      -type f -name "$name" -print -quit 2>/dev/null || true)"

  if [[ -n "$cand" && -f "$cand" ]]; then
    RESOLVE_CACHE["$key"]="$(abs_path "$cand")"
    printf '%s\n' "${RESOLVE_CACHE[$key]}"
    return 0
  fi

  RESOLVE_CACHE["$key"]=""
  printf '%s\n' ""
}

# =========================
# Build subtree by outgoing links only
# =========================
declare -A children  # absfile -> list of absfile (newline)
declare -A file2link # absfile -> [[path/from/root without .md]]
declare -A visited   # absfile -> 1
declare -A onpath    # absfile -> 1

file_to_wikilink() {
  local f="$1"
  local rel
  rel="$(rel_from_root "$f")"
  rel="$(strip_md "$rel")"
  printf '%s\n' "$rel"
}

ROOT_ABS="$TARGET_FILE"
ROOT_WL="$(file_to_wikilink "$ROOT_ABS")"
file2link["$ROOT_ABS"]="$ROOT_WL"

# DFS: populate children lists lazily
populate_children() {
  local f="$1"

  [[ -n "${visited[$f]+x}" ]] && return 0
  visited["$f"]=1

  local rel
  rel="$(rel_from_root "$f")"
  should_ignore "$rel" && return 0

  local from_dir
  from_dir="$(dirname "$f")"

  while IFS= read -r lk; do
    [[ -z "$lk" ]] && continue
    local child
    child="$(resolve_link "$lk" "$from_dir")"
    [[ -z "$child" ]] && continue

    local child_rel
    child_rel="$(rel_from_root "$child")"
    should_ignore "$child_rel" && continue

    children["$f"]+="$child"$'\n'
    if [[ -z "${file2link[$child]:-}" ]]; then
      file2link["$child"]="$(file_to_wikilink "$child")"
    fi
    populate_children "$child"
  done < <(extract_wikilinks "$f")
}

populate_children "$ROOT_ABS"

# =========================
# Print tree with cycle stop
# =========================
TREE_MD="$(mktemp)"
OUT_TMP="$(mktemp)"
trap 'rm -f "$TREE_MD" "$OUT_TMP" 2>/dev/null || true' EXIT

declare -A printed
desc_count=0

print_tree() {
  local f="$1" depth="$2"

  if (( MAX_DEPTH > 0 && depth > MAX_DEPTH )); then
    return 0
  fi

  local list="${children[$f]:-}"
  [[ -z "$list" ]] && return 0

  # stable sort by wikilink
  mapfile -t kids < <(
    printf '%s' "$list" |
      awk 'NF' | awk '!seen[$0]++' |
      while read -r c; do
        printf '%s\t%s\n' "${file2link[$c]}" "$c"
      done | sort | awk -F'\t' '{print $2}'
  )

  local indent="" child
  for ((i=0;i<depth;i++)); do indent+="  "; done

  for child in "${kids[@]}"; do
    [[ -z "$child" ]] && continue

    if [[ -n "${onpath[$child]+x}" ]]; then
      printf '%s- [[%s]] 🔁 (cycle)\n' "$indent" "${file2link[$child]}"
      continue
    fi
    if [[ -n "${printed[$child]+x}" ]]; then
      printf '%s- [[%s]] ↩︎ (already shown)\n' "$indent" "${file2link[$child]}"
      continue
    fi

    printed["$child"]=1
    onpath["$child"]=1
    printf '%s- [[%s]]\n' "$indent" "${file2link[$child]}"
    ((desc_count++))
    print_tree "$child" $((depth+1))
    unset onpath["$child"]
  done
}

{
  echo "- **[[${ROOT_WL}]]**"
  printed["$ROOT_ABS"]=1
  onpath["$ROOT_ABS"]=1
  print_tree "$ROOT_ABS" 1
  unset onpath["$ROOT_ABS"]
  echo ""
  echo "> descendants: $desc_count"
} > "$TREE_MD"

# =========================
# Insert / Replace block
# =========================
if grep -qF "$MARK_BEGIN" "$TARGET_FILE" && grep -qF "$MARK_END" "$TARGET_FILE"; then
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v tf="$TREE_MD" '
    function dump_tree(   l) { while ((getline l < tf) > 0) print l; close(tf) }
    BEGIN{inblk=0}
    index($0,b)>0 { print; inblk=1; dump_tree(); next }
    index($0,e)>0 { inblk=0; print; next }
    inblk==1 { next }
    { print }
  ' "$TARGET_FILE" > "$OUT_TMP"
else
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
echo "[OK] Wikilink Tree updated: $TARGET_FILE"
