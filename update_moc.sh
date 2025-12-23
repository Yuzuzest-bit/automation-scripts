#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="${1:-}"

# アイコン定義（末尾の半角スペース込みが重要）
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "

if [[ -z "$TARGET_FILE" ]]; then
  echo "usage: $0 <target.md>" >&2
  exit 2
fi

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "Error: File not found: $TARGET_FILE" >&2
  exit 1
fi

# 相対パスでも壊れないように、親ディレクトリへ移動したあと basename で読む
PARENT_DIR="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
BASE_NAME="$(basename "$TARGET_FILE")"

cd "$PARENT_DIR"

TEMP_FILE="$(mktemp)"

# 直前アイコンを「全部」剥がす（過去に2重3重に付いてしまった分も掃除）
strip_status_icons_before_link() {
  local s="$1"
  while :; do
    case "$s" in
      *"$ICON_CLOSED") s="${s%$ICON_CLOSED}" ;;
      *"$ICON_OPEN")   s="${s%$ICON_OPEN}" ;;
      *"$ICON_ERROR")  s="${s%$ICON_ERROR}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

while IFS= read -r line; do
  # [[...]] を含む行だけ処理（最初の [[ を対象）
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    LINK_TARGET="${BASH_REMATCH[1]}"

    # 拡張子補完
    if [[ "$LINK_TARGET" != *.md ]]; then
      FILENAME="${LINK_TARGET}.md"
    else
      FILENAME="$LINK_TARGET"
    fi

    # リンク先状態判定
    STATUS_ICON="$ICON_ERROR"
    if [[ -f "$FILENAME" ]]; then
      if head -n 20 "$FILENAME" | grep -qE '^closed:[[:space:]]*.+'; then
        STATUS_ICON="$ICON_CLOSED"
      else
        STATUS_ICON="$ICON_OPEN"
      fi
    fi

    # 「最初の [[ 」の手前(prefix)と、そこ以降(rest)に分割して、
    # prefix末尾の既存アイコンだけを剥がしてから、1個だけ付け直す
    prefix="${line%%\[\[*}"
    rest="${line#"$prefix"}"

    prefix="$(strip_status_icons_before_link "$prefix")"
    NEW_LINE="${prefix}${STATUS_ICON}${rest}"

    printf '%s\n' "$NEW_LINE" >> "$TEMP_FILE"
  else
    printf '%s\n' "$line" >> "$TEMP_FILE"
  fi
done < "$BASE_NAME"

mv "$TEMP_FILE" "$BASE_NAME"
echo "Updated icons in: $PARENT_DIR/$BASE_NAME"
