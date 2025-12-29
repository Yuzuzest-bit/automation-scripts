#!/usr/bin/env bash
# zk_extract_minutes_flat_v1.sh
#
# TREE_VIEW.md から「🕒(minutes) が付いたノート行だけ」を抽出し、
# 階層を潰して平坦なリストにする（- のインデントを全て除去）。
#
# 安全策: 🕒 が 0件なら上書きしない（全刈り防止）
#
# Optional env:
#   OUTDIR_NAME="dashboards"
#   FIXED_FILENAME="TREE_VIEW.md"
#   MINUTES_ICON_RE="🕒|🕒️"   # 絵文字の揺れ対策（既定）
#   INDENT_UNIT=2

set -Eeuo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}"

OUTDIR_NAME="${OUTDIR_NAME:-dashboards}"
FIXED_FILENAME="${FIXED_FILENAME:-TREE_VIEW.md}"
ROOT="$(pwd -P)"
TARGET_FILE="${ROOT}/${OUTDIR_NAME}/${FIXED_FILENAME}"

MINUTES_ICON_RE="${MINUTES_ICON_RE:-🕒|🕒️}"
INDENT_UNIT="${INDENT_UNIT:-2}"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERR] not found: $TARGET_FILE" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

# まず minutes 行が存在するか数える（0件なら上書きしない）
count="$(
  awk -v re="(${MINUTES_ICON_RE})" '
    { sub(/\r$/, "", $0) }
    $0 ~ /^[ ]*- / && $0 ~ re { c++ }
    END { print c+0 }
  ' "$TARGET_FILE"
)"

if [[ "$count" =~ ^[0-9]+$ ]] && (( count == 0 )); then
  echo "[ERR] 🕒(minutes) が1件も見つかりません。TREE_VIEW.md に🕒が付いていない可能性があります。" >&2
  echo "      まず以下で確認してください:" >&2
  echo "        grep -n \"🕒\" \"$TARGET_FILE\" | head" >&2
  echo "        grep -n \"🕒️\" \"$TARGET_FILE\" | head" >&2
  exit 1
fi

# 先頭（frontmatter/見出し等）は残し、🕒行だけ抽出してインデントを潰す
awk -v re="(${MINUTES_ICON_RE})" '
  { sub(/\r$/, "", $0) }

  # 最初のツリー行が出るまで（frontmatter や見出しなど）はそのまま出す
  started_list == 0 {
    if ($0 ~ /^[ ]*- /) started_list = 1
    else { print; next }
  }

  # ツリー行：🕒 を含むものだけ、インデントを除去して出す（平坦化）
  $0 ~ /^[ ]*- / && $0 ~ re {
    line = $0
    sub(/^[ ]+/, "", line)   # 先頭のインデントを落とす
    print line
  }
' "$TARGET_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "[OK] Minutes-only (flat) extracted: $TARGET_FILE"
if command -v code >/dev/null 2>&1; then
  code -r "$TARGET_FILE"
fi
