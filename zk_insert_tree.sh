#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Defaults (なるべく引数なしで動く)
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="${ZK_ROOT:-$SCRIPT_DIR}"      # ← デフォルトは「このスクリプトがあるフォルダ」
MAX_DEPTH=0                         # ← 0 = 無制限
SECTION_TITLE="## Tree"
MARK_BEGIN="<!--TREE:BEGIN-->"
MARK_END="<!--TREE:END-->"
IGNORE_FILE=".dashboardignore"

CACHE_DIR="$ROOT/.zk_cache"
CACHE_INDEX="$CACHE_DIR/parent_index.tsv"
CACHE_STAMP="$CACHE_DIR/parent_index.stamp"

usage() {
  cat >&2 <<'EOF'
usage: zk_insert_tree.sh <current.md> [--root ROOT] [--max-depth N] [--title "## Tree"]

defaults:
  --root      = script folder
  --max-depth = unlimited (0)
EOF
  exit 2
}

# ============================================================
# Args
# ============================================================
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

# ============================================================
# Path helpers (Git Bash / Windows対応)
# ============================================================
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

# ============================================================
# Frontmatter reader (先頭の --- --- の中だけ読む)
# ============================================================
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

# ============================================================
# Ignore
# ============================================================
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

# ============================================================
# Index (cache) builder / updater
# index columns:
#   file_abs \t canon \t parent_raw \t link \t base \t id
# ============================================================
ensure_cache_dir() {
  mkdir -p "$CACHE_DIR"
}

emit_index_line_for_file() {
  local f="$1"
  local rel base link id parent canon fm
  rel="$(rel_from_root "$f")"
  should_ignore "$rel" && return 0

  base="$(basename "$f")"; base="${base%.md}"
  link="$(strip_md "$rel")"

  fm="$(extract_frontmatter "$f")"
  id="${fm%%$'\t'*}"
  parent="${fm#*$'\t'}"

  canon="$id"
  [[ -z "$canon" ]] && canon="$link"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$canon" "$parent" "$link" "$base" "$id"
}

build_index_full() {
  ensure_cache_dir
  local tmp
  tmp="$(mktemp)"

  # 主要ディレクトリは prune して I/O を減らす
  while IFS= read -r -d '' f; do
    emit_index_line_for_file "$f" >> "$tmp"
  done < <(
    find "$ROOT" \
      \( -path "$ROOT/.git" -o -path "$ROOT/.git/*" \
         -o -path "$ROOT/node_modules" -o -path "$ROOT/node_modules/*" \
         -o -path "$ROOT/.obsidian" -o -path "$ROOT/.obsidian/*" \
         -o -path "$ROOT/dashboards" -o -path "$ROOT/dashboards/*" \
         -o -path "$ROOT/templates" -o -path "$ROOT/templates/*" \
      \) -prune -o \
      -type f -name '*.md' -print0
  )

  mv "$tmp" "$CACHE_INDEX"
  : > "$CACHE_STAMP"
}

update_index_incremental() {
  ensure_cache_dir
  [[ -f "$CACHE_INDEX" ]] || build_index_full

  # stamp が無ければ全作成
  [[ -f "$CACHE_STAMP" ]] || { build_index_full; return; }

  local tmp_add tmp_compact
  tmp_add="$(mktemp)"
  tmp_compact="$(mktemp)"

  # 変更分だけ拾って追記（削除は一旦放置。tree生成時に実ファイル無いものは自然に落ちる）
  while IFS= read -r -d '' f; do
    emit_index_line_for_file "$f" >> "$tmp_add"
  done < <(
    find "$ROOT" \
      \( -path "$ROOT/.git" -o -path "$ROOT/.git/*" \
         -o -path "$ROOT/node_modules" -o -path "$ROOT/node_modules/*" \
         -o -path "$ROOT/.obsidian" -o -path "$ROOT/.obsidian/*" \
         -o -path "$ROOT/dashboards" -o -path "$ROOT/dashboards/*" \
         -o -path "$ROOT/templates" -o -path "$ROOT/templates/*" \
      \) -prune -o \
      -type f -name '*.md' -newer "$CACHE_STAMP" -print0
  )

  # 旧index + 追記 を「同一file_absは最新行を採用」して圧縮
  cat "$CACHE_INDEX" "$tmp_add" | awk -F'\t' '
    {
      file=$1
      rec[file]=$0    # 同じfileは後勝ち
    }
    END{
      for (k in rec) print rec[k]
    }
  ' > "$tmp_compact"

  mv "$tmp_compact" "$CACHE_INDEX"
  : > "$CACHE_STAMP"
  rm -f "$tmp_add" 2>/dev/null || true
}

# ============================================================
# Tree generation (subtree only, cycle stop)
# ============================================================
# ルートノート情報
ROOT_REL="$(rel_from_root "$TARGET_FILE")"
ROOT_LINK="$(strip_md "$ROOT_REL")"
ROOT_BASE="$(basename "$TARGET_FILE")"; ROOT_BASE="${ROOT_BASE%.md}"
fm_root="$(extract_frontmatter "$TARGET_FILE")"
ROOT_ID="${fm_root%%$'\t'*}"
[[ -z "$ROOT_ID" ]] && ROOT_ID="$ROOT_BASE"

# インデックス更新（初回は重い、以降は差分のみ）
update_index_incremental

# maps
declare -A alias2canon canon2link canon2base canon2id canon2file children

register_aliases() {
  local canon="$1" id="$2" base="$3" link="$4"
  [[ -n "$id" ]]   && alias2canon["$id"]="$canon"   && alias2canon["[[$id]]"]="$canon"
  [[ -n "$base" ]] && alias2canon["$base"]="$canon" && alias2canon["[[$base]]"]="$canon"
  if [[ -n "$link" ]]; then
    alias2canon["$link"]="$canon"
    alias2canon["[[$link]]"]="$canon"
    alias2canon["$link.md"]="$canon"
    alias2canon["[[$link.md]]"]="$canon"
  fi
}

# 1) すべてのノード情報を登録（alias2canonを作る）
while IFS=$'\t' read -r file canon parent_raw link base id; do
  # file が消えてても index には残るので、無ければスキップ
  [[ -f "$file" ]] || continue
  canon2file["$canon"]="$file"
  canon2link["$canon"]="$link"
  canon2base["$canon"]="$base"
  canon2id["$canon"]="$id"
  register_aliases "$canon" "$id" "$base" "$link"
done < "$CACHE_INDEX"

# 2) children を組む
while IFS=$'\t' read -r file canon parent_raw link base id; do
  [[ -f "$file" ]] || continue
  [[ -z "$parent_raw" || "$parent_raw" == "-" ]] && continue

  pcanon="${alias2canon[$parent_raw]:-}"

  # 軽い揺れ（クォート等）
  if [[ -z "$pcanon" ]]; then
    parent2="${parent_raw%\"}"; parent2="${parent2#\"}"
    pcanon="${alias2canon[$parent2]:-}"
  fi

  [[ -z "$pcanon" ]] && continue
  children["$pcanon"]+="${canon}"$'\n'
done < "$CACHE_INDEX"

# root canon を解決（id優先 → base → link）
ROOT_CANON="${alias2canon[$ROOT_ID]:-}"
[[ -z "$ROOT_CANON" ]] && ROOT_CANON="${alias2canon[$ROOT_BASE]:-}"
[[ -z "$ROOT_CANON" ]] && ROOT_CANON="${alias2canon[$ROOT_LINK]:-}"
# それでも無ければ id を canon とみなす（最低限のフォールバック）
[[ -z "$ROOT_CANON" ]] && ROOT_CANON="$ROOT_ID"

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

  # 子を link でソート（安定表示）
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
    [[ -n "${canon2link[$child]:-}" ]] || continue

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
  # ルートが index に無い/リンク不明でも落ちないように
  root_link="${canon2link[$ROOT_CANON]:-$ROOT_LINK}"
  echo "- **[[${root_link}]]**"
  printed["$ROOT_CANON"]=1
  onpath["$ROOT_CANON"]=1
  print_tree "$ROOT_CANON" 1
  unset onpath["$ROOT_CANON"]
  echo ""
  echo "> descendants: $desc_count"
} > "$TREE_MD"

# ============================================================
# Insert / Replace block
# ============================================================
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
echo "[OK] Tree updated: $TARGET_FILE"
