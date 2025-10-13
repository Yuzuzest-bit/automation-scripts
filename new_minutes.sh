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
  # チェックするプレフィックスを作成 (例: 20251014_1)
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

# 4. 作成するフォルダ名を決定 (例: 20251014_2)
DIR_NAME="${TODAY}_${COUNTER}"

# 5. フォルダを作成
FULL_PATH="${TARGET_DIR}${DIR_NAME}"
echo "フォルダを作成します: ${FULL_PATH}"
mkdir -p "$FULL_PATH"


# ★★★ ここからが変更・追加部分 ★★★

# 6. 絶対パスを取得してクリップボードにコピー
# readlink -f で絶対パスに変換 (macOSの場合はbrew install coreutilsでgreadlinkが必要な場合あり)
# もしreadlinkコマンドがなければ、単純に echo "$FULL_PATH" としても良い
ABS_PATH=$(readlink -f "$FULL_PATH")

COPY_SUCCESS=false
if command -v pbcopy &> /dev/null; then # macOS
  echo -n "$ABS_PATH" | pbcopy
  COPY_SUCCESS=true
elif command -v clip.exe &> /dev/null; then # Windows (WSL)
  echo -n "$ABS_PATH" | clip.exe
  COPY_SUCCESS=true
elif command -v xclip &> /dev/null; then # Linux (X11)
  echo -n "$ABS_PATH" | xclip -selection clipboard
  COPY_SUCCESS=true
elif command -v wl-copy &> /dev/null; then # Linux (Wayland)
  echo -n "$ABS_PATH" | wl-copy
  COPY_SUCCESS=true
fi

if $COPY_SUCCESS; then
  echo "📋 フォルダパスをクリップボードにコピーしました: ${ABS_PATH}"
else
  echo "⚠️ クリップボードコマンドが見つかりませんでした。"
fi

# ★★★ ここまでが変更・追加部分 ★★★


# 7. 議事録ファイルを作成
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
