#!/usr/bin/env bash
# ------------------------------------------------------------
# zk_update_fast.sh (Windows高速化版)
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

# --- 【高速化 1】 全ファイルのパスをメモリにマッピング ---
# Bash 4.0以降の「連想配列」を使います (Git Bashは対応)
declare -A FILE_MAP

# findコマンドを1回だけ実行し、結果をループで配列に格納
# プロセス起動回数を劇的に減らす
while IFS= read -r FILE_PATH; do
  # パスからファイル名(拡張子なし)を取り出す
  BASENAME=$(basename "$FILE_PATH" .md)
  FILE_MAP["$BASENAME"]="$FILE_PATH"
done < <(find "$SEARCH_ROOT" -name "*.md")

echo "[INFO] File indexing complete. Updating dashboard..."

# 親ノートからリンク抽出
LINKS=$(grep -o '\[\[[^]]*\]\]' "$PARENT_FILE" | sed 's/\[\[//g; s/\]\]//g' | tr -d '\r' || true)

IFS=$'\n'
for LINK in $LINKS; do
  LINK=$(echo "$LINK" | tr -d '\r\n')
  
  # --- 【高速化 2】 メモリからパスを即座に取得 ---
  # findコマンドを使わず、配列から一瞬で取り出す
  TARGET_FILE="${FILE_MAP[$LINK]}"

  if [[ -z "$TARGET_FILE" ]]; then
    continue
  fi

  # --- 【高速化 3】 データの抽出を1回のawkプロセスで済ませる ---
  # 以前は grep x 4 + awk x 4 = 8プロセスだったのを 1プロセスに削減
  # Windowsの改行コード(\r)もここで除去
  read -r RES ATT LAST DUE <<< $(awk '
    BEGIN { r=""; a=""; l=""; d="" }
    /^st_result:/ { sub(/\r$/, "", $2); r=$2 }
    /^st_attempts:/ { sub(/\r$/, "", $2); a=$2 }
    /^st_last_solved:/ { sub(/\r$/, "", $2); l=$2 }
    /^due:/ { sub(/\r$/, "", $2); d=$2 }
    END { print r, a, l, d }
  ' "$TARGET_FILE")

  # --- 表示パーツの組み立て (ここはBash内部処理なので速い) ---
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
echo "完了！高速化版で更新しました。"
