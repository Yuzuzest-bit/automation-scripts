#!/usr/bin/env bash
# 文字化け防止
export LC_ALL=C.UTF-8
set -euo pipefail

TARGET_FILE="${1:-}"

# --- 設定 ---
# 検索の起点（Git Bash等で実行している現在のディレクトリ）
VAULT_ROOT="$(pwd -P)"

# アイコン定義
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "
ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "
ICON_BLOCK="🧱 "

if [[ -z "$TARGET_FILE" ]]; then
  echo "usage: $0 <target.md>" >&2
  exit 2
fi

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "Error: File not found: $TARGET_FILE" >&2
  exit 1
fi

PARENT_DIR="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
BASE_NAME="$(basename "$TARGET_FILE")"
TEMP_FILE="$(mktemp)"

# 既存のアイコンや (テキスト) を削除する関数
# 例: "✅ 🧱 (待機中) [[Link]]" -> "[[Link]]" に戻すため
strip_all_decorations() {
  local s="$1"
  # アイコンの除去
  for icon in "$ICON_CLOSED" "$ICON_OPEN" "$ICON_ERROR" "$ICON_FOCUS" "$ICON_AWAIT" "$ICON_BLOCK"; do
    s="${s//$icon/}"
  done
  # 末尾の "(...)" 形式のテキストを削除（必要に応じて調整）
  s=$(echo "$s" | sed -E 's/[[:space:]]*\([^)]+\)[[:space:]]*$//')
  # 前後の空白をトリム
  echo "$s" | sed -E 's/[[:space:]]+$//'
}

# フォルダを跨いでファイルを探す
resolve_file_path() {
  local target_name="$1"
  if [[ -f "$PARENT_DIR/$target_name" ]]; then
    echo "$PARENT_DIR/$target_name"
    return
  fi
  # findで見つける（1つ見つかったら即終了）
  find "$VAULT_ROOT" -maxdepth 4 -name "$target_name" -not -path "*/.*" -print -quit 2>/dev/null
}

# リンク先の詳細状態（アイコンとテキスト）を取得
get_link_details() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && { echo "$ICON_ERROR|"; return; }

  local status_icon=""
  local mark_icon=""
  local extra_info=""

  # 1. Closed 判定 (CRLF対策)
  if head -n 30 "$f_path" | tr -d '\r' | grep -qE '^closed:[[:space:]]*.+'; then
    status_icon="$ICON_CLOSED"
  else
    status_icon="$ICON_OPEN"
  fi

  # 2. @focus, @blocked, @awaiting 判定とテキスト抽出
  # 最初に見つかった行を対象にする
  local match
  match=$(grep -niE -m1 '@focus|@blocked|@awaiting' "$f_path" | tr -d '\r' || true)

  if [[ -n "$match" ]]; then
    local line_content="${match#*:}" # 行番号を除去

    if [[ "$line_content" =~ @focus ]]; then
      mark_icon="$ICON_FOCUS"
      # タグ以降の文字を抽出
      extra_info=$(echo "$line_content" | sed -E 's/.*@focus[[:space:]]*//I')
    elif [[ "$line_content" =~ @blocked ]]; then
      mark_icon="$ICON_BLOCK"
      extra_info=$(echo "$line_content" | sed -E 's/.*@blocked[[:space:]]*//I')
    elif [[ "$line_content" =~ @awaiting ]]; then
      mark_icon="$ICON_AWAIT"
      extra_info=$(echo "$line_content" | sed -E 's/.*@awaiting[[:space:]]*//I')
    fi
  fi

  # アイコンとテキストを結合して返す (textがあればカッコで括る)
  local info_str=""
  [[ -n "$extra_info" ]] && info_str="($extra_info) "

  echo "${status_icon}${mark_icon}|${info_str}"
}

# 処理メイン
while IFS= read -r line || [[ -n "$line" ]]; do
  # [[リンク]] を含む行を処理
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    LINK_TARGET="${BASH_REMATCH[1]}"
    [[ "$LINK_TARGET" != *.md ]] && FILENAME="${LINK_TARGET}.md" || FILENAME="$LINK_TARGET"

    # ファイル探索
    RESOLVED_PATH="$(resolve_file_path "$FILENAME")"

    # 詳細情報の取得
    DETAILS=$(get_link_details "$RESOLVED_PATH")
    ICONS="${DETAILS%|*}"
    INFO="${DETAILS#*|}"

    # 行の構築
    prefix="${line%%\[\[*}"
    rest="${line#"$prefix"}"

    # 既存の装飾を剥がす
    prefix="$(strip_all_decorations "$prefix")"

    # 新しい行を作成（アイコン + テキスト + 残りの行）
    echo "${prefix}${ICONS}${INFO}${rest}" >> "$TEMP_FILE"
  else
    echo "$line" >> "$TEMP_FILE"
  fi
done < "$TARGET_FILE"

mv "$TEMP_FILE" "$TARGET_FILE"
echo "Done: $TARGET_FILE"
