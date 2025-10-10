#!/bin/bash

# --- 設定 ---
# フォルダを作成する場所
TARGET_DIR="./"
# 作成する議事録のファイル名
MARKDOWN_FILENAME="meeting_minutes.md"
# --- 設定はここまで ---


# 1. 今日の日付を YYYYMMDD 形式で取得
TODAY=$(date +"%Y%m%d")

# 2. 連番の初期値を設定
COUNTER=1

# 3. 次に使用すべき連番を探す
while true; do
  # チェックするプレフィックスを作成 (例: 20251010_1)
  PREFIX="${TODAY}_${COUNTER}"
  
  # このプレフィックスで始まるフォルダが存在するかチェック
  COUNT=$(ls -d "${TARGET_DIR}${PREFIX}"* 2>/dev/null | wc -l)
  
  if [ "$COUNT" -eq 0 ]; then
    # 存在しなければ、この連番を使うことにしてループを抜ける
    break
  fi
  
  # 存在すれば、カウンターを1増やして次の連番を試す
  ((COUNTER++))
done

# 4. 作成するフォルダ名を決定 (例: 20251010_2)
DIR_NAME="${TODAY}_${COUNTER}"

# 5. フォルダと議事録ファイルを作成
FULL_PATH="${TARGET_DIR}${DIR_NAME}"
echo "フォルダを作成します: ${FULL_PATH}"
mkdir -p "$FULL_PATH"

MARKDOWN_FILE_PATH="${FULL_PATH}/${MARKDOWN_FILENAME}"
echo "議事録ファイルを作成します: ${MARKDOWN_FILE_PATH}"

cat << EOF > "$MARKDOWN_FILE_PATH"
# 議事録

## 議題
- 

## 日時
- $(date +"%Y年%m月%d日 %H:%M")

## 場所
- 

## 参加者
- 

## 決定事項
- 

## 次回までのタスク (TODO)
- 

EOF

echo "✅ 完了しました。"
