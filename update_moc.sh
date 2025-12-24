#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="${1:-}"

# アイコン定義（末尾の半角スペース込みが重要）
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "

# 追加: Focus/Awaiting
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

# 相対パスでも壊れないように、親ディレクトリへ移動したあと basename で読む
PARENT_DIR="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
BASE_NAME="$(basename "$TARGET_FILE")"

cd "$PARENT_DIR"

TEMP_FILE="$(mktemp)"

# 直前アイコンを「全部」剥がす（過去に2重3重に付いてしまった分も掃除）
# 追加: 🎯 / ⏳ も剥がして「更新」できるようにする
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

# リンク先の本文を見て、🎯/⏳ を決める（🎯優先）
detect_mark_icon() {
  local file="$1"

  # ファイルが無いなら付けない（状態は⚠️で表現）
  [[ -f "$file" ]] || { printf ''; return; }

  # case-insensitive。最初に見つかったら十分
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

    # 追加: Focus/Awaiting 判定（🎯優先）
    MARK_ICON="$(detect_mark_icon "$FILENAME")"

    # 「最初の [[ 」の手前(prefix)と、そこ以降(rest)に分割して、
    # prefix末尾の既存アイコンだけを剥がしてから、付け直す
    prefix="${line%%\[\[*}"
    rest="${line#"$prefix"}"

    prefix="$(strip_icons_before_link "$prefix")"
    NEW_LINE="${prefix}${STATUS_ICON}${MARK_ICON}${rest}"

    printf '%s\n' "$NEW_LINE" >> "$TEMP_FILE"
  else
    printf '%s\n' "$line" >> "$TEMP_FILE"
  fi
done < "$BASE_NAME"

mv "$TEMP_FILE" "$BASE_NAME"
echo "Updated icons in: $PARENT_DIR/$BASE_NAME"
