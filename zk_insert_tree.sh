#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Defaults
# --------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="${ZK_ROOT:-$SCRIPT_DIR}"   # ← デフォルトは「このスクリプトがあるフォルダ」
MAX_DEPTH=0                      # ← 0 = 無制限
SECTION_TITLE="## Tree"
MARK_BEGIN="<!--TREE:BEGIN-->"
MARK_END="<!--TREE:END-->"
IGNORE_FILE=".dashboardignore"

usage() {
  cat >&2 <<'EOF'
usage: zk_insert_tree.sh <current.md> [options]

options:
  --root ROOT          (default: script folder)
  --max-depth N        (default: unlimited; 0 means unlimited)
  --title "## Tree"    (default: ## Tree)

notes:
- current.md を起点に parent: を辿って「そのサブツリーだけ」出力
- 循環参照は "🔁 (cycle)" と表示してその枝の探索を中断
- ripgrep (rg) が必要
EOF
  exit 2
}

# --------------------------------------------
# Helpers (path)
# --------------------------------------------
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

strip_md() {
  local p="$1"
  p="${p%.md}"
  printf '%s\n' "$p"
}

rel_from_root() {
  local full="$1"
  full="$(abs_path "$full")"
  local r
  r="$(abs_path "$ROOT")"
  r="${r%/}/"
  full="${full#"$r"}"
  printf '%s\n' "$full"
}

# --------------------------------------------
# Parse args
# --------------------------------------------
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

TARGET_FILE="$(abs_path "$TARGET_FILE")"
ROOT="$(abs_path "$ROOT")"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] File not found: $TARGET_FILE" >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "[ERR] rg (ripgrep) not found. This fast subtree mode requires rg." >&2
  exit 2
fi

# --------------------------------------------
# Frontmatter read
# --------------------------------------------
extract_frontmatter() {
  local file="$1"
  awk '
    BEGIN{in_fm=0; id=""; parent=""}
    NR==1 && $0=="---" {in_fm=1; next}
    in_fm==1 && $0=="---" {in_fm=0; exit}
    in_fm==1 {
      if ($0 ~ /^id:[[:space:]]*/) {
        sub(/^id:[[:space:]]*/, "", $0); id=$0
      }
      if ($0 ~ /^parent:[[:space:]]*/) {
        sub(/^parent:[[:space:]]*/, "", $0); parent=$0
      }
    }
    END{ printf("%s\t%s\n", id, parent) }
  ' "$file"
}

# --------------------------------------------
# Ignore
# --------------------------------------------
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

# --------------------------------------------
# ripgrep regex escape (Rust regex)
# --------------------------------------------
re_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\./\\\.}"
  s="${s//\*/\\\*}"
  s="${s//\+/\\\+}"
  s="${s//\?/\\\?}"
  s="${s//\^/\\\^}"
  s="${s//\$/\\\$}"
  s="${s//\{/\\\{}"
  s="${s//\}/\\\}}"
  s="${s//\(/\\\(}"
  s="${s//\)/\\\)}"
  s="${s//\[/\\\[}"
  s="${s//\]/\\\]}"
  s="${s//\|/\\\|}"
  printf '%s\n' "$s"
}

make_keys() {
  local id="$1" base="$2" link="$3"
  local out=()
  [[ -n "$id" ]] && out+=("$id" "[[$id]]")
  [[ -n "$base" ]] && out+=("$base" "[[$base]]")
  [[ -n "$link" ]] && out+=("$link" "[[$link]]" "$link.md" "[[$link.md]]")
  printf '%s\n' "${out[@]}" | awk 'NF' | awk '!seen[$0]++'
}

# --------------------------------------------
# Root node info
# --------------------------------------------
ROOT_REL="$(rel_from_root "$TARGET_FILE")"
ROOT_LINK="$(strip_md "$ROOT_REL")"
ROOT_BASE="$(basename "$TARGET_FILE")"; ROOT_BASE="${ROOT_BASE%.md}"
fm="$(extract_frontmatter "$TARGET_FILE")"
ROOT_ID="${fm%%$'\t'*}"
[[ -z "$ROOT_ID" ]] && ROOT_ID="$ROOT_BASE"
ROOT_CANON="$ROOT_ID"  # canonは id 優先

# --------------------------------------------
# Discovery structures (subtree only)
# --------------------------------------------
declare -A alias2canon canon2link canon2base canon2id canon2file canon2keys
declare -A children discovered enqueued

register_node() {
  local canon="$1" id="$2" base="$3" link="$4" file="$5"
  canon2id["$canon"]="$id"
  canon2base["$canon"]="$base"
  canon2link["$canon"]="$link"
  canon2file["$canon"]="$file"

  local keys
  keys="$(make_keys "$id" "$base" "$link")"
  canon2keys["$canon"]="$keys"

  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    alias2canon["$k"]="$canon"
  done <<< "$keys"
}

register_node "$ROOT_CANON" "$ROOT_ID" "$ROOT_BASE" "$ROOT_LINK" "$TARGET_FILE"

find_children_files_for_canon() {
  local canon="$1"
  local keys="${canon2keys[$canon]:-}"
  [[ -z "$keys" ]] && return 0

  local alt="" k_esc
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    k_esc="$(re_escape "$k")"
    if [[ -z "$alt" ]]; then alt="$k_esc"; else alt="$alt|$k_esc"; fi
  done <<< "$keys"
  [[ -z "$alt" ]] && return 0

  local pattern="^parent:[[:space:]]*['\"]?(${alt})['\"]?[[:space:]]*$"

  rg -l --no-messages \
     --glob='!.git/**' --glob='!node_modules/**' --glob='!.obsidian/**' \
     --glob='!dashboards/**' --glob='!templates/**' \
     "$pattern" "$ROOT" || true
}

queue=("$ROOT_CANON")
enqueued["$ROOT_CANON"]=1

while ((${#queue[@]} > 0)); do
  parent_canon="${queue[0]}"
  queue=("${queue[@]:1}")

  [[ -n "${discovered[$parent_canon]+x}" ]] && continue
  discovered["$parent_canon"]=1

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    f="$(abs_path "$f")"
    rel="$(rel_from_root "$f")"
    should_ignore "$rel" && continue

    fm="$(extract_frontmatter "$f")"
    cid="${fm%%$'\t'*}"
    cparent_raw="${fm#*$'\t'}"

    cbase="$(basename "$f")"; cbase="${cbase%.md}"
    clink="$(strip_md "$rel")"
    ccanon="$cid"; [[ -z "$ccanon" ]] && ccanon="$clink"

    pcanon="${alias2canon[$cparent_raw]:-}"
    if [[ -z "$pcanon" ]]; then
      # クォート付き等の軽い揺れ対応
      pcanon="${alias2canon[${cparent_raw%\"}]:-}"
      pcanon="${pcanon:-${alias2canon[${cparent_raw#\"}]:-}}"
    fi
    [[ -z "$pcanon" ]] && continue

    if [[ -z "${canon2link[$ccanon]:-}" ]]; then
      register_node "$ccanon" "$cid" "$cbase" "$clink" "$f"
    fi

    children["$pcanon"]+="${ccanon}"$'\n'

    if [[ -z "${enqueued[$ccanon]+x}" ]]; then
      queue+=("$ccanon")
      enqueued["$ccanon"]=1
    fi
  done < <(find_children_files_for_canon "$parent_canon")
done

# --------------------------------------------
# Print tree (cycle detect)
# --------------------------------------------
TREE_MD="$(mktemp)"
OUT_TMP="$(mktemp)"
trap 'rm -f "$TREE_MD" "$OUT_TMP" 2>/dev/null || true' EXIT

declare -A onpath printed
desc_count=0

print_tree() {
  local canon="$1" depth="$2"

  if (( MAX_DEPTH > 0 && depth > MAX_DEPTH )); then
    return
  fi

  local list="${children[$canon]:-}"
  [[ -z "$list" ]] && return

  mapfile -t kids < <(
    printf '%s' "$list" |
      awk 'NF' | awk '!seen[$0]++' |
      while read -r c; do
        printf '%s\t%s\n' "${canon2link[$c]:-}" "$c"
      done | sort | awk -F'\t' '{print $2}'
  )

  local indent="" child
  for ((i=0;i<depth;i++)); do indent+="  "; done

  for child in "${kids[@]}"; do
    [[ -z "$child" ]] && continue

    if [[ -n "${onpath[$child]+x}" ]]; then
      printf '%s- [[%s]] 🔁 (cycle)\n' "$indent" "${canon2link[$child]}"
      continue
    fi

    if [[ -n "${printed[$child]+x}" ]]; then
      printf '%s- [[%s]] ↩︎ (already shown)\n' "$indent" "${canon2link[$child]}"
      continue
    fi

    printed["$child"]=1
    onpath["$child"]=1
    printf '%s- [[%s]]\n' "$indent" "${canon2link[$child]}"
    ((desc_count++))
    print_tree "$child" $((depth+1))
    unset onpath["$child"]
  done
}

{
  echo "- **[[${canon2link[$ROOT_CANON]}]]**"
  printed["$ROOT_CANON"]=1
  onpath["$ROOT_CANON"]=1
  print_tree "$ROOT_CANON" 1
  unset onpath["$ROOT_CANON"]
  echo ""
  echo "> descendants: $desc_count"
} > "$TREE_MD"

# --------------------------------------------
# Insert/replace in note
# --------------------------------------------
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
echo "[OK] Tree updated (subtree only): $TARGET_FILE"
