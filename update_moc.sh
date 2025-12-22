#!/bin/bash

TARGET_FILE="$1"
# アイコン定義
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "

# ターゲットファイルが存在しない場合は終了
if [ ! -f "$TARGET_FILE" ]; then
    echo "Error: File not found: $TARGET_FILE"
    exit 1
fi

# 一時ファイル作成
TEMP_FILE=$(mktemp)

# MOCファイルのあるディレクトリに移動（相対パス解決のため）
PARENT_DIR=$(dirname "$TARGET_FILE")
cd "$PARENT_DIR" || exit

# 行ごとに処理
while IFS= read -r line; do
    # 1. [[Filename]] が含まれているかチェック
    # 正規表現: [[ (任意の文字) ]] をキャプチャ
    if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
        LINK_TARGET="${BASH_REMATCH[1]}"
        
        # 拡張子 .md がなければ補完
        if [[ "$LINK_TARGET" != *.md ]]; then
            FILENAME="${LINK_TARGET}.md"
        else
            FILENAME="$LINK_TARGET"
        fi

        # 2. リンク先のファイル状態を確認
        STATUS_ICON="$ICON_ERROR" # デフォルトはエラー（ファイルなし）

        if [ -f "$FILENAME" ]; then
            # 先頭20行から "closed: 20..." のパターンを探す
            # grep -q でヒットするか確認
            if head -n 20 "$FILENAME" | grep -qE "^closed:\s*.+"; then
                STATUS_ICON="$ICON_CLOSED"
            else
                STATUS_ICON="$ICON_OPEN"
            fi
        fi

        # 3. 行の整形
        # まず既存のアイコンを削除 (sedを使用)
        # リスト記号( - )の後ろ、または [[ の直前にあるアイコンを消す
        CLEAN_LINE=$(echo "$line" | sed -E "s/($ICON_CLOSED|$ICON_OPEN|$ICON_ERROR)//g")

        # [[ の直前に新しいアイコンを挿入
        # 例: "- [[Note]]" -> "- 📖 [[Note]]"
        NEW_LINE=$(echo "$CLEAN_LINE" | sed "s/\[\[/$STATUS_ICON\[\[/")
        
        echo "$NEW_LINE" >> "$TEMP_FILE"
    else
        # リンクがない行はそのまま出力
        echo "$line" >> "$TEMP_FILE"
    fi
done < "$TARGET_FILE"

# 元のファイルを上書き
mv "$TEMP_FILE" "$TARGET_FILE"

echo "Updated icons in: $TARGET_FILE"
