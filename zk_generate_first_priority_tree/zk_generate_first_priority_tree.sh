#!/usr/bin/env bash
# zk_generate_first_priority_tree.sh
#
# Windows (Git Bash) 最適化版:
# - UTF-8エンコーディングの明示
# - Windowsのパス形式とCRLFへの耐性強化

# 文字化け防止（絵文字を正しく扱うため）
export LC_ALL=C.UTF-8

set -Eeuo pipefail

# --- 設定 ---
MAX_DEPTH=0
OUTDIR_NAME="dashboards"
FIXED_FILENAME="TREE_VIEW.md"

# アイコン定義
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "
ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "
ICON_BLOCK="🧱 "
ICON_CYCLE="🔁 (infinite loop) "
ICON_ALREADY="🔗 (already shown) "

usage() {
  echo "usage: $0 <source_note.md>" >&2
  exit 2
}

# パス解決の修正（Windowsの絶対パスをGit Bash形式に統一）
TARGET_FILE="${1:-}"
[[ -z "$TARGET_FILE" ]] && usage

# 実体のパスを取得
if [[ "$TARGET_FILE" == /* ]]; then
    # すでにPOSIX形式（/c/...）の場合
    TARGET_FILE="$(cd "$(dirname "$TARGET_FILE")" && pwd)/$(basename "$TARGET_FILE")"
else
    # Windows形式のパスが渡された場合に対応
    TARGET_FILE="$(cd "$(dirname "$TARGET_FILE")" && pwd)/$(basename "$TARGET_FILE")"
fi
ROOT="$(pwd)"

OUTDIR="${ROOT}/${OUTDIR_NAME}"
mkdir -p "$OUTDIR"
OUTPUT_FILE="${OUTDIR}/${FIXED_FILENAME}"

# --- 1. IDインデックスの作成 ---
declare -A ID_MAP
echo "Scanning Vault..."
# .git や .vscode などを除外して高速化
while read -r f; do
  fid=$(awk '/^id:[[:space:]]*/ { sub(/^id:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$f")
  if [[ -n "$fid" ]]; then ID_MAP["$fid"]="$f"; fi
  fname=$(basename "${f%.md}")
  if [[ -z "${ID_MAP[$fname]:-}" ]]; then ID_MAP["$fname"]="$f"; fi
done < <(find "$ROOT" -maxdepth 4 -name "*.md" -not -path "*/.*")

# --- 2. 状態取得関数（WindowsのCRLF改行に対応） ---
get_status_details() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && { echo "$ICON_ERROR|"; return; }

  local icons=""
  local extra_info=""

  # Closed判定 (改行コード \r を除去して判定)
  if head -n 30 "$f_path" | tr -d '\r' | grep -qE '^closed:[[:space:]]*.+'; then
    icons+="$ICON_CLOSED"
  else
    icons+="$ICON_OPEN"
  fi

  # 最初に見つかったマーカーを取得
  local first_match
  first_match=$(grep -niE '@focus|@awaiting|@blocked' "$f_path" | tr -d '\r' | sort -t: -k1,1n | head -n 1 || true)

  if [[ -n "$first_match" ]]; then
    local line_content
    line_content=$(echo "$first_match" | cut -d: -f2-)
    local lower_content
    lower_content=$(echo "$line_content" | tr '[:upper:]' '[:lower:]')

    if [[ "$lower_content" == *"@focus"* ]]; then
      icons+="$ICON_FOCUS"
    elif [[ "$lower_content" == *"@blocked"* ]]; then
      icons+="$ICON_BLOCK"
      local info
      info=$(echo "$line_content" | sed -n 's/.*@blocked[[:space:]]*\(.*\)/\1/p')
      [[ -n "$info" ]] && extra_info=" (🧱 $info)"
    elif [[ "$lower_content" == *"@awaiting"* ]]; then
      icons+="$ICON_AWAIT"
      local info
      info=$(echo "$line_content" | sed -n 's/.*@awaiting[[:space:]]*\(.*\)/\1/p')
      [[ -n "$info" ]] && extra_info=" (⏳ $info)"
    fi
  fi
  echo "${icons}|${extra_info}"
}

# --- 3. リンク抽出関数 (CRLF対応済み) ---
extract_wikilinks() {
  awk '
    function strip_bom(s){ sub(/^\357\273\277/, "", s); return s }
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN{in_fm=0; in_code_block=0; first=0}
    {
      line=$0; sub(/\r$/, "", line); line=strip_bom(line); t=trim(line)
      if(!first){ if(t=="")next; first=1; if(t=="---"){in_fm=1;next}}
      if(in_fm){ if(t=="---"){in_fm=0}; next}
      if(t ~ /^```/ || t ~ /^~~~/){ in_code_block = !in_code_block; next }
      if(in_code_block) next
      gsub(/`[^`]+`/, "", line)
      while(match(line, /\[\[[^][]+\]\]/)){
        s=substr(line, RSTART+2, RLENGTH-4)
        p=index(s,"|"); if(p>0) s=substr(s,1,p-1)
        p=index(s,"#"); if(p>0) s=substr(s,1,p-1)
        print trim(s)
        line=substr(line, RSTART+RLENGTH)
      }
    }
  ' "$1"
}

# --- 4. ツリー構築 ---
declare -A visited_global
TREE_CONTENT=""

build_tree() {
  local link_target="$1" depth="$2" current_stack="$3"
  local indent=""
  for ((i=0; i<depth; i++)); do indent+="  "; done

  local f_path="${ID_MAP[$link_target]:-}"
  if [[ -z "$f_path" || ! -f "$f_path" ]]; then
    TREE_CONTENT+="${indent}- [[${link_target}]] ${ICON_ERROR}\n"
    return
  fi

  local display_name
  display_name=$(basename "${f_path%.md}")
  local details
  details=$(get_status_details "$f_path")
  local status_icons="${details%|*}"
  local extra_info="${details#*|}"

  # 循環参照チェック (パス文字列比較)
  if [[ "$current_stack" == *"[${f_path}]"* ]]; then
    TREE_CONTENT+="${indent}- [[${display_name}]] ${status_icons}${ICON_CYCLE}\n"
    return
  fi

  if [[ -n "${visited_global[$f_path]:-}" ]]; then
    TREE_CONTENT+="${indent}- [[${display_name}]] ${status_icons}${ICON_ALREADY}\n"
    return
  fi

  visited_global[$f_path]=1
  TREE_CONTENT+="${indent}- [[${display_name}]] ${status_icons}${extra_info}\n"

  while read -r child; do
    [[ -z "$child" ]] && continue
    build_tree "$child" $((depth + 1)) "${current_stack}[${f_path}]"
  done < <(extract_wikilinks "$f_path")
}

# --- 5. 実行 ---
DISPLAY_NAME=$(basename "${TARGET_FILE%.md}")
START_ID=$(awk '/^id:[[:space:]]*/ { sub(/^id:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TARGET_FILE")
[[ -z "$START_ID" ]] && START_ID="$DISPLAY_NAME"

echo "Updating Visual Priority Tree for ${DISPLAY_NAME}..."
build_tree "$START_ID" 0 ""

NOW=$(date '+%Y-%m-%dT%H:%M:%S')
{
  echo "---"
  echo "id: $(date '+%Y%m%d%H%M')-TREE-VIEW"
  echo "tags: [system, zk-archive]"
  echo "title: Status Tree - ${DISPLAY_NAME}"
  echo "closed: ${NOW}"
  echo "---"
  echo "# 🌲 Visual Priority Tree: [[${DISPLAY_NAME}]]"
  echo "- 生成日時: ${NOW}"
  echo "- 凡例: ✅ 完 / 📖 開 / 🎯 集中 / 🧱 閉塞 / ⏳ 待機 / 🔗 既出 / 🔁 循環"
  echo "---"
  echo -e "$TREE_CONTENT"
} > "$OUTPUT_FILE"

echo "[OK] Tree View saved to: $OUTPUT_FILE"

# VS Codeで開く（Git Bash環境用）
if command -v code >/dev/null 2>&1; then
  code "$OUTPUT_FILE"
fi
