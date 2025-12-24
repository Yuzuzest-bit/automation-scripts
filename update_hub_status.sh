#!/usr/bin/env bash
set -euo pipefail

HUB_FILE="${1:-}"
ROOT="${2:-$PWD}"   # MOC探索ルート（省略時はPWD）

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

# HUBの場所へ（相対参照を安定）
HUB_DIR="$(cd "$(dirname "$HUB_FILE")" && pwd -P)"
HUB_BASE="$(basename "$HUB_FILE")"
cd "$HUB_DIR"

# MOC名→実ファイルの索引を作る（HUBからの相対パス問題を回避）
declare -A MOC_MAP
while IFS= read -r f; do
  base="$(basename "$f" .md)"
  MOC_MAP["$base"]="$f"
done < <(find "$ROOT" -type f -name "MOC_*.md" 2>/dev/null)

strip_prefix() {
  local s="$1"
  # 先頭付近に付いてしまう要約アイコンをざっくり除去
  s="${s//${ICON_OK}/}"
  s="${s//${ICON_OPEN}/}"
  s="${s//${ICON_ERROR}/}"
  s="${s//${ICON_FOCUS}/}"
  s="${s//${ICON_AWAIT}/}"
  # 「📖 12 」みたいな数字を落とす
  s="$(printf '%s' "$s" | sed -E 's/[0-9]+[[:space:]]*//g')"
  printf '%s' "$s"
}

summarize_moc() {
  local moc_base="$1"
  local moc_path="${MOC_MAP[$moc_base]:-}"

  [[ -n "$moc_path" && -f "$moc_path" ]] || { printf '%s' "$ICON_ERROR"; return; }

  # Nowブロック抽出（CRLF対策で \r を削る）
  now_block="$(awk '
    BEGIN{in=0}
    /<!--NOW:BEGIN-->/{in=1; next}
    /<!--NOW:END-->/{in=0}
    in==1{print}
  ' "$moc_path" | tr -d '\r')"

  # マーカーが無い/空なら “未設定” として⚠️（静かに✅にしない）
  if [[ -z "$now_block" ]]; then
    printf '%s' "$ICON_ERROR"
    return
  fi

  open_cnt="$(printf '%s\n' "$now_block" | grep -o "📖" | wc -l | tr -d ' ')"
  err_cnt="$(printf '%s\n' "$now_block" | grep -o "⚠️" | wc -l | tr -d ' ')"
  focus_cnt="$(printf '%s\n' "$now_block" | grep -o "🎯" | wc -l | tr -d ' ')"
  await_cnt="$(printf '%s\n' "$now_block" | grep -o "⏳" | wc -l | tr -d ' ')"

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
  if [[ "$line" =~ \[\[([^]|]+)(\|[^]]+)?\]\] ]]; then
    target="${BASH_REMATCH[1]}"
    # HUBがMOCリンク集である前提：MOC_* だけ集計
    if [[ "$target" == MOC_* ]]; then
      summary="$(summarize_moc "$target")"

      # 箇条書きならマーカー部分を残してリンク直前に差し込む
      if [[ "$line" =~ ^([[:space:]]*[-*+][[:space:]]*)(.*)(\[\[[^]]+\]\].*)$ ]]; then
        marker="${BASH_REMATCH[1]}"
        before="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[3]}"
        before="$(strip_prefix "$before")"
        printf '%s%s%s%s\n' "$marker" "$before" "$summary" "$rest" >> "$tmp"
      else
        prefix="${line%%\[\[*}"
        rest="${line#"$prefix"}"
        prefix="$(strip_prefix "$prefix")"
        printf '%s%s%s\n' "$prefix" "$summary" "$rest" >> "$tmp"
      fi
      continue
    fi
  fi
  printf '%s\n' "$line" >> "$tmp"
done < "$HUB_BASE"

mv "$tmp" "$HUB_BASE"
echo "Updated HUB: $HUB_DIR/$HUB_BASE"
