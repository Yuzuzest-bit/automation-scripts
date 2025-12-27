#!/usr/bin/env bash

# 文字化け対策
export LC_ALL=C.UTF-8
set -Eeuo pipefail

# --- 設定 ---
OUTDIR_NAME="dashboards"
FIXED_FILENAME="TREE_VIEW.md"

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

# 1. パスとルートの確定（ここを確実に直しました）
TARGET_FILE_RAW="${1:-}"
[[ -z "$TARGET_FILE_RAW" ]] && usage

# 絶対パスを取得
TARGET_FILE_ABS=$(readlink -f "$TARGET_FILE_RAW")
ROOT=$(pwd) # 実行時のカレントディレクトリをVaultルートとみなす

OUTDIR="${ROOT}/${OUTDIR_NAME}"
mkdir -p "$OUTDIR"
OUTPUT_FILE="${OUTDIR}/${FIXED_FILENAME}"

# --- 2. IDインデックスの作成（安定性と速度の両立） ---
declare -A ID_MAP
echo "Scanning files... (Please wait)"

# .git 等を除外してファイルリストを一括取得
while read -r f; do
    # 外部コマンド(awk/sed)を使わず、Bashのreadで中身を判定（高速）
    # 最初の30行程度からidを探す
    found_id=""
    line_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_count++)) && ((line_count > 30)) && break
        
        # Windowsの改行コード対策
        line="${line%$'\r'}"
        
        if [[ "$line" =~ ^id:[[:space:]]*(.+) ]]; then
            found_id="${BASH_REMATCH[1]}"
            found_id="${found_id%"${found_id##*[![:space:]]}"}" # trim
            break
        fi
    done < "$f"

    # IDがあれば登録、なければファイル名をキーにする
    if [[ -n "$found_id" ]]; then
        ID_MAP["$found_id"]="$f"
    fi
    
    fname=$(basename "$f" .md)
    if [[ -z "${ID_MAP["$fname"]:-}" ]]; then
        ID_MAP["$fname"]="$f"
    fi
done < <(find "$ROOT" -maxdepth 4 -name "*.md" -not -path "*/.*" -not -path "*/$OUTDIR_NAME/*")

# --- 3. 状態取得（極力外部コマンドを減らす） ---
get_status_details() {
    local f_path="$1"
    local icons="$ICON_OPEN"
    local extra=""
    
    # grep 1回で判定
    local meta
    meta=$(grep -m 30 -E "^closed:|@focus|@awaiting|@blocked" "$f_path" | tr -d '\r' || true)
    
    if [[ "$meta" == *"closed:"* ]]; then icons="$ICON_CLOSED"; fi
    
    if [[ "$meta" == *"@focus"* ]]; then
        icons+="$ICON_FOCUS"
    elif [[ "$meta" == *"@blocked"* ]]; then
        icons+="$ICON_BLOCK"
        extra=" (🧱 $(echo "$meta" | sed -n 's/.*@blocked//p' | head -n1 | xargs))"
    elif [[ "$meta" == *"@awaiting"* ]]; then
        icons+="$ICON_AWAIT"
        extra=" (⏳ $(echo "$meta" | sed -n 's/.*@awaiting//p' | head -n1 | xargs))"
    fi
    echo "${icons}|${extra}"
}

# --- 4. リンク抽出 (AWKを使用) ---
extract_links() {
    awk '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN{fm=0; code=0; first=0}
    {
        line=$0; sub(/\r$/, "", line); t=trim(line)
        if(!first){ if(t=="")next; first=1; if(t=="---"){fm=1;next}}
        if(fm){ if(t=="---"){fm=0}; next}
        if(t ~ /^```/){ code=!code; next }
        if(code) next
        while(match(line, /\[\[[^][]+\]\]/)){
            s=substr(line, RSTART+2, RLENGTH-4)
            p=index(s,"|"); if(p>0) s=substr(s,1,p-1)
            p=index(s,"#"); if(p>0) s=substr(s,1,p-1)
            print trim(s)
            line=substr(line, RSTART+RLENGTH)
        }
    }' "$1"
}

# --- 5. ツリー構築 ---
declare -A visited
TREE=""

build_tree() {
    local target="$1" depth="$2" stack="$3"
    local indent=""
    for ((i=0; i<depth; i++)); do indent+="  "; done

    local f="${ID_MAP["$target"]:-}"
    if [[ -z "$f" || ! -f "$f" ]]; then
        TREE+="${indent}- [[${target}]] ${ICON_ERROR}\n"
        return
    fi

    local dname=$(basename "$f" .md)
    if [[ "$stack" == *"[${f}]"* ]]; then
        TREE+="${indent}- [[${dname}]] ${ICON_CYCLE}\n"; return
    fi
    if [[ -n "${visited["$f"]:-}" ]]; then
        TREE+="${indent}- [[${dname}]] ${ICON_ALREADY}\n"; return
    fi

    visited["$f"]=1
    local res=$(get_status_details "$f")
    TREE+="${indent}- [[${dname}]] ${res%|*}${res#*|}\n"

    while read -r child; do
        [[ -z "$child" ]] && continue
        build_tree "$child" $((depth + 1)) "${stack}[${f}]"
    done < <(extract_links "$f")
}

# --- 6. 実行 ---
# 開始IDの特定
START_ID=$(grep -m 1 "^id:" "$TARGET_FILE_ABS" | sed 's/id:[[:space:]]*//;s/\r//' || true)
[[ -z "$START_ID" ]] && START_ID=$(basename "$TARGET_FILE_ABS" .md)

echo "Generating tree for [[$START_ID]]..."
build_tree "$START_ID" 0 ""

NOW=$(date '+%Y-%m-%dT%H:%M:%S')
{
    echo "---"
    echo "title: Tree - $START_ID"
    echo "---"
    echo "# 🌲 Tree View: [[$START_ID]]"
    echo "- 生成: $NOW"
    echo "---"
    echo -e "$TREE"
} > "$OUTPUT_FILE"

echo "Success: $OUTPUT_FILE"
# VS Code で開く
command -v code >/dev/null 2>&1 && code "$OUTPUT_FILE"
