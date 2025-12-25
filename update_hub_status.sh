#!/usr/bin/env bash
set -euo pipefail

HUB_FILE="${1:-}"
ROOT="${2:-$PWD}"   # ノート全体のルート（検索に使う）

ICON_OK="✅ "
ICON_OPEN="📖 "    # +件数
ICON_ERROR="⚠️ "
ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "

if [[ -z "$HUB_FILE" ]]; then
  echo "usage: $0 <hub.md> [ROOT]" >&2
  exit 2
fi
[[ -f "$HUB_FILE" ]] || { echo "Error: File not found: $HUB_FILE" >&2; exit 1; }

# HUBの場所へ（相対パス安定）
HUB_DIR="$(cd "$(dirname "$HUB_FILE")" && pwd -P)"
HUB_BASE="$(basename "$HUB_FILE")"
cd "$HUB_DIR"

# Windowsパス → POSIX
to_posix() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    if [[ "$p" =~ ^[A-Za-z]:[\\/]|\\ ]]; then
      cygpath -u "$p"
      return
    fi
  fi
  printf '%s\n' "$p"
}

ROOT="$(to_posix "$ROOT")"

strip_summary_prefix() {
  local s="$1"
  # 既存の要約を剥がす（雑でOK）
  s="${s//${ICON_OK}/}"
  s="${s//${ICON_ERROR}/}"
  s="${s//${ICON_FOCUS}/}"
  s="${s//${ICON_AWAIT}/}"
  s="$(printf '%s' "$s" | sed -E 's/📖[[:space:]]*[0-9]+[[:space:]]*//g')"
  s="${s//${ICON_OPEN}/}"
  printf '%s' "$s"
}

# ----------------------------
# 解決パスのキャッシュ（find連発を避ける）
declare -A RESOLVE_CACHE

# target → 実ファイル解決（ROOT配下も検索）
# base_dir（呼び出し元ファイルのディレクトリ）も考慮
resolve_note_file_from() {
  local target="$1"
  local base_dir="$2"

  # Obsidian/Logseq っぽい #heading を落とす
  target="${target%%#*}"

  local f="$target"
  [[ "$f" == *.md ]] || f="${f}.md"

  # 1) パス付きならそのまま解決（base_dir基準）
  if [[ "$f" == */* || "$f" == *\\* ]]; then
    local fp
    fp="$(to_posix "$f")"
    if [[ -f "$fp" ]]; then printf '%s\n' "$fp"; return; fi
    if [[ -f "$base_dir/$fp" ]]; then printf '%s\n' "$base_dir/$fp"; return; fi
  fi

  # 2) base_dir 内
  if [[ -f "$base_dir/$f" ]]; then
    printf '%s\n' "$base_dir/$f"
    return
  fi

  # 3) HUBからの相対（HUB_DIR）
  if [[ -f "$f" ]]; then
    printf '%s\n' "$f"
    return
  fi

  # 4) ROOT配下をfind（basename一致、キャッシュ）
  local base
  base="$(basename "$f")"
  if [[ -n "${RESOLVE_CACHE[$base]+x}" ]]; then
    [[ "${RESOLVE_CACHE[$base]}" == "-" ]] && printf '%s\n' "" || printf '%s\n' "${RESOLVE_CACHE[$base]}"
    return
  fi

  local hit
  hit="$(find "$ROOT" -type f -name "$base" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$hit" ]]; then
    RESOLVE_CACHE["$base"]="$hit"
    printf '%s\n' "$hit"
  else
    RESOLVE_CACHE["$base"]="-"
    printf '%s\n' ""
  fi
}

# MOC判定：NOWマーカーがあるか
is_moc_file() {
  local f="$1"
  grep -q '<!--NOW:BEGIN-->' "$f" 2>/dev/null
}

# NOWブロック抽出（CRLF対策で \r 除去）
extract_now_block() {
  local f="$1"
  awk '
    BEGIN{inNow=0}
    /<!--NOW:BEGIN-->/{inNow=1; next}
    /<!--NOW:END-->/{inNow=0; next}
    inNow==1{print}
  ' "$f" | tr -d '\r'
}

# NOWブロックから [[target]] を全部抜く（|alias もOK）
extract_links_from_block() {
  # stdin -> targets
  sed -E 's/\r$//' \
  | grep -oE '\[\[[^]]+\]\]' \
  | sed -E 's/^\[\[//; s/\]\]$//' \
  | sed -E 's/\|.*$//'
}

is_closed_file() {
  local f="$1"
  # 先頭40行以内に closed: があればクローズ扱い
  head -n 40 "$f" | grep -qE '^closed:[[:space:]]*.+' 2>/dev/null
}

has_focus() { grep -qi -m1 '@focus' "$1" 2>/dev/null; }
has_await() { grep -qi -m1 '@awaiting' "$1" 2>/dev/null; }

summarize_moc_now() {
  local mocfile="$1"

  [[ -f "$mocfile" ]] || { printf '%s' "$ICON_ERROR"; return; }
  is_moc_file "$mocfile" || { printf '%s' ""; return; }  # MOCじゃなければ何も付けない

  local block
  block="$(extract_now_block "$mocfile")"

  # マーカーあるのに空なら「未設定」扱いで⚠️（誤って✅にしない）
  if [[ -z "$block" ]]; then
    printf '%s' "$ICON_ERROR"
    return
  fi

  local moc_dir
  moc_dir="$(cd "$(dirname "$mocfile")" && pwd -P)"

  local open_cnt=0 err_cnt=0 focus_cnt=0 await_cnt=0

  while IFS= read -r target; do
    [[ -n "$target" ]] || continue

    local fp
    fp="$(resolve_note_file_from "$target" "$moc_dir")"
    if [[ -z "$fp" || ! -f "$fp" ]]; then
      err_cnt=$((err_cnt+1))
      continue
    fi

    if ! is_closed_file "$fp"; then
      open_cnt=$((open_cnt+1))
    fi

    # 🎯優先（個別行と同じ思想）
    if has_focus "$fp"; then
      focus_cnt=$((focus_cnt+1))
    elif has_await "$fp"; then
      await_cnt=$((await_cnt+1))
    fi
  done < <(printf '%s\n' "$block" | extract_links_from_block)

  local s=""
  if (( err_cnt > 0 )); then
    s+="${ICON_ERROR}"
  elif (( open_cnt > 0 )); then
    s+="${ICON_OPEN}${open_cnt} "
  else
    s+="${ICON_OK}"
  fi

  # 要約は 🎯 優先（両方出したければここを変更）
  if (( focus_cnt > 0 )); then
    s+="${ICON_FOCUS}"
  elif (( await_cnt > 0 )); then
    s+="${ICON_AWAIT}"
  fi

  printf '%s' "$s"
}

# ----------------------------
tmp="$(mktemp)"

while IFS= read -r line; do
  # 行内の最初の [[...]] を対象（HUBは通常1行1リンク想定）
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    target="${BASH_REMATCH[1]}"

    # HUBリンク先の実ファイル解決（HUB基準 + ROOT）
    note_path="$(resolve_note_file_from "$target" "$HUB_DIR")"

    if [[ -n "$note_path" ]]; then
      summary="$(summarize_moc_now "$note_path")"
      if [[ -n "$summary" ]]; then
        # 箇条書きならリスト記号を保って、リンク直前にsummaryを差し込む
        if [[ "$line" =~ ^([[:space:]]*[-*+][[:space:]]*)(.*)(\[\[[^]]+\]\].*)$ ]]; then
          marker="${BASH_REMATCH[1]}"
          before="${BASH_REMATCH[2]}"
          rest="${BASH_REMATCH[3]}"
          before="$(strip_summary_prefix "$before")"
          printf '%s%s%s%s\n' "$marker" "$before" "$summary" "$rest" >> "$tmp"
          continue
        else
          prefix="${line%%\[\[*}"
          rest="${line#"$prefix"}"
          prefix="$(strip_summary_prefix "$prefix")"
          printf '%s%s%s\n' "$prefix" "$summary" "$rest" >> "$tmp"
          continue
        fi
      fi
    fi
  fi

  printf '%s\n' "$line" >> "$tmp"
done < "$HUB_BASE"

mv "$tmp" "$HUB_BASE"
echo "Updated HUB: $HUB_DIR/$HUB_BASE"
