#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# zk_new_child_note.sh
# - 子ノートをテンプレから作成 (親と同じフォルダに作成)
# - 親ノート(frontmatter直下)に [[wikilink]] を挿入
# - 末尾で子ノートを VS Code で開く
# ------------------------------------------------------------

OPEN_CHILD=1  # 1=open / 0=do not open

usage() {
  cat >&2 <<'EOF'
usage:
  zk_new_child_note.sh [--no-open|--open] <parent-md-file> <child-title> [ROOT_DIR] [TEMPLATE_KEY]

options:
  --no-open   子ノートを作成しても VS Code で開かない
  --open      明示的に開く（デフォルト）
EOF
  exit 2
}

# env で上書き
if [[ -n "${ZK_NEW_CHILD_OPEN:-}" ]]; then
  case "${ZK_NEW_CHILD_OPEN}" in
    0|false|FALSE|no|NO) OPEN_CHILD=0 ;;
    1|true|TRUE|yes|YES) OPEN_CHILD=1 ;;
  esac
fi

pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open) OPEN_CHILD=0 ;;
    --open)    OPEN_CHILD=1 ;;
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
  # Git Bash用に /dev/clipboard を優先 (文字化け防止)
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
  # \r 除去を追加
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
  s="$(printf '%s' "$s" | tr -d '\r')" # Windows改行除去
  s="${s// /_}"
  s="$(printf '%s' "$s" | sed -E 's/[^0-9A-Za-zぁ-んァ-ン一-龠ー_・-]+/_/g; s/_+/_/g; s/^_+|_+$//g')"
  [[ -n "$s" ]] || s="child"
  printf '%s\n' "$s"
}

insert_link_below_frontmatter() {
  local parent="$1"
  local child_base="$2"
  local link="[[${child_base}]]"

  # 親ファイル検索時に \r を考慮してgrep（簡易チェック）
  if grep -Fq "$link" "$parent"; then
    echo "[INFO] link already exists in parent, skip insert"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  # awkでの挿入ロジック (\r除去は行わないが、出力時に改行コードを維持するかは環境依存。Git BashならLFになる)
  awk -v link="$link" '
    BEGIN { started=0; inFM=0; inserted=0 }
    {
      line=$0
      # WindowsのCRを取り除いて判定
      cleanLine=line
      sub(/\r$/, "", cleanLine)

      if (started==0) {
        if (cleanLine ~ /^[[:space:]]*$/) { print line; next }
        if (cleanLine ~ /^[[:space:]]*---[[:space:]]*$/) {
          started=1
          inFM=1
          print line
          next
        }
        started=2
        print line
        next
      }

      if (started==1 && inFM==1) {
        print line
        if (cleanLine ~ /^[[:space:]]*---[[:space:]]*$/) {
          inFM=0
          if (!inserted) {
            print ""
            print link
            print ""
            inserted=1
          }
        }
        next
      }
      print line
    }
    END {
      if (started==1 && inserted==0) exit 3
    }
  ' "$parent" > "$tmp" || {
    rc=$?
    rm -f "$tmp"
    return "$rc"
  }

  mv "$tmp" "$parent"
  echo "[INFO] inserted below frontmatter: $link"
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

  # テンプレート読み込み時に \r 除去
  tr -d '\r' < "$tmpl_file" | sed \
    -e "s|{{ID}}|${ID_ESC}|g" \
    -e "s|{{PARENT}}|${PARENT_ESC}|g" \
    -e "s|{{TODAY}}|${TODAY_ESC}|g" \
    -e "s|{{NOW}}|${NOW_ESC}|g" \
    -e "s|{{CHILD_BASE}}|${CHILD_BASE_ESC}|g" \
    -e "s|{{TITLE}}|${TITLE_ESC}|g" \
    > "$out_file"
}

# --- メイン処理開始 ---

PARENT_FILE="$(to_posix "$PARENT_FILE")"
[[ -f "$PARENT_FILE" ]] || { echo "[ERR] not found: $PARENT_FILE" >&2; exit 2; }

# 【修正点1】作成先のディレクトリを「親ファイルと同じ場所」にする
OUTPUT_DIR="$(dirname "$PARENT_FILE")"

# テンプレートなどを探すためのROOTは引数または親ディレクトリから決定
if [[ -z "$ROOT" ]]; then
  ROOT="$OUTPUT_DIR"
else
  ROOT="$(to_posix "$ROOT")"
fi

# ID取得
PARENT_ID="$(get_fm_id "$PARENT_FILE")"
if [[ -z "$PARENT_ID" ]]; then
  echo "[ERR] parent has no id: $PARENT_FILE" >&2
  exit 1
fi

TODAY_YMD="$(date '+%Y-%m-%d')"
NOW="$(date '+%Y-%m-%d %H:%M')"

BASE="$(slugify "$CHILD_TITLE")"
CHILD_BASE="${TODAY_YMD}_${BASE}"

# 【修正点2】ファイルパスの構築に OUTPUT_DIR を使用
CHILD_PATH="${OUTPUT_DIR}/${CHILD_BASE}.md"
CHILD_ID="$(date '+%Y%m%d')-${CHILD_BASE}"

if [[ -e "$CHILD_PATH" ]]; then
  echo "[ERR] already exists: $CHILD_PATH" >&2
  exit 1
fi

TEMPL_DIR="${ROOT}/templates"
TEMPL_FILE="${TEMPL_DIR}/child_${TEMPLATE_KEY}.md"

if [[ ! -f "$TEMPL_FILE" ]]; then
  echo "[ERR] template not found: $TEMPL_FILE" >&2
  echo "[HINT] expected at: ${TEMPL_FILE}" >&2
  exit 1
fi

render_template "$TEMPL_FILE" "$CHILD_PATH"

echo "[INFO] created: $CHILD_PATH"
echo "[INFO] parent id : $PARENT_ID"
echo "[INFO] template  : ${TEMPLATE_KEY}"

insert_link_below_frontmatter "$PARENT_FILE" "$CHILD_BASE" || {
  echo "[WARN] could not insert below frontmatter; fallback to append end" >&2
  printf '\n[[%s]]\n' "$CHILD_BASE" >> "$PARENT_FILE"
}

clip_set "$PARENT_ID" || true

if [[ "$OPEN_CHILD" -eq 1 ]]; then
  if command -v code >/dev/null 2>&1; then
    # code コマンドにも Windows パスではなく Git Bash パスを渡しても通常は処理してくれるが
    # 心配な場合は cygpath -w "$CHILD_PATH" する手もある
    code -r "$CHILD_PATH" >/dev/null 2>&1 || true
  fi
else
  echo "[INFO] --no-open: skip opening in VS Code"
fi
