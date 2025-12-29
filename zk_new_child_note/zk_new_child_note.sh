#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# zk_new_child_note.sh
# - 子ノートをテンプレから作成
# - 親ノート(frontmatter直下)に [[wikilink]] を挿入
# - 末尾で子ノートを VS Code で開く(デフォルト)
#   -> --no-open で抑止可能
#
# 追加:
#   --same-dir   子ノート作成先を「親ノートと同じフォルダ」にする
#   --out-dir D  子ノート作成先を明示（相対なら Vault root から）
# ------------------------------------------------------------

OPEN_CHILD=1  # 1=open / 0=do not open
SAME_DIR=0
OUT_DIR=""

usage() {
  cat >&2 <<'EOF'
usage:
  zk_new_child_note.sh [--no-open|--open] [--same-dir] [--out-dir DIR] <parent-md-file> <child-title> [VAULT_ROOT] [TEMPLATE_KEY]

options:
  --no-open    子ノートを作成しても VS Code で開かない
  --open       明示的に開く（デフォルト）
  --same-dir   子ノートを親ノートと同じフォルダに作成する
  --out-dir D  子ノート作成先を指定（相対パスなら VAULT_ROOT から）

env:
  ZK_NEW_CHILD_OPEN=0           でも --no-open と同じ
  ZK_NEW_CHILD_SAME_DIR=1       でも --same-dir と同じ
  ZK_NEW_CHILD_OUT_DIR=path     でも --out-dir と同じ（相対なら VAULT_ROOT から）
EOF
  exit 2
}

# env で上書き（task.json の options.env で使える）
if [[ -n "${ZK_NEW_CHILD_OPEN:-}" ]]; then
  case "${ZK_NEW_CHILD_OPEN}" in
    0|false|FALSE|no|NO) OPEN_CHILD=0 ;;
    1|true|TRUE|yes|YES) OPEN_CHILD=1 ;;
  esac
fi
if [[ -n "${ZK_NEW_CHILD_SAME_DIR:-}" ]]; then
  case "${ZK_NEW_CHILD_SAME_DIR}" in
    1|true|TRUE|yes|YES) SAME_DIR=1 ;;
    0|false|FALSE|no|NO) SAME_DIR=0 ;;
  esac
fi
if [[ -n "${ZK_NEW_CHILD_OUT_DIR:-}" ]]; then
  OUT_DIR="${ZK_NEW_CHILD_OUT_DIR}"
fi

# 引数パース（オプションはどこに置いてもOK）
pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open)  OPEN_CHILD=0; shift;;
    --open)     OPEN_CHILD=1; shift;;
    --same-dir) SAME_DIR=1; shift;;
    --out-dir)
      OUT_DIR="${2:-}"
      [[ -n "$OUT_DIR" ]] || { echo "[ERR] --out-dir requires DIR" >&2; exit 2; }
      shift 2
      ;;
    -h|--help) usage ;;
    *) pos+=("$1"); shift;;
  esac
done

PARENT_FILE="${pos[0]:-}"
CHILD_TITLE="${pos[1]:-}"
VAULT_ROOT_ARG="${pos[2]:-}"
TEMPLATE_KEY="${pos[3]:-task}"   # task / review など

if [[ -z "$PARENT_FILE" || -z "$CHILD_TITLE" ]]; then
  usage
fi

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

clip_set() {
  local s="$1"
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$s" | pbcopy
  elif command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$s" | clip.exe
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$s" | xclip -selection clipboard
  else
    return 0
  fi
}

get_fm_id() {
  local f="$1"
  awk '
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
  }' "$f"
}

slugify() {
  local s="$1"
  s="${s// /_}"
  s="$(printf '%s' "$s" | tr -d '\r')"
  s="$(printf '%s' "$s" | sed -E 's/[^0-9A-Za-zぁ-んァ-ン一-龠ー_・-]+/_/g; s/_+/_/g; s/^_+|_+$//g')"
  [[ -n "$s" ]] || s="child"
  printf '%s\n' "$s"
}

insert_link_below_frontmatter() {
  local parent="$1"
  local child_base="$2"  # 拡張子なし
  local link="[[${child_base}]]"

  if grep -Fq "$link" "$parent"; then
    echo "[INFO] link already exists in parent, skip insert"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  awk -v link="$link" '
    BEGIN { started=0; inFM=0; inserted=0 }

    {
      line=$0

      if (started==0) {
        if (line ~ /^[[:space:]]*$/) { print $0; next }
        if (line ~ /^[[:space:]]*---[[:space:]]*$/) {
          started=1
          inFM=1
          print $0
          next
        }
        started=2
        print $0
        next
      }

      if (started==1 && inFM==1) {
        print $0
        if (line ~ /^[[:space:]]*---[[:space:]]*$/) {
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

      print $0
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

  sed \
    -e "s|{{ID}}|${ID_ESC}|g" \
    -e "s|{{PARENT}}|${PARENT_ESC}|g" \
    -e "s|{{TODAY}}|${TODAY_ESC}|g" \
    -e "s|{{NOW}}|${NOW_ESC}|g" \
    -e "s|{{CHILD_BASE}}|${CHILD_BASE_ESC}|g" \
    -e "s|{{TITLE}}|${TITLE_ESC}|g" \
    "$tmpl_file" > "$out_file"
}

find_vault_root() {
  local start="$1"
  local d="$start"
  while :; do
    if [[ -d "$d/.obsidian" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
    local p
    p="$(cd "$d/.." && pwd -P)"
    [[ "$p" == "$d" ]] && break
    d="$p"
  done
  # 見つからない場合は親ノートのフォルダを Vault root 扱い
  printf '%s\n' "$start"
}

abs_dir_under_vault() {
  local d="$1"
  d="$(to_posix "$d")"
  if [[ "$d" != /* ]]; then
    d="${VAULT_ROOT}/${d}"
  fi
  mkdir -p "$d"
  (cd "$d" && pwd -P)
}

# ---- main ----
PARENT_FILE="$(to_posix "$PARENT_FILE")"
[[ -f "$PARENT_FILE" ]] || { echo "[ERR] not found: $PARENT_FILE" >&2; exit 2; }

PARENT_DIR="$(cd "$(dirname "$PARENT_FILE")" && pwd -P)"

if [[ -n "$VAULT_ROOT_ARG" ]]; then
  VAULT_ROOT="$(to_posix "$VAULT_ROOT_ARG")"
  VAULT_ROOT="$(cd "$VAULT_ROOT" && pwd -P)"
else
  VAULT_ROOT="$(find_vault_root "$PARENT_DIR")"
fi

# 作成先の決定
if [[ -n "$OUT_DIR" ]]; then
  OUT_DIR="$(abs_dir_under_vault "$OUT_DIR")"
elif [[ "$SAME_DIR" -eq 1 ]]; then
  OUT_DIR="$PARENT_DIR"
else
  OUT_DIR="$VAULT_ROOT"
fi

PARENT_ID="$(get_fm_id "$PARENT_FILE")"
if [[ -z "$PARENT_ID" ]]; then
  echo "[ERR] parent has no id: $PARENT_FILE" >&2
  exit 1
fi

TODAY_YMD="$(date '+%Y-%m-%d')"
NOW="$(date '+%Y-%m-%d %H:%M')"

BASE="$(slugify "$CHILD_TITLE")"
CHILD_BASE="${TODAY_YMD}_${BASE}"
CHILD_PATH="${OUT_DIR}/${CHILD_BASE}.md"
CHILD_ID="$(date '+%Y%m%d')-${CHILD_BASE}"

if [[ -e "$CHILD_PATH" ]]; then
  echo "[ERR] already exists: $CHILD_PATH" >&2
  exit 1
fi

TEMPL_DIR="${VAULT_ROOT}/templates"
TEMPL_FILE="${TEMPL_DIR}/child_${TEMPLATE_KEY}.md"

if [[ ! -f "$TEMPL_FILE" ]]; then
  echo "[ERR] template not found: $TEMPL_FILE" >&2
  echo "[HINT] create templates/child_${TEMPLATE_KEY}.md (e.g. child_task.md, child_review.md)" >&2
  exit 1
fi

render_template "$TEMPL_FILE" "$CHILD_PATH"

echo "[INFO] created    : $CHILD_PATH"
echo "[INFO] out dir    : $OUT_DIR"
echo "[INFO] vault root : $VAULT_ROOT"
echo "[INFO] parent id  : $PARENT_ID"
echo "[INFO] template   : ${TEMPLATE_KEY}"

insert_link_below_frontmatter "$PARENT_FILE" "$CHILD_BASE" || {
  echo "[WARN] could not insert below frontmatter; fallback to append end" >&2
  printf '\n[[%s]]\n' "$CHILD_BASE" >> "$PARENT_FILE"
}

clip_set "$PARENT_ID" || true

if [[ "$OPEN_CHILD" -eq 1 ]]; then
  if command -v code >/dev/null 2>&1; then
    code -r "$CHILD_PATH" >/dev/null 2>&1 || true
  fi
else
  echo "[INFO] --no-open: skip opening in VS Code"
fi
