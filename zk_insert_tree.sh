#!/usr/bin/env bash
# zk_insert_wikilink_tree.sh
#
# 目的:
# - 「今開いているノート」を起点に、本文中の [[wikilink]]（前向きリンク）を辿ってツリーを生成し、
#   そのツリーをノート内に挿入/更新する。
#
# 特徴:
# - id/parent に依存しない（崩れていてもOK）
# - rg 不要
# - Vaultルートは「開いているノートから上へ辿って .obsidian を探す」ことで自動検出
#   （見つからなければファイルのあるディレクトリをROOTとして扱う）
# - 循環参照は 🔁 (cycle) を表示してその枝の探索を中断
# - [[...]] 抽出は「コードブロック判定なし」版（``` の閉じ忘れでも吸い込まれない）
#
# 使い方:
#   ./zk_insert_wikilink_tree.sh <current.md>
#   オプション:
#     --root ROOT        ... ROOTを明示（自動検出より優先）
#     --max-depth N      ... 0=無制限（デフォルト）
#     --title "## Tree"  ... 見出し
#
# 診断:
#   DIAG=1 を付けると、各ノートの抽出リンク数だけを出す（ログ地獄になりにくい）
#     DIAG=1 ./zk_insert_wikilink_tree.sh xxx.md

set -Eeuo pipefail
trap 'ec=$?; echo "[ERR] exit=$ec line=$LINENO file=${BASH_SOURCE[0]} cmd=$BASH_COMMAND" >&2' ERR

# =========================
# Defaults (引数最小)
# =========================
MAX_DEPTH=0                      # 0 = 無制限
SECTION_TITLE="## Tree"
MARK_BEGIN="<!--TREE:BEGIN-->"
MARK_END="<!--TREE:END-->"
IGNORE_FILE=".dashboardignore"

usage() {
  cat >&2 <<'EOF'
usage: zk_insert_wikilink_tree.sh <current.md> [--root ROOT] [--max-depth N] [--title "## Tree"]

- current.md を起点に、本文中の [[wikilink]] を辿ってツリーを生成して挿入
- rg 不要
- Vault root は .obsidian を目印に自動検出（--root 指定があればそれを優先）
EOF
  exit 2
}

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

strip_md() { local p="$1"; printf '%s\n' "${p%.md}"; }

# =========================
# Vault root auto-detect (.obsidian)
# =========================
detect_vault_root() {
  local start="$1"
  local d
  d="$(cd "$(dirname "$start")" && pwd -P)"
  while :; do
    if [[ -d "$d/.obsidian" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
    if [[ "$d" == "/" ]]; then
      return 1
    fi
    d="$(cd "$d/.." && pwd -P)"
  done
}

# =========================
# Args
# =========================
TARGET_FILE="${1:-}"
[[ -z "$TARGET_FILE" ]] && usage
shift || true

ROOT=""  # 未指定なら後で自動検出

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
[[ -f "$TARGET_FILE" ]] || { echo "[ERR] File not found: $TARGET_FILE" >&2; exit 1; }

# ROOT を決定（指定があればそれ、無ければ自動検出）
if [[ -n "${ROOT}" ]]; then
  ROOT="$(abs_path "$ROOT")"
else
  if ROOT="$(detect_vault_root "$TARGET_FILE")"; then
    :
  else
    # 最後の保険：ノートと同じフォルダをROOTとして扱う
    ROOT="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
  fi
fi

rel_from_root() {
  local full
  full="$(abs_path "$1")"
  local r="${ROOT%/}/"
  printf '%s\n' "${full#"$r"}"
}

# =========================
# Ignore (ROOT/.dashboardignore + 主要フォルダ除外)
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
# Extract wikilinks
# - frontmatter(--- ---) は除外
# - コードブロック判定はしない（``` 閉じ忘れに強い）
# - ![[embed]] は除外
# - [[path|alias]] の alias は捨てる
# - [[note#heading]] の heading は捨てる
# =========================
extract_wikilinks() {
  local file="$1"
  awk '
    function push(x) { if (x != "" && !seen[x]++) print x }
    BEGIN{in_fm=0}
    NR==1 && $0=="---" {in_fm=1; next}
    in_fm==1 && $0=="---" {in_fm=0; next}
    in_fm { next }

    {
      line=$0
      while (match(line, /\[\[[^][]+\]\]/)) {
        s = substr(line, RSTART, RLENGTH)

        # embed ![[...]] は除外
        if (RSTART > 1 && substr(line, RSTART-1, 1) == "!") {
          line = substr(line, RSTART+RLENGTH)
          continue
        }

        inner = substr(s, 3, length(s)-4)

        p = index(inner, "|")
        if (p > 0) inner = substr(inner, 1, p-1)

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
# Resolve link -> file
# 優先順位:
# 1) [[path/to/note]] は ROOT 基準で解決
# 2) [[name]] は 同フォルダ
# 3) それでも無ければ ROOT からファイル名検索（最初に見つかったもの）
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

  # 1) path付きはROOT基準
  if [[ "$link" == */* ]]; then
    cand="$ROOT/$link"
    [[ "$cand" != *.md ]] && cand="${cand}.md"
    if [[ -f "$cand" ]]; then
      RESOLVE_CACHE["$key"]="$(abs_path "$cand")"
      printf '%s\n' "${RESOLVE_CACHE[$key]}"
      return 0
    fi
  fi

  # 2) 同フォルダ優先
  cand="$from_dir/$link"
  [[ "$cand" != *.md ]] && cand="${cand}.md"
  if [[ -f "$cand" ]]; then
    RESOLVE_CACHE["$key"]="$(abs_path "$cand")"
    printf '%s\n' "${RESOLVE_CACHE[$key]}"
    return 0
  fi

  # 3) ROOT全体から探索（必要な時だけ）
  local name="$link"
  [[ "$name" != *.md ]] && name="${name}.md"

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
declare -A file2wl   # absfile -> wikilink text (path/from/root without .md)
declare -A visited   # absfile -> 1

file_to_wikilink() {
  local f="$1"
  local rel
  rel="$(rel_from_root "$f")"
  rel="$(strip_md "$rel")"
  printf '%s\n' "$rel"
}

ROOT_ABS="$TARGET_FILE"
ROOT_WL="$(file_to_wikilink "$ROOT_ABS")"
file2wl["$ROOT_ABS"]="$ROOT_WL"

populate_children() {
  local f="$1"

  [[ -n "${visited[$f]+x}" ]] && return 0
  visited["$f"]=1

  local rel
  rel="$(rel_from_root "$f")"
  should_ignore "$rel" && return 0

  # diag: extracted link count only (quiet)
  if [[ "${DIAG:-0}" == "1" ]]; then
    local cnt
    cnt="$(extract_wikilinks "$f" | wc -l | tr -d " ")"
    echo "[DIAG] $(basename "$f") links=$cnt" >&2
  fi

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
    if [[ -z "${file2wl[$child]:-}" ]]; then
      file2wl["$child"]="$(file_to_wikilink "$child")"
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

declare -A onpath printed
desc_count=0

print_tree() {
  local f="$1" depth="$2"

  if (( MAX_DEPTH > 0 && depth > MAX_DEPTH )); then
    return 0
  fi

  local list="${children[$f]:-}"
  [[ -z "$list" ]] && return 0

  mapfile -t kids < <(
    printf '%s' "$list" |
      awk 'NF' | awk '!seen[$0]++' |
      while read -r c; do
        printf '%s\t%s\n' "${file2wl[$c]}" "$c"
      done | sort | awk -F'\t' '{print $2}'
  )

  local indent="" child
  for ((i=0;i<depth;i++)); do indent+="  "; done

  for child in "${kids[@]}"; do
    [[ -z "$child" ]] && continue

    if [[ -n "${onpath[$child]+x}" ]]; then
      printf '%s- [[%s]] 🔁 (cycle)\n' "$indent" "${file2wl[$child]}"
      continue
    fi
    if [[ -n "${printed[$child]+x}" ]]; then
      printf '%s- [[%s]] ↩︎ (already shown)\n' "$indent" "${file2wl[$child]}"
      continue
    fi

    printed["$child"]=1
    onpath["$child"]=1
    printf '%s- [[%s]]\n' "$indent" "${file2wl[$child]}"
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
