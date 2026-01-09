#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# 指定されたFrontmatterの内容
# ------------------------------------------------------------
FM_CONTENT='---
due: 2026-01-09
closed: 2026-01-09T12:20
---'

# ------------------------------------------------------------
# 処理ロジック
# ------------------------------------------------------------

# 現在のディレクトリ以下の .md ファイルを検索
find . -type f -name "*.md" | while read -r file; do
    
    # ファイルの1行目を読み込む（ファイルが空の場合は空文字になる）
    first_line=$(head -n 1 "$file" || true)

    # 1行目が "---" でない場合のみ処理を実行
    if [[ "$first_line" != "---" ]]; then
        echo "[UPDATE] Frontmatterを追加します: $file"
        
        # 一時ファイルを作成して結合する
        # 1. Frontmatterの内容を一時ファイルに書き込む
        echo "$FM_CONTENT" > "${file}.tmp"
        # 2. 元のファイルの内容を追記する
        cat "$file" >> "${file}.tmp"
        # 3. 元のファイルを置き換える
        mv "${file}.tmp" "$file"
    else
        echo "[SKIP] すでにFrontmatterがあります: $file"
    fi

done

echo "すべての処理が完了しました。"
