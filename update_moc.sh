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

# link target を同一フォルダ内の md ファイル名に正規化
# - 前後空白除去
# - #以降（見出し/ブロック参照）除去
# - .md 補完
# - "/" を含む（パス指定）場合は同一フォルダ縛りでは解決不能 → 空を返す
normalize_link_to_local_mdname() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"  # ltrim
  raw="${raw%"${raw##*[![:space:]]}"}"  # rtrim
  raw="${raw%%#*}"                      # drop heading/block

  # パス指定は同一フォルダ縛りでは扱わない
  if [[ "$raw" == */* ]]; then
    printf '%s' ""
    return
  fi

  if [[ -z "$raw" ]]; then
    printf '%s' ""
    return
  fi

  if [[ "$raw" != *.md ]]; then
    printf '%s' "${raw}.md"
  else
    printf '%s' "$raw"
  fi
}

# closed 判定：frontmatter(--- ... ---) 内だけ見る / CRLF & BOM 対策
has_closed_in_frontmatter() {
  local file="$1"
  awk '
    BEGIN { fm=0; started=0 }
    {
      sub(/\r$/, "", $0)                      # CRLF対策
      if (NR==1) sub(/^\xef\xbb\xbf/, "", $0) # BOM対策
    }
    started==0 && $0=="---" { fm=1; started=1; next }
    fm==1 && $0=="---" { exit 1 }             # 終端までに closed が無ければ false
    fm==1 && $0 ~ /^closed:[[:space:]]*.+/ { exit 0 }
    END { exit 1 }
  ' "$file"
}

while IFS= read -r line; do
  # [[...]] を含む行だけ処理（最初の [[ を対象）
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    LINK_TARGET_RAW="${BASH_REMATCH[1]}"

    FILENAME="$(normalize_link_to_local_mdname "$LINK_TARGET_RAW")"

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
    printf '%s\n' "${prefix}${STATUS_ICON}${rest}" >> "$TEMP_FILE"
  else
    printf '%s\n' "$line" >> "$TEMP_FILE"
  fi
done < "$BASE_NAME"

mv "$TEMP_FILE" "$BASE_NAME"
trap - EXIT
echo "Updated icons in: $PARENT_DIR/$BASE_NAME"
