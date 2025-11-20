#!/bin/bash

# --- 設定 ---
# ファイルを作成する場所
TARGET_DIR="./"
# 作成する議事録のベースファイル名
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
  
  # このプレフィックスで始まるファイルやフォルダが存在するかチェック
  # 既存のフォルダ運用(20251014_1/...)が残っていても衝突しないようにそのまま流用
  COUNT=$(ls -d "${TARGET_DIR}${PREFIX}"* 2>/dev/null | wc -l)
  
  if [ "$COUNT" -eq 0 ]; then
    # 存在しなければ、この連番を使うことにしてループを抜ける
    break
  fi
  
  # 存在すれば、カウンターを1増やして次の連番を試す
  ((COUNTER++))
done

# 4. 作成する Markdown ファイル名を決定 (例: 20251014_2_meeting_minutes.md)
BASENAME="${PREFIX}_${MARKDOWN_FILENAME}"
FULL_PATH="${TARGET_DIR}${BASENAME}"

echo "Markdown ファイルを作成します: ${FULL_PATH}"

# 5. 絶対パスを取得してクリップボードにコピー
ABS_PATH=$(readlink -f "$FULL_PATH")
COPIED_PATH=$ABS_PATH # 表示用にコピーしておく

COPY_SUCCESS=false
if command -v pbcopy &> /dev/null; then # macOS
  echo -n "$ABS_PATH" | pbcopy
  COPY_SUCCESS=true

elif command -v clip.exe &> /dev/null; then # Windows (WSL / Git Bash)
  # Git Bash用のパスをWindows形式 (C:\...) に変換
  WIN_PATH=$(cygpath -w "$ABS_PATH")
  echo -n "$WIN_PATH" | clip.exe
  COPIED_PATH=$WIN_PATH # 表示用パスをWindows形式で上書き
  COPY_SUCCESS=true

elif command -v xclip &> /dev/null; then # Linux (X11)
  echo -n "$ABS_PATH" | xclip -selection clipboard
  COPY_SUCCESS=true

elif command -v wl-copy &> /dev/null; then # Linux (Wayland)
  echo -n "$ABS_PATH" | wl-copy
  COPY_SUCCESS=true
fi

if $COPY_SUCCESS; then
  echo "📋 ファイルパスをクリップボードにコピーしました: ${COPIED_PATH}"
else
  echo "⚠️ クリップボードコマンドが見つかりませんでした。"
fi

# 6. 議事録ファイルを作成
cat << EOF > "$FULL_PATH"
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

echo "✅ 完了しました。作成されたファイル: ${FULL_PATH}"
