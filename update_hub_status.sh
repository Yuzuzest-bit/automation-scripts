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
  s="${s//${ICON_OK}/}"
  s="${s//${ICON_ERROR}/}"
  s="${s//${ICON_FOCUS}/}"
  s="${s//${ICON_AWAIT}/}"
  # 「📖 12 」を落とす
  s="$(printf '%s' "$s" | sed -E 's/📖[[:space:]]*[0-9]+[[:space:]]*//g')"
  s="${s//${ICON_OPEN}/}"
  printf '%s' "$s"
}

# リンクターゲット → ファイル解決
# 1) HUBからの相対
# 2) ROOT配下をfind（同名が複数あったら先頭を使う）
resolve_note_file() {
  local target="$1"
  local f="$target"
  [[ "$f" == *.md ]] || f="${f}.md"

  # 相対パス（HUBの場所基準）
  if [[ -f "$f" ]]; then
    printf '%s\n' "$f"
    return
  fi

  # ROOT配下を検索（basename一致）
  local base
  base="$(basename "$f")"
  local hit
  hit="$(find "$ROOT" -type f -name "$base" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$hit" ]]; then
    printf '%s\n' "$hit"
    return
  fi

  printf '%s\n' ""
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

  local open_cnt err_cnt focus_cnt await_cnt
  open_cnt="$(printf '%s\n' "$block" | grep -o "📖" | wc -l | tr -d ' ')"
  err_cnt="$(printf '%s\n' "$block" | grep -o "⚠️" | wc -l | tr -d ' ')"
  focus_cnt="$(printf '%s\n' "$block" | grep -o "🎯" | wc -l | tr -d ' ')"
  await_cnt="$(printf '%s\n' "$block" | grep -o "⏳" | wc -l | tr -d ' ')"

  local s=""
  if (( err_cnt > 0 )); then
    s+="${ICON_ERROR}"
  elif (( open_cnt > 0 )); then
    s+="${ICON_OPEN}${open_cnt} "
  else
    s+="${ICON_OK}"
  fi
  (( focus_cnt > 0 )) && s+="${ICON_FOCUS}"
  (( await_cnt > 0 )) && s+="${ICON_AWAIT}"

  printf '%s' "$s"
}

tmp="$(mktemp)"

while IFS= read -r line; do
  # 行内の最初の [[...]] を対象（HUBは通常1行1リンク想定）
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    target="${BASH_REMATCH[1]}"
    note_path="$(resolve_note_file "$target")"

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
