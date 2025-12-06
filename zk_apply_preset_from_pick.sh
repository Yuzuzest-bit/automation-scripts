#!/usr/bin/env bash
# zk_apply_preset_from_pick.sh <file> "<key | description | ops>" [ROOT]
# - VS Code tasks.json の pickString 文字列から ops を抽出して
#   既存の zk_tags.sh に渡す
# - 拡張なし / Pythonなし / 会社・家で同一運用のための“中継スクリプト”
set -euo pipefail
FILE="${1:-}"
RAW="${2:-}"
ROOT="${3:-$PWD}"
TAGS_SH="${ROOT}/zk_tags.sh"
if [[ -z "$FILE" || -z "$RAW" ]]; then
  echo "usage: zk_apply_preset_from_pick.sh <file> \"key | desc | ops\" [ROOT]" >&2
  exit 2
fi
if [[ ! -f "$TAGS_SH" ]]; then
  echo "zk_tags.sh not found: $TAGS_SH" >&2
  exit 2
fi
# "key | description | ops" の 3列目だけ抽出
ops_str="$(printf '%s' "$RAW" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')"
if [[ -z "$ops_str" ]]; then
  echo "Invalid preset format. Expected: key | description | ops" >&2
  exit 1
fi
# ops を配列化して適用
# shellcheck disable=SC2206
ops=($ops_str)
"$TAGS_SH" "$FILE" "${ops[@]}"
