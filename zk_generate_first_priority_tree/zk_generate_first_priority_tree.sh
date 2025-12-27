#!/usr/bin/env bash
# zk_generate_tree_fast.sh

export LC_ALL=C.UTF-8
set -Eeuo pipefail

# --- 設定 ---
OUTDIR_NAME="dashboards"
FIXED_FILENAME="TREE_VIEW.md"
CACHE_FILE=".vault_id_cache"
CACHE_EXPIRY=3600 # キャッシュの有効期限（秒）。1時間。

# アイコン定義
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "
ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "
ICON_BLOCK="🧱 "
ICON_CYCLE="🔁 (infinite loop) "
ICON_ALREADY="🔗 (already shown) "

usage() { echo "usage: $0 <source_note.md>" >&2; exit 2; }

TARGET_FILE="${1:-}"
[[ -z "$TARGET_FILE" ]] && usage

# パス解決（外部コマンドを減らすためBash機能を使用）
ROOT="$(pwd)"
OUTDIR="${ROOT}/${OUTDIR_NAME}"
mkdir -p "$OUTDIR"
OUTPUT_FILE="${OUTDIR}/${FIXED_FILENAME}"

# --- 1. 高速IDインデックス作成 (Caching & Grep) ---
declare -A ID_MAP

update_cache() {
  echo "Scanning Vault (High-speed mode)..."
  # grep -r で一括抽出。ファイル名:行内容 の形式で取得
  # .git や .vscode を除外
  grep -rE "^id:[[:space:]]*" --include="*.md" --exclude-dir={.*,dashboards} . | \
  sed 's/\r//g' > "$CACHE_FILE" || true
}

# キャッシュが古い、または存在しない場合のみスキャン
if [[ ! -f "$CACHE_FILE" ]] || [[ $(($(date +%s) - $(date -r "$CACHE_FILE" +%s))) -gt $CACHE_EXPIRY ]]; then
  update_cache
fi

echo "Loading Index..."
while IFS=: read -r f_path _ id_val; do
  # 余計な空白を削除
  id_val=$(echo "$id_val" | xargs)
  [[ -n "$id_val" ]] && ID_MAP["$id_val"]="$f_path"
  
  # ファイル名(拡張子なし)もインデックス登録
  fname="${f_path##*/}"
  fname="${fname%.md}"
  if [[ -z "${ID_MAP[$fname]:-}" ]]; then ID_MAP["$fname"]="$f_path"; fi
done < "$CACHE_FILE"

# --- 2. 状態取得 (プロセス起動を最小化) ---
get_status_details() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && { echo "$ICON_ERROR|"; return; }

  # 1回のgrepで必要な情報をまとめて抜く
  local content
  content=$(grep -m 30 -E "^closed:|@focus|@awaiting|@blocked" "$f_path" | tr -d '\r' || true)

  local icons=""
  local extra_info=""

  if echo "$content" | grep -q "^closed:"; then icons+="$ICON_CLOSED"; else icons+="$ICON_OPEN"; fi
  
  if [[ "$content" == *"@focus"* ]]; then
    icons+="$ICON_FOCUS"
  elif [[ "$content" == *"@blocked"* ]]; then
    icons+="$ICON_BLOCK"
    extra_info=" (🧱 $(echo "$content" | sed -n 's/.*@blocked//p' | head -n1 | xargs))"
  elif [[ "$content" == *"@awaiting"* ]]; then
    icons+="$ICON_AWAIT"
    extra_info=" (⏳ $(echo "$content" | sed -n 's/.*@awaiting//p' | head -n1 | xargs))"
  fi
  echo "${icons}|${extra_info}"
}

# --- 3. リンク抽出 (既存のAWKを使用、ただし呼び出しを最適化) ---
extract_wikilinks() {
  # 標準入力から読み込むように変更
  awk '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN{in_fm=0; in_code=0; first=0}
    {
      line=$0; sub(/\r$/, "", line); t=trim(line)
      if(!first){ if(t=="")next; first=1; if(t=="---"){in_fm=1;next}}
      if(in_fm){ if(t=="---"){in_fm=0}; next}
      if(t ~ /^```/){ in_code = !in_code; next }
      if(in_code) next
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

  local display_name="${f_path##*/}"
  display_name="${display_name%.md}"
  
  if [[ "$current_stack" == *"[${f_path}]"* ]]; then
    TREE_CONTENT+="${indent}- [[${display_name}]] ${ICON_CYCLE}\n"
    return
  fi

  if [[ -n "${visited_global[$f_path]:-}" ]]; then
    TREE_CONTENT+="${indent}- [[${display_name}]] ${ICON_ALREADY}\n"
    return
  fi

  local details=$(get_status_details "$f_path")
  visited_global[$f_path]=1
  TREE_CONTENT+="${indent}- [[${display_name}]] ${details%|*}${details#*|}\n"

  # 子リンクをまとめて取得
  while read -r child; do
    [[ -z "$child" ]] && continue
    build_tree "$child" $((depth + 1)) "${current_stack}[${f_path}]"
  done < <(extract_wikilinks "$f_path")
}

# --- 5. 実行 ---
# 開始IDの取得
START_ID=$(grep -m 5 "^id:" "$TARGET_FILE" | sed 's/id:[[:space:]]*//;s/\r//' || true)
if [[ -z "$START_ID" ]]; then
    START_ID="${TARGET_FILE##*/}"
    START_ID="${START_ID%.md}"
fi

echo "Building tree for: $START_ID"
build_tree "$START_ID" 0 ""

# ファイル書き出し
NOW=$(date '+%Y-%m-%dT%H:%M:%S')
{
  echo "---"
  echo "title: Status Tree - $START_ID"
  echo "---"
  echo "# 🌲 Visual Priority Tree: [[$START_ID]]"
  echo "- 更新: $NOW"
  echo "---"
  echo -e "$TREE_CONTENT"
} > "$OUTPUT_FILE"

echo "[DONE] $OUTPUT_FILE"
