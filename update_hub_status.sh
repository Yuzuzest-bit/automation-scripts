#!/usr/bin/env bash
set -euo pipefail

HUB_FILE="${1:-}"

# 表示アイコン
ICON_OK="✅ "
ICON_OPEN="📖 "   # +件数
ICON_ERROR="⚠️ "
ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "

if [[ -z "$HUB_FILE" ]]; then
  echo "usage: $0 <hub.md>" >&2
  exit 2
fi
if [[ ! -f "$HUB_FILE" ]]; then
  echo "Error: File not found: $HUB_FILE" >&2
  exit 1
fi

# HUBのある場所で相対参照できるように
ROOT_DIR="$(cd "$(dirname "$HUB_FILE")" && pwd -P)"
BASE_NAME="$(basename "$HUB_FILE")"
cd "$ROOT_DIR"

tmp="$(mktemp)"

# ------------------------------------------------------------
# MOCのNowセクションにあるリンクだけ抜き出す
# - "## Now" ～ 次の "## Current/Recent/Past" まで
extract_now_links() {
  local mocfile="$1"

  # Now区間を抜き出す → CR(\r)除去 → [[target]] だけ抽出
  awk '
    BEGIN{in=0}
    $0 ~ /^#+[[:space:]]+Now/ {in=1; next}  # Now（...）やNow:でもOK
    $0 ~ /^#+[[:space:]]+(Current|Recent|Past)/ {in=0}
    in==1 {print}
  ' "$mocfile" \
  | tr -d '\r' \
  | grep -oE '\[\[[^]|#]+' \
  | sed 's/^\[\[//'
}

# ノートの状態判定（あなたの既存ルールに合わせる）
is_closed() {
  local f="$1"
  head -n 20 "$f" | grep -qE '^closed:[[:space:]]*.+' 2>/dev/null
}
has_focus() { grep -qi -m1 '@focus' "$1" 2>/dev/null; }
has_await() { grep -qi -m1 '@awaiting' "$1" 2>/dev/null; }

# MOC1つの状態を集計して、HUBに付けるprefix文字列を返す
summarize_moc_now() {
  local mocfile="$1"

  # MOC自体が無い
  [[ -f "$mocfile" ]] || { printf '%s' "$ICON_ERROR"; return; }

  local open=0 focus=0 await=0 missing=0

  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    local f="$target"
    [[ "$f" == *.md ]] || f="${f}.md"

    if [[ ! -f "$f" ]]; then
      missing=$((missing+1))
      continue
    fi

    # open/closed
    if ! is_closed "$f"; then
      open=$((open+1))
    fi

    # mark（🎯優先は “見せ方” の話なので、ここでは件数として両方カウント）
    if has_focus "$f"; then
      focus=$((focus+1))
    elif has_await "$f"; then
      await=$((await+1))
    fi
  done < <(extract_now_links "$mocfile")

  local s=""
  if (( missing > 0 )); then
    s+="${ICON_ERROR}"
  elif (( open > 0 )); then
    s+="${ICON_OPEN}${open} "
  else
    s+="${ICON_OK}"
  fi

  (( focus > 0 )) && s+="${ICON_FOCUS}"
  (( await > 0 )) && s+="${ICON_AWAIT}"

  printf '%s' "$s"
}

# 既存の集計prefixを剥がす（HUB行の「リンク手前」だけ軽く掃除）
strip_summary_prefix() {
  local s="$1"
  # よく出る文字（✅ 📖 ⚠️ 🎯 ⏳ と数字）を雑に落とす
  s="$(printf '%s' "$s" | sed -E 's/[0-9]+[[:space:]]*//g')"
  s="${s//${ICON_OK}/}"
  s="${s//${ICON_OPEN}/}"
  s="${s//${ICON_ERROR}/}"
  s="${s//${ICON_FOCUS}/}"
  s="${s//${ICON_AWAIT}/}"
  printf '%s' "$s"
}

while IFS= read -r line; do
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    local_target="${BASH_REMATCH[1]}"
    mocfile="$local_target"
    [[ "$mocfile" == *.md ]] || mocfile="${mocfile}.md"

    summary="$(summarize_moc_now "$mocfile")"

    # 先頭のリスト記号やインデントは残して、リンク直前に summary を挿入
    if [[ "$line" =~ ^([[:space:]]*[-*+][[:space:]]*)(.*)(\[\[[^]]+\]\].*)$ ]]; then
      marker="${BASH_REMATCH[1]}"
      before="${BASH_REMATCH[2]}"
      rest="${BASH_REMATCH[3]}"
      before="$(strip_summary_prefix "$before")"
      printf '%s%s%s%s\n' "$marker" "$before" "$summary" "$rest" >> "$tmp"
    else
      # リストじゃない行（念のため）
      prefix="${line%%\[\[*}"
      rest="${line#"$prefix"}"
      prefix="$(strip_summary_prefix "$prefix")"
      printf '%s%s%s\n' "$prefix" "$summary" "$rest" >> "$tmp"
    fi
  else
    printf '%s\n' "$line" >> "$tmp"
  fi
done < "$BASE_NAME"

mv "$tmp" "$BASE_NAME"
echo "Updated HUB status: $ROOT_DIR/$BASE_NAME"
