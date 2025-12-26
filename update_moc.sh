#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="${1:-}"

# --- 設定 ---
# 検索の起点となるディレクトリ。
# デフォルトは実行した場所（.）ですが、特定のパス（~/Documents/Notes など）に固定も可能です。
VAULT_ROOT="$(pwd -P)"

# アイコン定義
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "
ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "

if [[ -z "$TARGET_FILE" ]]; then
  echo "usage: $0 <target.md>" >&2
  exit 2
fi

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "Error: File not found: $TARGET_FILE" >&2
  exit 1
fi

# ターゲットファイルの情報を取得
PARENT_DIR="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
BASE_NAME="$(basename "$TARGET_FILE")"
TEMP_FILE="$(mktemp)"

# アイコン除去関数
strip_icons_before_link() {
  local s="$1"
  while :; do
    case "$s" in
      *"$ICON_CLOSED") s="${s%$ICON_CLOSED}" ;;
      *"$ICON_OPEN")   s="${s%$ICON_OPEN}" ;;
      *"$ICON_ERROR")  s="${s%$ICON_ERROR}" ;;
      *"$ICON_FOCUS")  s="${s%$ICON_FOCUS}" ;;
      *"$ICON_AWAIT")  s="${s%$ICON_AWAIT}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

# リンク先のパスを解決する関数
# 1. カレントディレクトリ(PARENT_DIR)にあるか確認
# 2. なければ VAULT_ROOT 以下を検索
resolve_file_path() {
  local target_name="$1"
  
  # A. 同じフォルダにある場合（最速）
  if [[ -f "$PARENT_DIR/$target_name" ]]; then
    echo "$PARENT_DIR/$target_name"
    return
  fi

  # B. 他のフォルダにある場合（findで検索）
  # -maxdepth 5 などに制限するとさらに高速化できます
  local found
  found=$(find "$VAULT_ROOT" -name "$target_name" -print -quit 2>/dev/null)
  
  if [[ -n "$found" ]]; then
    echo "$found"
  fi
}

detect_mark_icon() {
  local file="$1"
  [[ -f "$file" ]] || { printf ''; return; }
  if grep -qi -m1 '@focus' "$file"; then
    printf '%s' "$ICON_FOCUS"
    return
  fi
  if grep -qi -m1 '@awaiting' "$file"; then
    printf '%s' "$ICON_AWAIT"
    return
  fi
  printf ''
}

# 処理開始
while IFS= read -r line; do
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    LINK_TARGET="${BASH_REMATCH[1]}"
    
    if [[ "$LINK_TARGET" != *.md ]]; then
      FILENAME="${LINK_TARGET}.md"
    else
      FILENAME="$LINK_TARGET"
    fi

    # ファイルの場所を特定
    RESOLVED_PATH="$(resolve_file_path "$FILENAME")"

    STATUS_ICON="$ICON_ERROR"
    MARK_ICON=""

    if [[ -n "$RESOLVED_PATH" ]]; then
      # 状態判定
      if head -n 20 "$RESOLVED_PATH" | grep -qE '^closed:[[:space:]]*.+'; then
        STATUS_ICON="$ICON_CLOSED"
      else
        STATUS_ICON="$ICON_OPEN"
      fi
      # Focus/Awaiting 判定
      MARK_ICON="$(detect_mark_icon "$RESOLVED_PATH")"
    fi

    prefix="${line%%\[\[*}"
    rest="${line#"$prefix"}"
    prefix="$(strip_icons_before_link "$prefix")"
    
    echo "${prefix}${STATUS_ICON}${MARK_ICON}${rest}" >> "$TEMP_FILE"
  else
    echo "$line" >> "$TEMP_FILE"
  fi
done < "$TARGET_FILE"

mv "$TEMP_FILE" "$TARGET_FILE"
echo "Updated: $TARGET_FILE"
