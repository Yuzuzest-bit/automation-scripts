#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# zk_new_child_note.sh
# - 子ノートをテンプレから作成
# - 子ノートの [[wikilink]] をクリップボードにコピー
# - 末尾で子ノートを VS Code で開く
#
# Options:
#   --same-dir   : 親ノートと同じディレクトリに作成
#   --out-dir D  : 指定ディレクトリ（WorkspaceRootからの相対）に作成
#   --no-open    : 自動で開かない
# ------------------------------------------------------------

OPEN_CHILD=1  # 1=open / 0=do not open
SAME_DIR=0
OUT_DIR_ARG=""

usage() {
  cat >&2 <<'EOF'
usage:
  zk_new_child_note.sh [options] <parent-md-file> <child-title> [ROOT_DIR] [TEMPLATE_KEY]

options:
  --same-dir     Create child note in the same directory as parent
  --out-dir DIR  Create child note in DIR (relative to ROOT_DIR)
  --no-open      Do not open VS Code after creation
  --open         Open VS Code (default)
EOF
  exit 2
}

# --- 引数解析ループ ---
pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open)  OPEN_CHILD=0; shift ;;
    --open)     OPEN_CHILD=1; shift ;;
    --same-dir) SAME_DIR=1; shift ;;
    --out-dir)
      if [[ -z "${2:-}" ]]; then echo "[ERR] --out-dir requires an argument"; exit 2; fi
      OUT_DIR_ARG="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *)         pos+=("$1"); shift ;;
  esac
done

PARENT_FILE="${pos[0]:-}"
CHILD_TITLE="${pos[1]:-}"
ROOT="${pos[2]:-}"
TEMPLATE_KEY="${pos[3]:-task}"

if [[ -z "$PARENT_FILE" || -z "$CHILD_TITLE" ]]; then
  usage
fi

# --- 関数定義 ---

to_posix() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    if [[ "$p" =~ ^[A-Za-z]:[\\/] || "$p" == *\\* ]]; then
      cygpath -u "$p"
      return
    fi
  fi
  printf '%s\n' "$p"
}

clip_set() {
  local s="$1"
  if [[ -e /dev/clipboard ]]; then
    printf '%s' "$s" > /dev/clipboard
  elif command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$s" | clip.exe
  elif command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$s" | pbcopy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$s" | xclip -selection clipboard
  fi
}

get_fm_id() {
  local f="$1"
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
  s="$(printf '%s' "$s" | tr -d '\r')"
  s="${s// /_}"
  s="$(printf '%s' "$s" | sed -E 's/[^0-9A-Za-zぁ-んァ-ン一-龠ー_・-]+/_/g; s/_+/_/g; s/^_+|_+$//g')"
  [[ -n "$s" ]] || s="child"
  printf '%s\n' "$s"
}

esc_sed_repl() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

render_template() {
  local tmpl_file="$1"
  local out_file="$2"

  local ID_ESC PARENT_ESC TODAY_ESC NOW_ESC CHILD_BASE_ESC TITLE_ESC
  ID_ESC="$(esc_sed_repl "$CHILD_ID")"
  PARENT_ESC="$(esc_sed_repl "$PARENT_ID")"
  TODAY_ESC="$(esc_sed_repl "$TODAY_YMD")"
  NOW_ESC="$(esc_sed_repl "$NOW")"
  CHILD_BASE_ESC="$(esc_sed_repl "$CHILD_BASE")"
  TITLE_ESC="$(esc_sed_repl "$CHILD_TITLE")"

  tr -d '\r' < "$tmpl_file" | sed \
    -e "s|{{ID}}|${ID_ESC}|g" \
    -e "s|{{PARENT}}|${PARENT_ESC}|g" \
    -e "s|{{TODAY}}|${TODAY_ESC}|g" \
    -e "s|{{NOW}}|${NOW_ESC}|g" \
    -e "s|{{CHILD_BASE}}|${CHILD_BASE_ESC}|g" \
    -e "s|{{TITLE}}|${TITLE_ESC}|g" \
    > "$out_file"
}

# --- メイン処理 ---

# 1. パス正規化
PARENT_FILE="$(to_posix "$PARENT_FILE")"
if [[ ! -f "$PARENT_FILE" ]]; then
  echo "[ERR] not found: $PARENT_FILE" >&2; exit 2
fi

# ROOT設定
if [[ -z "$ROOT" ]]; then
  ROOT="$(cd "$(dirname "$PARENT_FILE")" && pwd)"
else
  ROOT="$(to_posix "$ROOT")"
fi

# 2. 出力ディレクトリ(OUTPUT_DIR)の決定
if [[ -n "$OUT_DIR_ARG" ]]; then
  OUTPUT_DIR="${ROOT}/${OUT_DIR_ARG}"
elif [[ "$SAME_DIR" -eq 1 ]]; then
  OUTPUT_DIR="$(dirname "$PARENT_FILE")"
else
  OUTPUT_DIR="${ROOT}"
fi
mkdir -p "$OUTPUT_DIR"

# 3. ID取得 & 変数生成
PARENT_ID="$(get_fm_id "$PARENT_FILE")"
if [[ -z "$PARENT_ID" ]]; then
  echo "[ERR] parent has no id: $PARENT_FILE" >&2; exit 1
fi

TODAY_YMD="$(date '+%Y-%m-%d')"
NOW="$(date '+%Y-%m-%d %H:%M')"
BASE="$(slugify "$CHILD_TITLE")"
CHILD_BASE="${TODAY_YMD}_${BASE}"
CHILD_PATH="${OUTPUT_DIR}/${CHILD_BASE}.md"
CHILD_ID="$(date '+%Y%m%d')-${CHILD_BASE}"

if [[ -e "$CHILD_PATH" ]]; then
  echo "[ERR] already exists: $CHILD_PATH" >&2; exit 1
fi

# 4. テンプレート処理
TEMPL_DIR="${ROOT}/templates"
TEMPL_FILE="${TEMPL_DIR}/child_${TEMPLATE_KEY}.md"

if [[ ! -f "$TEMPL_FILE" ]]; then
  echo "[ERR] template not found: $TEMPL_FILE" >&2
  exit 1
fi

render_template "$TEMPL_FILE" "$CHILD_PATH"

echo "[INFO] created    : $CHILD_PATH"
echo "[INFO] parent id  : $PARENT_ID"

# 5. Wikilinkをクリップボードへコピー
WIKILINK="[[${CHILD_BASE}]]"
clip_set "$WIKILINK" || true
echo "[INFO] Copied to clipboard: $WIKILINK"

# 6. VS Codeで開く
if [[ "$OPEN_CHILD" -eq 1 ]]; then
  if command -v code >/dev/null 2>&1; then
    code -r "$CHILD_PATH" >/dev/null 2>&1 || true
  fi
else
  echo "[INFO] --no-open: skip opening in VS Code"
fi
