#!/usr/bin/env bash
# ------------------------------------------------------------
# zk_update_fast_fix.sh (高速化・列ズレ修正版)
# ------------------------------------------------------------

export LANG=ja_JP.UTF-8

# 引数処理
PARENT_FILE="${1:-}"
if [[ -z "$PARENT_FILE" || ! -f "$PARENT_FILE" ]]; then
  echo "[ERR] Target dashboard file not found."
  echo "Usage: $0 <dashboard_file> [search_root_dir]"
  exit 1
fi

DEFAULT_ROOT="$(cd "$(dirname "$PARENT_FILE")/.." && pwd)"
SEARCH_ROOT="${2:-$DEFAULT_ROOT}"

if [[ ! -d "$SEARCH_ROOT" ]]; then
  echo "[ERR] Search directory not found: $SEARCH_ROOT"
  exit 1
fi

echo "[INFO] Indexing files in: $SEARCH_ROOT ..."

# --- 全ファイルのパスをメモリにマッピング (高速化の要) ---
declare -A FILE_MAP

# findの結果をループ処理して連想配列に格納
while IFS= read -r FILE_PATH; do
  BASENAME=$(basename "$FILE_PATH" .md)
  FILE_MAP["$BASENAME"]="$FILE_PATH"
done < <(find "$SEARCH_ROOT" -name "*.md")

echo "[INFO] File indexing complete. Updating dashboard..."

# 親ノートからリンク抽出
LINKS=$(grep -o '\[\[[^]]*\]\]' "$PARENT_FILE" | sed 's/\[\[//g; s/\]\]//g' | tr -d '\r' || true)

IFS=$'\n'
for LINK in $LINKS; do
  LINK=$(echo "$LINK" | tr -d '\r\n')
  
  # マッピングからパスを即座に取得
  TARGET_FILE="${FILE_MAP[$LINK]}"

  if [[ -z "$TARGET_FILE" ]]; then
    continue
  fi

  # --- 【修正ポイント】 区切り文字をパイプ(|)にしてズレを防止 ---
  # データ読み込み時に空白ではなく | を区切りとして使う
  # awkの printf "%s|%s..." が重要
  
  IFS='|' read -r RES ATT LAST DUE <<< $(awk '
    BEGIN { r=""; a=""; l=""; d="" }
    /^st_result:/ { sub(/\r$/, "", $2); r=$2 }
    /^st_attempts:/ { sub(/\r$/, "", $2); a=$2 }
    /^st_last_solved:/ { sub(/\r$/, "", $2); l=$2 }
    /^due:/ { sub(/\r$/, "", $2); d=$2 }
    END { printf "%s|%s|%s|%s", r, a, l, d }
  ' "$TARGET_FILE")

  # --- 表示パーツの組み立て ---
  MARK="ーー"
  [[ "$RES" == "st-ok" ]] && MARK="✅"
  [[ "$RES" == "st-wrong" ]] && MARK="❌"

  ATT_DISP="(${ATT:-0}回)"

  LAST_DISP=""
  [[ -n "$LAST" ]] && LAST_DISP="@$LAST"

  DUE_DISP=""
  [[ -n "$DUE" ]] && DUE_DISP="due: $DUE"

  # --- 親ノートの行を置換 ---
  NEW_STR="[[${LINK}]] ${MARK} ${ATT_DISP} ${LAST_DISP} ${DUE_DISP}"
  NEW_STR=$(echo "$NEW_STR" | sed 's/  */ /g' | sed 's/ *$//')

  sed -i "s|\[\[${LINK}\]\].*|${NEW_STR}|g" "$PARENT_FILE"

  echo "[OK] Updated: $LINK"
done

echo "----------------------------------------"
echo "完了！高速かつ正確に更新しました。"
