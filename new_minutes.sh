#!/bin/bash

# --- 設定 ---
# フォルダを作成する場所を指定します。 "./" はスクリプトを実行した場所（カレントディレクトリ）を意味します。
# 例: "/c/Users/Taro/Documents/議事録" のように絶対パスで指定することも可能です。
TARGET_DIR="./"

# 作成する議事録のファイル名
MARKDOWN_FILENAME="meeting_minutes.md"
# --- 設定はここまで ---


# 1. 今日の日付を YYYYMMDD 形式で取得
TODAY=$(date +"%Y%m%d")

# 2. 連番の初期値を設定
COUNTER=1

# 3. ユニークなフォルダ名を決定
while true; do
  # フォルダ名の候補を作成 (例: 20251010_1)
  DIR_NAME="${TODAY}_${COUNTER}"
  
  # 同じ名前のフォルダやファイルが存在しないかチェック
  if [ ! -e "${TARGET_DIR}${DIR_NAME}" ]; then
    # 存在しなければ、この名前で決定しループを抜ける
    break
  fi
  
  # 存在した場合は、カウンターを1増やして次の候補を試す
  ((COUNTER++))
done

# 4. フォルダを作成
FULL_PATH="${TARGET_DIR}${DIR_NAME}"
echo "フォルダを作成します: ${FULL_PATH}"
mkdir -p "$FULL_PATH"

# 5. フォルダ内にMarkdownファイルを作成し、テンプレートを書き込む
MARKDOWN_FILE_PATH="${FULL_PATH}/${MARKDOWN_FILENAME}"
echo "議事録ファイルを作成します: ${MARKDOWN_FILE_PATH}"

cat << EOF > "$MARKDOWN_FILE_PATH"
# 議事録

## 日時
- $(date +"%Y年%m月%d日 %H:%M")

## 場所
- 

## 参加者
- 

## 議題
- 

## 決定事項
- 

## 次回までのタスク (TODO)
- 

EOF

echo "✅ 完了しました。"

