#!/usr/bin/env bash
# 親ノートの [[link]] の右側に、戦績と期限を一括反映する
# 形式: [[link]] ✅ (3回) @2025-12-30 due: 2026-01-05

# 日本語・絵文字文字化け防止
export LANG=ja_JP.UTF-8

PARENT_FILE="${1:-}"

if [[ -z "$PARENT_FILE" || ! -f "$PARENT_FILE" ]]; then
  echo "[ERR] Parent file not found."
  exit 1
fi

ROOT="$(cd "$(dirname "$PARENT_FILE")" && pwd)"

# 親ノートから wikilink を抽出 (Windows改行コード除去を追加)
LINKS=$(grep -o '\[\[[^]]*\]\]' "$PARENT_FILE" | sed 's/\[\[//g; s/\]\]//g' | tr -d '\r' || true)

echo "[INFO] Syncing dashboard data to index..."

IFS=$'\n'
for LINK in $LINKS; do
  LINK=$(echo "$LINK" | tr -d '\r\n')
  FILE_PATH="${ROOT}/${LINK}.md"

  if [[ ! -f "$FILE_PATH" ]]; then
    continue
  fi

  # 子ノートからメタデータを抽出 (Windows改行コード除去を追加)
  RES=$(grep "^st_result:" "$FILE_PATH" | awk '{print $2}' | tr -d '\r' || true)
  ATT=$(grep "^st_attempts:" "$FILE_PATH" | awk '{print $2}' | tr -d '\r' || true)
  LAST_DATE=$(grep "^st_last_solved:" "$FILE_PATH" | awk '{print $2}' | tr -d '\r' || true)
  DUE=$(grep "^due:" "$FILE_PATH" | awk '{print $2}' | tr -d '\r' || true)

  # --- 表示パーツの組み立て ---
  # 1. 結果マーク
  MARK="ーー"
  [[ "$RES" == "st-ok" ]] && MARK="✅"
  [[ "$RES" == "st-wrong" ]] && MARK="❌"

  # 2. 回数
  ATT_DISP="(${ATT:-0}回)"

  # 3. 最終実施日 (@記号付き)
  LAST_DISP=""
  if [[ -n "$LAST_DATE" ]]; then
    LAST_DISP="@$LAST_DATE"
  fi

  # 4. 期限 (due: 記号付き)
  DUE_DISP=""
  if [[ -n "$DUE" ]]; then
    DUE_DISP="due: $DUE"
  fi

  # --- 親ノートの行を置換 ---
  # リンクの右側を一旦リセットして再構築
  NEW_STR="[[${LINK}]] ${MARK} ${ATT_DISP} ${LAST_DISP} ${DUE_DISP}"
  
  # 余分なスペースを整形
  NEW_STR=$(echo "$NEW_STR" | sed 's/  */ /g' | sed 's/ *$//')

  # 【重要】Windows (GNU sed) 用に -i "" を -i に変更
  sed -i "s|\[\[${LINK}\]\].*|${NEW_STR}|g" "$PARENT_FILE"

done

echo "----------------------------------------"
echo "完了！ダッシュボードを更新しました。"
