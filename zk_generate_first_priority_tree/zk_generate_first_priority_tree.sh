#!/usr/bin/env bash

export LC_ALL=C.UTF-8
set -Eeuo pipefail

# --- 設定 ---
OUTDIR_NAME="dashboards"
FIXED_FILENAME="TREE_VIEW.md"
CACHE_FILE=".tree_cache.txt"

# アイコン
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "
ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "
ICON_BLOCK="🧱 "
ICON_CYCLE="🔁 "
ICON_ALREADY="🔗 "

usage() { echo "usage: $0 <source_note.md>" >&2; exit 2; }

TARGET_FILE_RAW="${1:-}"
[[ -z "$TARGET_FILE_RAW" ]] && usage
TARGET_FILE_ABS=$(readlink -f "$TARGET_FILE_RAW")
ROOT="$(pwd)"
OUTPUT_FILE="${ROOT}/${OUTDIR_NAME}/${FIXED_FILENAME}"
mkdir -p "${ROOT}/${OUTDIR_NAME}"

# キャッシュ用配列
# 構造: [ファイルパス]="最終更新秒 | ID | ステータスアイコン | 追加情報 | 子リンク(スペース区切り)"
declare -A FILE_CACHE

# --- 1. キャッシュの読み込み ---
if [[ -f "$CACHE_FILE" ]]; then
    echo "Loading cache..."
    while IFS=$'\t' read -r f_path cache_data; do
        FILE_CACHE["$f_path"]="$cache_data"
    done < "$CACHE_FILE"
fi

# --- 2. 高速スキャン & 解析 (差分のみ) ---
declare -A ID_MAP
echo "Syncing Vault..."

while read -r f; do
    # 最終更新日時を取得
    mtime=$(stat -c %Y "$f")
    
    # キャッシュがあるか確認
    cached_entry="${FILE_CACHE["$f"]:-}"
    cached_mtime="${cached_entry%%|*}"

    if [[ -n "$cached_entry" && "$mtime" == "$cached_mtime" ]]; then
        # 更新されていないのでキャッシュを利用
        data="${cached_entry#*|}"
        fid="${data%%|*}"
    else
        # 新規または更新されたファイルのみ解析
        # 1. ID抽出
        fid=$(grep -m 1 "^id:" "$f" | sed 's/id:[[:space:]]*//;s/\r//' || true)
        [[ -z "$fid" ]] && fid=$(basename "$f" .md)
        
        # 2. ステータス抽出
        meta=$(grep -m 30 -E "^closed:|@focus|@awaiting|@blocked" "$f" | tr -d '\r' || true)
        icons="$ICON_OPEN"; [[ "$meta" == *"closed:"* ]] && icons="$ICON_CLOSED"
        extra=""
        if [[ "$meta" == *"@focus"* ]]; then icons+="$ICON_FOCUS"
        elif [[ "$meta" == *"@blocked"* ]]; then icons+="$ICON_BLOCK"; extra=" (🧱 $(echo "$meta" | sed -n 's/.*@blocked//p' | head -n1 | xargs))"
        elif [[ "$meta" == *"@awaiting"* ]]; then icons+="$ICON_AWAIT"; extra=" (⏳ $(echo "$meta" | sed -n 's/.*@awaiting//p' | head -n1 | xargs))"
        fi
        
        # 3. リンク抽出 (子要素)
        links=$(awk 'BEGIN{fm=0;code=0;f=0}{line=$0;sub(/\r$/,"",line);t=line;gsub(/^[ \t]+|[ \t]+$/,"",t);if(!f){if(t=="")next;f=1;if(t=="---"){fm=1;next}};if(fm){if(t=="---")fm=0;next};if(t~/^```/){code=!code;next};if(code)next;while(match(line,/\[\[[^][]+\]\]/)){s=substr(line,RSTART+2,RLENGTH-4);p=index(s,"|");if(p>0)s=substr(s,1,p-1);p=index(s,"#");if(p>0)s=substr(s,1,p-1);printf "%s ",s;line=substr(line,RSTART+RLENGTH)}}' "$f")
        
        # キャッシュ更新
        FILE_CACHE["$f"]="$mtime|$fid|$icons|$extra|$links"
    fi
    
    # IDマップ作成
    ID_MAP["$fid"]="$f"
    
done < <(find "$ROOT" -maxdepth 4 -name "*.md" -not -path "*/.*" -not -path "*/$OUTDIR_NAME/*")

# --- 3. キャッシュをファイルに保存 ---
for f in "${!FILE_CACHE[@]}"; do
    printf "%s\t%s\n" "$f" "${FILE_CACHE[$f]}"
done > "$CACHE_FILE"

# --- 4. ツリー構築 (メモリ上のデータのみで行うので一瞬) ---
declare -A visited
TREE=""

build_tree() {
    local target="$1" depth="$2" stack="$3"
    local indent=""; for ((i=0; i<depth; i++)); do indent+="  "; done

    local f="${ID_MAP["$target"]:-}"
    if [[ -z "$f" || ! -f "$f" ]]; then
        TREE+="${indent}- [[${target}]] ${ICON_ERROR}\n"; return
    fi

    local data="${FILE_CACHE["$f"]#*|}" # IDを取り除く
    local fid="${data%%|*}"
    local rest="${data#*|}"
    local icons="${rest%%|*}"
    local rest2="${rest#*|}"
    local extra="${rest2%%|*}"
    local links="${rest2#*|}"

    if [[ "$stack" == *"[${f}]"* ]]; then TREE+="${indent}- [[${fid}]] ${ICON_CYCLE}\n"; return; fi
    if [[ -n "${visited["$f"]:-}" ]]; then TREE+="${indent}- [[${fid}]] ${icons}${ICON_ALREADY}\n"; return; fi
    visited["$f"]=1

    TREE+="${indent}- [[${fid}]] ${icons}${extra}\n"
    for child in $links; do
        build_tree "$child" $((depth + 1)) "${stack}[${f}]"
    done
}

# --- 5. 実行 ---
START_ID=$(grep -m 1 "^id:" "$TARGET_FILE_ABS" | sed 's/id:[[:space:]]*//;s/\r//' || true)
[[ -z "$START_ID" ]] && START_ID=$(basename "$TARGET_FILE_ABS" .md)

echo "Building Tree..."
build_tree "$START_ID" 0 ""

NOW=$(date '+%Y-%m-%dT%H:%M:%S')
{
    echo "---"; echo "title: Tree - $START_ID"; echo "---"
    echo "# 🌲 Tree View: [[$START_ID]]"
    echo "- 生成: $NOW (Cache sync completed)"
    echo "---"
    echo -e "$TREE"
} > "$OUTPUT_FILE"

echo "Success: $OUTPUT_FILE"
