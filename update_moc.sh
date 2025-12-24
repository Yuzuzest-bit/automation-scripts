#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="${1:-}"

# アイコン定義（末尾の半角スペース込みが重要）
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "

DEBUG="${DEBUG:-0}"  # DEBUG=1 で解決ログを stderr に出す

if [[ -z "$TARGET_FILE" ]]; then
  echo "usage: $0 <target.md>" >&2
  exit 2
fi
if [[ ! -f "$TARGET_FILE" ]]; then
  echo "Error: File not found: $TARGET_FILE" >&2
  exit 1
fi

# 親ディレクトリへ移動したあと basename で読む
PARENT_DIR="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
BASE_NAME="$(basename "$TARGET_FILE")"

cd "$PARENT_DIR"

TEMP_FILE="$(mktemp)"
cleanup() { rm -f "$TEMP_FILE"; }
trap cleanup EXIT

logd() { [[ "$DEBUG" == "1" ]] && printf '[DBG] %s\n' "$*" >&2 || true; }

# Vault root を検出（ZK_ROOT 優先、なければ .obsidian を上へ辿る）
detect_vault_root() {
  local start="$1"
  if [[ -n "${ZK_ROOT:-}" && -d "${ZK_ROOT:-}" ]]; then
    (cd "$ZK_ROOT" && pwd -P)
    return
  fi
  local d="$start"
  while :; do
    if [[ -d "$d/.obsidian" ]]; then
      (cd "$d" && pwd -P)
      return
    fi
    # ルート到達
    local parent
    parent="$(cd "$d/.." && pwd -P)"
    if [[ "$parent" == "$d" ]]; then
      (cd "$start" && pwd -P)
      return
    fi
    d="$parent"
  done
}

VAULT_ROOT="$(detect_vault_root "$PARENT_DIR")"
logd "VAULT_ROOT=$VAULT_ROOT"
logd "PARENT_DIR=$PARENT_DIR"

# 直前アイコンを「全部」剥がす
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

# link target -> "basename(.md付き)" に正規化（#以降の見出し/ブロック参照を除去）
normalize_link_to_mdname() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"  # ltrim
  raw="${raw%"${raw##*[![:space:]]}"}"  # rtrim
  raw="${raw%%#*}"                      # drop heading/block
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

# closed 判定：frontmatter(--- ... ---) 内だけ見る / CRLF 対策 / BOM 対策
has_closed_in_frontmatter() {
  local file="$1"
  awk '
    BEGIN { fm=0; started=0 }
    {
      sub(/\r$/, "", $0)                # CRLF対策
      if (NR==1) sub(/^\xef\xbb\xbf/, "", $0)  # BOM対策
    }
    started==0 && $0=="---" { fm=1; started=1; next }
    fm==1 && $0=="---" { exit 1 }
    fm==1 && $0 ~ /^closed:[[:space:]]*.+/ { exit 0 }
    END { exit 1 }
  ' "$file"
}

# Vault 内でリンク先ファイルを解決（キャッシュあり）
declare -A RESOLVE_CACHE

resolve_note_path() {
  local link_raw="$1"
  local mdname
  mdname="$(normalize_link_to_mdname "$link_raw")"
  [[ -z "$mdname" ]] && printf '%s' "" && return

  # Obsidian の [[folder/Note]] 対応：'/' を含むなら Vault root 基準
  # そのまま mdname に含まれている想定（folder/Note.md）
  local key="$mdname"
  if [[ -n "${RESOLVE_CACHE[$key]:-}" ]]; then
    printf '%s' "${RESOLVE_CACHE[$key]}"
    return
  fi

  local p=""

  if [[ "$mdname" == */* ]]; then
    # Vault root 基準で直指定
    p="$VAULT_ROOT/$mdname"
    if [[ -f "$p" ]]; then
      RESOLVE_CACHE[$key]="$p"
      printf '%s' "$p"
      return
    fi
    # 失敗なら find も試す（表記ゆれ/大文字小文字など）
    p="$(find "$VAULT_ROOT" -type f -iname "$(basename "$mdname")" -path "*/${mdname%/*}/*" -print -quit 2>/dev/null || true)"
    RESOLVE_CACHE[$key]="$p"
    printf '%s' "$p"
    return
  fi

  # 1) 同じフォルダ（いま cd 済み）
  if [[ -f "$mdname" ]]; then
    p="$PARENT_DIR/$mdname"
    RESOLVE_CACHE[$key]="$p"
    printf '%s' "$p"
    return
  fi

  # 2) Vault ルート直下
  if [[ -f "$VAULT_ROOT/$mdname" ]]; then
    p="$VAULT_ROOT/$mdname"
    RESOLVE_CACHE[$key]="$p"
    printf '%s' "$p"
    return
  fi

  # 3) Vault 全体から検索（1件だけ）
  p="$(find "$VAULT_ROOT" -type f -iname "$mdname" -print -quit 2>/dev/null || true)"
  RESOLVE_CACHE[$key]="$p"
  printf '%s' "$p"
}

while IFS= read -r line; do
  # [[...]] を含む行だけ処理（最初の [[ を対象）
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    LINK_TARGET_RAW="${BASH_REMATCH[1]}"

    NOTE_PATH="$(resolve_note_path "$LINK_TARGET_RAW")"
    logd "LINK='$LINK_TARGET_RAW' => PATH='$NOTE_PATH'"

    STATUS_ICON="$ICON_ERROR"
    if [[ -n "$NOTE_PATH" && -f "$NOTE_PATH" ]]; then
      if has_closed_in_frontmatter "$NOTE_PATH"; then
        STATUS_ICON="$ICON_CLOSED"
      else
        STATUS_ICON="$ICON_OPEN"
      fi
    fi

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
