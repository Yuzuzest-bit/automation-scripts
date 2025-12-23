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
cleanup() { rm -f "$TEMP_FILE"; }
trap cleanup EXIT

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

# Obsidian の [[note#heading]] / [[note#^block]] の "#以降" を落としてファイル名にする
normalize_link_to_filename() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"  # ltrim
  raw="${raw%"${raw##*[![:space:]]}"}"  # rtrim

  # 見出し/ブロック参照を除去
  local base="${raw%%#*}"

  # 念のため空なら空返し
  if [[ -z "$base" ]]; then
    printf '%s' ""
    return
  fi

  # 拡張子補完（.md 以外を使わない前提ならこれでOK）
  if [[ "$base" != *.md ]]; then
    printf '%s' "${base}.md"
  else
    printf '%s' "$base"
  fi
}

# closed 判定は「frontmatter(--- ... ---)の中だけ」を見る（行数制限なし）
has_closed_in_frontmatter() {
  local file="$1"
  awk '
    BEGIN { fm=0 }                          # fm: frontmatter中かどうか
    NR==1 && $0=="---" { fm=1; next }       # 先頭が --- ならfrontmatter開始
    fm==1 && $0=="---" { exit 1 }           # 2つ目の --- でfrontmatter終了（見つからなければNG）
    fm==1 && $0 ~ /^closed:[[:space:]]*.+/ { exit 0 }  # found
    END { exit 1 }                          # frontmatter無し/未検出
  ' "$file"
}

while IFS= read -r line; do
  # [[...]] を含む行だけ処理（最初の [[ を対象）
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    LINK_TARGET_RAW="${BASH_REMATCH[1]}"
    FILENAME="$(normalize_link_to_filename "$LINK_TARGET_RAW")"

    # リンク先状態判定
    STATUS_ICON="$ICON_ERROR"
    if [[ -n "$FILENAME" && -f "$FILENAME" ]]; then
      if has_closed_in_frontmatter "$FILENAME"; then
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
trap - EXIT
echo "Updated icons in: $PARENT_DIR/$BASE_NAME"
