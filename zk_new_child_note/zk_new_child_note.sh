#!/usr/bin/env bash
set -euo pipefail
# 文字コードをUTF-8に固定（日本語処理用）
export LANG="ja_JP.UTF-8"

# ------------------------------------------------------------
# zk_create_and_link.sh
# Git Bash on Windows Optimized
# ------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
usage:
  zk_create_and_link.sh <parent-md-file> <child-title> [ROOT_DIR] [TEMPLATE_KEY]
EOF
  exit 2
}

pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    *)         pos+=("$1") ;;
  esac
  shift
done

PARENT_FILE="${pos[0]:-}"
CHILD_TITLE="${pos[1]:-}"
ROOT="${pos[2]:-}"
TEMPLATE_KEY="${pos[3]:-task}"

if [[ -z "$PARENT_FILE" || -z "$CHILD_TITLE" ]]; then
  usage
fi

# Windowsパス(C:\...)をGit Bashパス(/c/...)に変換する関数
to_posix() {
  local p="$1"
  # cygpathが存在し、かつパスがWindows形式の場合
  if command -v cygpath >/dev/null 2>&1; then
    if [[ "$p" =~ ^[A-Za-z]:[\\/] || "$p" == *\\* ]]; then
      cygpath -u "$p"
      return
    fi
  fi
  printf '%s\n' "$p"
}

# クリップボードへ送る関数 (Git Bash /dev/clipboard 対応)
clip_set() {
  local s="$1"
  # Git Bashでは /dev/clipboard を使うのが最も文字化けしにくい
  if [[ -e /dev/clipboard ]]; then
    printf '%s' "$s" > /dev/clipboard
  elif command -v clip.exe >/dev/null 2>&1; then
    # /dev/clipboardがない場合はclip.exe (文字化けリスクあり)
    printf '%s' "$s" | clip.exe
  elif command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$s" | pbcopy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$s" | xclip -selection clipboard
  fi
}

get_fm_id() {
  local f="$1"
  # ファイル読み込み時に \r を削除してからawkに渡す
  tr -d '\r' < "$f" | awk '
  BEGIN{ inFM=0; fmDone=0; nonHead=0 }
  {
    if (fmDone==0 && inFM==0) {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 !~ /^[[:space:]]*---[[:space:]]*$/) nonHead=1
    }
    if ($0 ~ /^[[:space:]]*---[[:space:]]*$/) {
      if (inFM==0 && fmDone==0) { inFM=1; next }
      else if (inFM==1 && fmDone==0) { inFM=0; fmDone=1; exit }
    }
    if (inFM==1 && $0 ~ /^[[:space:]]*id:[[:space:]]*/) {
      line=$0
      sub(/^[[:space:]]*id:[[:space:]]*/, "", line)
      gsub(/^[ "\x27`]+|[ "\x27`]+$/, "", line)
      print line
      exit
    }
  }'
}

slugify() {
  local s="$1"
  # Windowsの改行コード除去
  s="$(printf '%s' "$s" | tr -d '\r')"
  s="${s// /_}"
  # 日本語・英数字・特定の記号以外をアンダースコアに
  s="$(printf '%s' "$s" | sed -E 's/[^0-9A-Za-zぁ-んァ-ン一-龠ー_・-]+/_/g; s/_+/_/g; s/^_+|_+$//g')"
  [[ -n "$s" ]] || s="child"
  printf '%s\n' "$s"
}

esc_sed_repl() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

render_template_to_stdout() {
  local tmpl_file="$1"

  local ID_ESC PARENT_ESC LINK_TARGET_ESC TODAY_ESC NOW_ESC CHILD_BASE_ESC TITLE_ESC
  ID_ESC="$(esc_sed_repl "$CHILD_ID")"
  PARENT_ESC="$(esc_sed_repl "$PARENT_ID")"
  LINK_TARGET_ESC="$(esc_sed_repl "$LINK_TARGET")"
  TODAY_ESC="$(esc_sed_repl "$TODAY_YMD")"
  NOW_ESC="$(esc_sed_repl "$NOW")"
  CHILD_BASE_ESC="$(esc_sed_repl "$CHILD_BASE")"
  TITLE_ESC="$(esc_sed_repl "$CHILD_TITLE")"

  # テンプレート読み込み時も \r を除去
  tr -d '\r' < "$tmpl_file" | sed \
    -e "s|{{ID}}|${ID_ESC}|g" \
    -e "s|{{PARENT}}|${PARENT_ESC}|g" \
    -e "s|{{LINK_TARGET}}|${LINK_TARGET_ESC}|g" \
    -e "s|{{TODAY}}|${TODAY_ESC}|g" \
    -e "s|{{NOW}}|${NOW_ESC}|g" \
    -e "s|{{CHILD_BASE}}|${CHILD_BASE_ESC}|g" \
    -e "s|{{TITLE}}|${TITLE_ESC}|g"
}

# --- メイン処理 ---

# 1. パスの正規化 (Git Bash形式へ)
PARENT_FILE="$(to_posix "$PARENT_FILE")"

if [[ ! -f "$PARENT_FILE" ]]; then
  echo "[ERR] not found: $PARENT_FILE" >&2
  exit 2
fi

if [[ -z "$ROOT" ]]; then
  ROOT="$(cd "$(dirname "$PARENT_FILE")" && pwd)"
else
  ROOT="$(to_posix "$ROOT")"
fi

# 2. 変数生成
PARENT_ID="$(get_fm_id "$PARENT_FILE")"
if [[ -z "$PARENT_ID" ]]; then
  echo "[ERR] parent has no id: $PARENT_FILE" >&2
  exit 1
fi

TODAY_YMD="$(date '+%Y-%m-%d')"
NOW="$(date '+%Y-%m-%d %H:%M')"
BASE="$(slugify "$CHILD_TITLE")"
CHILD_BASE="${TODAY_YMD}_${BASE}"
CHILD_ID="$(date '+%Y%m%d')-${CHILD_BASE}"
LINK_TARGET="${PARENT_ID#*-}"

NEW_FILE_PATH="${ROOT}/${CHILD_BASE}.md"

# 3. チェックと作成
if [[ -f "$NEW_FILE_PATH" ]]; then
  echo "[ERR] file already exists: $NEW_FILE_PATH" >&2
  exit 1
fi

TEMPL_DIR="${ROOT}/templates"
TEMPL_FILE="${TEMPL_DIR}/child_${TEMPLATE_KEY}.md"

if [[ ! -f "$TEMPL_FILE" ]]; then
  echo "[ERR] template not found: $TEMPL_FILE" >&2
  exit 1
fi

# ファイル作成
render_template_to_stdout "$TEMPL_FILE" > "$NEW_FILE_PATH"

# Wikilinkコピー
WIKILINK="[[${CHILD_BASE}]]"
clip_set "$WIKILINK"

echo "[SUCCESS] Created: $NEW_FILE_PATH"
echo "[INFO] Wikilink $WIKILINK has been copied to clipboard."
