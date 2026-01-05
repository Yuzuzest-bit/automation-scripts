#!/usr/bin/env bash
# ------------------------------------------------------------
# zk_update_deep_search.sh
# 使い方: ./script.sh [ダッシュボードファイル] [検索するルートフォルダ(任意)]
# 例: ./script.sh dashboard/TREE_VIEW.md .
# ------------------------------------------------------------

# 文字化け防止
export LANG=ja_JP.UTF-8

# 引数1: ダッシュボードファイル (必須)
PARENT_FILE="${1:-}"

if [[ -z "$PARENT_FILE" || ! -f "$PARENT_FILE" ]]; then
  echo "[ERR] Target dashboard file not found."
  echo "Usage: $0 <dashboard_file> [search_root_dir]"
  exit 1
fi

# 引数2: 検索を開始するルートフォルダ (任意)
# 指定がなければ、ダッシュボードの「1つ上の階層」をデフォルトとする
DEFAULT_ROOT="$(cd "$(dirname "$PARENT_FILE")/.." && pwd)"
SEARCH_ROOT="${2:-$DEFAULT_ROOT}"

if [[ ! -d "$SEARCH_ROOT" ]]; then
  echo "[ERR] Search directory not found: $SEARCH_ROOT"
  exit 1
fi

echo "[INFO] Dashboard: $PARENT_FILE"
echo "[INFO] Searching recursively in: $SEARCH_ROOT"

# 親ノートから wikilink を抽出 (Windows改行コード除去)
LINKS=$(grep -o '\[\[[^]]*\]\]' "$PARENT_FILE" | sed 's/\[\[//g; s/\]\]//g' | tr -d '\r' || true)

IFS=$'\n'
for LINK in $LINKS; do
  LINK=$(echo "$LINK" | tr -d '\r\n')
  
  # --- ファイル探索 (findコマンドで再帰検索) ---
  # 指定フォルダ以下から、名前が一致する .md ファイルを探す
  # head -n 1 で最初に見つかった1つだけを採用する（同名ファイル対策）
  TARGET_FILE=$(find "$SEARCH_ROOT" -name "${LINK}.md" | head -n 1)

  if [[ -z "$TARGET_FILE" ]]; then
    # echo "[WARN] Not found: ${LINK}.md (Skipping)"
    continue
  fi

  # --- 子ノートからメタデータを抽出 ---
  # Windows改行コード対策 (tr -d '\r') を継続
  RES=$(grep "^st_result:" "$TARGET_FILE" | awk '{print $2}' | tr -d '\r' || true)
  ATT=$(grep "^st_attempts:" "$TARGET_FILE" | awk '{print $2}' | tr -d '\r' || true)
  LAST_DATE=$(grep "^st_last_solved:" "$TARGET_FILE" | awk '{print $2}' | tr -d '\r' || true)
  DUE=$(grep "^due:" "$TARGET_FILE" | awk '{print $2}' | tr -d '\r' || true)

  # --- 表示パーツの組み立て ---
  # 1. 結果マーク
  MARK="ーー"
  [[ "$RES" == "st-ok" ]] && MARK="✅"
  [[ "$RES" == "st-wrong" ]] && MARK="❌"

  # 2. 回数
  ATT_DISP="(${ATT:-0}回)"

  # 3. 最終実施日
  LAST_DISP=""
  [[ -n "$LAST_DATE" ]] && LAST_DISP="@$LAST_DATE"

  # 4. 期限
  DUE_DISP=""
  [[ -n "$DUE" ]] && DUE_DISP="due: $DUE"

  # --- 親ノートの行を置換 ---
  NEW_STR="[[${LINK}]] ${MARK} ${ATT_DISP} ${LAST_DISP} ${DUE_DISP}"
  NEW_STR=$(echo "$NEW_STR" | sed 's/  */ /g' | sed 's/ *$//')

  # sed実行
  sed -i "s|\[\[${LINK}\]\].*|${NEW_STR}|g" "$PARENT_FILE"

  echo "[OK] Updated: $LINK (Found in: $TARGET_FILE)"
done

echo "----------------------------------------"
echo "完了！サブフォルダを含めて検索し、更新しました。"
