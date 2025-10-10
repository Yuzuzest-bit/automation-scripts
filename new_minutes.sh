#!/bin/bash

# --- 設定 ---
# フォルダを作成する場所
TARGET_DIR="./"
# 作成する議事録のファイル名
MARKDOWN_FILENAME="meeting_minutes.md"
# --- 設定はここまで ---
# 1. スクリプト実行時の引数を「議題」として取得
# 例: ./script.sh "新製品キックオフ" -> TOPIC="新製品キックオフ"
TOPIC="$1"

# 2. 今日の日付を YYYYMMDD 形式で取得
TODAY=$(date +"%Y%m%d")

# 3. 連番の初期値を設定
COUNTER=1

# 4. ユニークなプレフィックス(yyyymmdd_連番)を決定
while true; do
  # チェックするプレフィックスを作成 (例: 20251010_1)
  PREFIX="${TODAY}_${COUNTER}"
  
  # ★変更点: このプレフィックスで始まるフォルダが1つでも存在するかチェック
  # `ls -d ${PREFIX}*` でプレフィックスに一致するフォルダをリストし、その数を数える
  # `2>/dev/null` は、一致するフォルダがない場合のエラーメッセージを非表示にするおまじない
  COUNT=$(ls -d "${TARGET_DIR}${PREFIX}"* 2>/dev/null | wc -l)
  if [ "$COUNT" -eq 0 ]; then
    # 一致するフォルダが0個なら、この連番で決定しループを抜ける
    break
  fi
  # 一致するフォルダが1個以上あれば、カウンターを1増やして次の候補を試す
  ((COUNTER++))
done

# 5. 最終的なフォルダ名を決定
# ループを抜けた時点のプレフィックス (例: 20251010_2)
FINAL_PREFIX="${TODAY}_${COUNTER}"

# 議題が引数で渡されていれば、フォルダ名に含める
if [ -n "$TOPIC" ]; then
  # 例: 20251010_2_新製品キックオフ
  DIR_NAME="${FINAL_PREFIX}_${TOPIC// /_}" # 議題のスペースはアンダースコアに置換
else
  # 例: 20251010_2
  DIR_NAME="${FINAL_PREFIX}"
fi

# 6. フォルダと議事録ファイルを作成
FULL_PATH="${TARGET_DIR}${DIR_NAME}"
echo "フォルダを作成します: ${FULL_PATH}"
mkdir -p "$FULL_PATH"

MARKDOWN_FILE_PATH="${FULL_PATH}/${MARKDOWN_FILENAME}"
echo "議事録ファイルを作成します: ${MARKDOWN_FILE_PATH}"

cat << EOF > "$MARKDOWN_FILE_PATH"
# 議事録

## 議題
- ${TOPIC:-}

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
