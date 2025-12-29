#!/usr/bin/env bash
# update_in_place.sh (FAST)
#
# Windows(Git Bash)で遅い原因を潰す版:
# - 1リンクごとに find/head/grep/sed/awk/cut を起動しない
# - Vault全体を最初に一度だけ索引化（basename等も外部コマンド廃止）
# - リンク先ファイルの状態は mtime でキャッシュ（同じノートは一度しか解析しない）
# - VS Code ${file} が C:\... で来ても to_posix(cygpath) で吸収
#
# 使い方:
#   ./update_in_place.sh <target.md>
#
# Optional env:
#   ZK_DEBUG=1        デバッグログ
#   ZK_PRUNE_DIRS     追加で find から除外するディレクトリ名(カンマ区切り)
#                    例: ZK_PRUNE_DIRS="attachments,exports,archive,node_modules"
#
export LC_ALL=C.UTF-8
set -Eeuo pipefail
trap 'rc=$?; printf "[ERR] exit=%d line=%d cmd=%s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

TARGET_FILE="${1:-}"

# --- lifecycle icons (open/closed/error) ---
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "

# --- markers (suffix) ---
ICON_FOCUS="🎯"
ICON_AWAIT="⏳"
ICON_BLOCK="🧱"

# --- decision state icons (separate layer) ---
# NOTE: accepted は closed(✅) と被るので、別アイコン
ICON_ACCEPT="🆗 "
ICON_REJECT="❌ "
ICON_SUPER="♻️ "
ICON_DROP="💤 "
ICON_PROPOSE="📝 "

ZK_DEBUG="${ZK_DEBUG:-0}"
dbg(){ if [[ "${ZK_DEBUG}" != 0 ]]; then printf '[DBG] %s\n' "$*" >&2; fi; }

if [[ -z "$TARGET_FILE" ]]; then
  echo "usage: $0 <target.md>" >&2
  exit 2
fi

to_posix() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    if [[ "$p" =~ ^[A-Za-z]:[\\/].* ]] || [[ "$p" == *\\* ]]; then
      cygpath -u "$p"
      return 0
    fi
  fi
  printf '%s\n' "$p"
}

# 入力ファイルのパス正規化
TARGET_FILE="$(to_posix "$TARGET_FILE")"
TARGET_FILE="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)/${TARGET_FILE##*/}"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "Error: File not found: $TARGET_FILE" >&2
  exit 1
fi

PARENT_DIR="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
TEMP_FILE="$(mktemp)"

# vault root 自動検出（.obsidian/.foam/.git/.vscode を上に辿る）
detect_root() {
  local d="$PARENT_DIR"
  while :; do
    [[ -d "$d/.obsidian" ]] && { printf '%s\n' "$d"; return; }
    [[ -d "$d/.foam"     ]] && { printf '%s\n' "$d"; return; }
    [[ -d "$d/.git"      ]] && { printf '%s\n' "$d"; return; }
    [[ -d "$d/.vscode"   ]] && { printf '%s\n' "$d"; return; }
    [[ "$d" == "/" ]] && break
    d="$(dirname "$d")"
  done
  printf '%s\n' "$PARENT_DIR"
}

VAULT_ROOT="$(detect_root)"
dbg "TARGET_FILE=$TARGET_FILE"
dbg "PARENT_DIR=$PARENT_DIR"
dbg "VAULT_ROOT=$VAULT_ROOT"

# stat (mtime)
OS_NAME="$(uname)"
STAT_CMD=(stat -c %Y)
if [[ "$OS_NAME" == "Darwin" ]]; then
  STAT_CMD=(stat -f %m)
fi

# -----------------------------
# 文字列クリーニング
# -----------------------------
clean_prefix() {
  local s="$1"
  for icon in \
    "$ICON_CLOSED" "$ICON_OPEN" "$ICON_ERROR" \
    "$ICON_ACCEPT" "$ICON_REJECT" "$ICON_SUPER" "$ICON_DROP" "$ICON_PROPOSE"
  do
    s="${s//$icon/}"
  done
  printf '%s' "$s"
}

# suffix の先頭から marker と (→ xxx) を剥がす（外部 sed なし）
clean_suffix() {
  local s="$1"
  # 先頭: (🎯|🧱|⏳)(...)
  if [[ "$s" =~ ^[[:space:]]*(🎯|🧱|⏳)\([^)]*\)(.*)$ ]]; then
    s="${BASH_REMATCH[2]}"
  fi
  # 先頭: (→ ...)
  if [[ "$s" =~ ^[[:space:]]*\(→[^)]*\)(.*)$ ]]; then
    s="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$s"
}

# -----------------------------
# 1) まず Vault 内の md を一度だけ索引化（リンク解決の find を撲滅）
# -----------------------------
declare -A FILE_MAP=()   # key: basename(no ext) -> fullpath
declare -A FILE_MAP_MD=()# key: basename(with .md) -> fullpath (念のため)

# 追加除外（ディレクトリ名カンマ区切り）
# 例: ZK_PRUNE_DIRS="attachments,exports,archive,node_modules"
PRUNE_DIRS="${ZK_PRUNE_DIRS:-}"
IFS=',' read -r -a PRUNE_ARR <<< "$PRUNE_DIRS"
unset IFS

# find コマンド組み立て（隠しディレクトリは常に prune）
FIND_CMD=(find "$VAULT_ROOT" \( -path "*/.*" )
for d in "${PRUNE_ARR[@]}"; do
  d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
  [[ -z "$d" ]] && continue
  FIND_CMD+=( -o -path "*/$d/*" )
done
FIND_CMD+=( \) -prune -o -type f -name "*.md" -print0)

dbg "Indexing md files..."
FILE_COUNT=0
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue
  base="${f##*/}"
  base_no_ext="${base%.md}"

  # 競合があっても「最初に見つかったもの」を優先（元の find -quit と同じく曖昧解決）
  if [[ -z "${FILE_MAP["$base_no_ext"]+x}" ]]; then
    FILE_MAP["$base_no_ext"]="$f"
  fi
  if [[ -z "${FILE_MAP_MD["$base"]+x}" ]]; then
    FILE_MAP_MD["$base"]="$f"
  fi

  FILE_COUNT=$((FILE_COUNT+1))
done < <("${FIND_CMD[@]}" 2>/dev/null || true)

(( FILE_COUNT > 0 )) || { echo "[ERR] vault scan returned 0 md files. VAULT_ROOT is wrong?" >&2; exit 1; }
dbg "Indexed md count=$FILE_COUNT"

resolve_file_path_fast() {
  local filename="$1"  # "xxx.md" or "xxx"
  # まず同じフォルダ優先（元の挙動維持）
  if [[ -f "$PARENT_DIR/$filename" ]]; then
    printf '%s\n' "$PARENT_DIR/$filename"
    return 0
  fi
  # .md あり/なし 両対応
  if [[ "$filename" == *.md ]]; then
    local p="${FILE_MAP_MD["$filename"]:-}"
    [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }
    local noext="${filename%.md}"
    p="${FILE_MAP["$noext"]:-}"
    [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }
  else
    local p="${FILE_MAP["$filename"]:-}"
    [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }
    p="${FILE_MAP_MD["$filename.md"]:-}"
    [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }
  fi
  printf '%s\n' ""  # not found
}

# -----------------------------
# 2) リンク先メタ情報を mtime でキャッシュ（head/grep/awk を一度だけ）
# -----------------------------
declare -A META_MTIME=()
declare -A META_INFO=()  # fpath -> "life<TAB>dec<TAB>prio<TAB>text<TAB>arrow"

scan_meta() {
  local f_path="$1"
  # 出力: life<TAB>dec<TAB>prio<TAB>text<TAB>arrow
  awk \
    -v ic="$ICON_CLOSED" -v io="$ICON_OPEN" \
    -v iacc="$ICON_ACCEPT" -v irej="$ICON_REJECT" -v isup="$ICON_SUPER" -v idrp="$ICON_DROP" -v iprp="$ICON_PROPOSE" '
  function norm_ws(s){ gsub(/　/, " ", s); return s }
  function trim(s){
    s = norm_ws(s)
    sub(/^\xef\xbb\xbf/, "", s)
    gsub(/\r/, "", s)
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return s
  }
  function strip_quotes(v){
    v=trim(v)
    gsub(/^"+|"+$/, "", v)
    gsub(/^\047+|\047+$/, "", v)
    gsub(/^\140+|\140+$/, "", v)
    return v
  }
  function fence_count(s, c, n){ n=0; while (substr(s, n+1, 1) == c) n++; return n }

  BEGIN{
    in_fm=0; first=0;
    closed=0; decision=""; sup_by="";
    in_code=0; fence_ch=""; fence_len=0;

    a_txt=""; b_txt=""; f_txt="";
  }

  {
    line=$0
    sub(/\r$/, "", line)
    if(NR==1){ sub(/^\xef\xbb\xbf/, "", line) }
    t=trim(line)

    # frontmatter
    if(!first){
      if(t=="") next
      first=1
      if(t ~ /^---[ \t]*$/){ in_fm=1; next }
    }
    if(in_fm){
      if(t ~ /^---[ \t]*$/){ in_fm=0; next }

      if(t ~ /^closed:[ \t]*/){ closed=1 }
      if(t ~ /^decision:[ \t]*/){
        sub(/^decision:[ \t]*/, "", t)
        decision=tolower(trim(t))
      }
      if(t ~ /^superseded_by:[ \t]*/){
        sub(/^superseded_by:[ \t]*/, "", t)
        sup_by=strip_quotes(t)
      }
      next
    }

    # fenced code skip
    u=line
    gsub(/^[ \t]+|[ \t]+$/, "", u)
    if(in_code){
      c=substr(u,1,1)
      if(c==fence_ch){
        n=fence_count(u, fence_ch)
        if(n>=fence_len){
          rest=trim(substr(u,n+1))
          if(rest==""){ in_code=0; next }
        }
      }
      next
    } else {
      c=substr(u,1,1)
      if(c=="`" || c=="~"){
        n=fence_count(u,c)
        if(n>=3){
          fence_ch=c; fence_len=n; in_code=1; next
        }
      }
    }

    low=tolower(line)

    # marker text は「初出」を保持し、最後に awaiting > blocked > focus で選ぶ
    if(a_txt=="" && low ~ /@awaiting/){
      a_txt=line
      sub(/.*@awaiting[[:space:]]*/i, "", a_txt)
      a_txt=trim(a_txt)
    }
    if(b_txt=="" && low ~ /@blocked/){
      b_txt=line
      sub(/.*@blocked[[:space:]]*/i, "", b_txt)
      b_txt=trim(b_txt)
    }
    if(f_txt=="" && low ~ /@focus/){
      f_txt=line
      sub(/.*@focus[[:space:]]*/i, "", f_txt)
      f_txt=trim(f_txt)
    }
  }

  END{
    life = (closed?ic:io)

    dec=""
    if(decision!=""){
      if(decision=="accepted") dec=iacc
      else if(decision=="rejected") dec=irej
      else if(decision=="superseded") dec=isup
      else if(decision=="dropped") dec=idrp
      else dec=iprp
    }

    # decision 終端なら marker 抑制（ただし superseded の矢印は別）
    prio=""; text=""
    if(!(decision ~ /^(accepted|rejected|superseded|dropped)$/)){
      if(a_txt!=""){ prio="⏳"; text=a_txt }
      else if(b_txt!=""){ prio="🧱"; text=b_txt }
      else if(f_txt!=""){ prio="🎯"; text=f_txt }
    }

    arrow=""
    if(decision=="superseded" && sup_by!=""){
      arrow=sup_by
    }

    gsub(/\t/, " ", text)
    gsub(/\t/, " ", arrow)

    printf "%s\t%s\t%s\t%s\t%s\n", life, dec, prio, text, arrow
  }' "$f_path"
}

ensure_meta() {
  local f_path="$1"
  [[ -f "$f_path" ]] || return 1

  local cur
  cur="$("${STAT_CMD[@]}" "$f_path" 2>/dev/null || echo 0)"
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=0

  if [[ "${META_MTIME["$f_path"]:-}" != "$cur" ]]; then
    dbg "scan_meta: $f_path"
    META_INFO["$f_path"]="$(scan_meta "$f_path")"
    META_MTIME["$f_path"]="$cur"
  fi
  return 0
}

get_link_info_fast() {
  local f_path="$1"
  if [[ -z "$f_path" || ! -f "$f_path" ]]; then
    printf "%s\t\t\t\t\n" "$ICON_ERROR"
    return 0
  fi
  ensure_meta "$f_path" || { printf "%s\t\t\t\t\n" "$ICON_ERROR"; return 0; }
  printf "%s\n" "${META_INFO["$f_path"]}"
}

# -----------------------------
# 3) 本体: 1行ずつ変換（外部 cut/echo/sed を排除）
# -----------------------------
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ (.*)\[\[([^]|]+)(\|[^]]+)?\]\](.*) ]]; then
    prefix="${BASH_REMATCH[1]}"
    link_target="${BASH_REMATCH[2]}"
    link_alias="${BASH_REMATCH[3]}"
    suffix="${BASH_REMATCH[4]}"

    # [[Note#Heading]] の #以降はファイル解決に使わない
    target_filepart="${link_target%%#*}"
    target_filepart="${target_filepart#"${target_filepart%%[!$' \t　']*}"}"
    target_filepart="${target_filepart%"${target_filepart##*[!$' \t　']}"}"

    if [[ -z "$target_filepart" ]]; then
      printf '%s\n' "$line" >> "$TEMP_FILE"
      continue
    fi

    if [[ "$target_filepart" != *.md ]]; then
      filename="${target_filepart}.md"
    else
      filename="$target_filepart"
    fi

    resolved_path="$(resolve_file_path_fast "$filename")"

    info_line="$(get_link_info_fast "$resolved_path")"
    IFS=$'\t' read -r life_icon dec_icon pr_icon extra_txt arrow_txt <<< "$info_line"
    unset IFS

    new_prefix="$(clean_prefix "$prefix")"
    new_suffix="$(clean_suffix "$suffix")"

    prio_part=""
    if [[ -n "${pr_icon:-}" ]]; then
      if [[ -n "${extra_txt:-}" ]]; then
        prio_part="${pr_icon}(${extra_txt})"
      else
        prio_part="${pr_icon}"
      fi
    fi

    arrow_part=""
    if [[ -n "${arrow_txt:-}" ]]; then
      arrow_part=" (→ ${arrow_txt})"
    fi

    # life + decision を並べて表示
    printf '%s%s%s[[%s%s]]%s%s%s\n' \
      "$new_prefix" \
      "${life_icon:-$ICON_OPEN}" \
      "${dec_icon:-}" \
      "$link_target" \
      "${link_alias:-}" \
      "$prio_part" \
      "$arrow_part" \
      "$new_suffix" \
      >> "$TEMP_FILE"
  else
    printf '%s\n' "$line" >> "$TEMP_FILE"
  fi
done < "$TARGET_FILE"

mv "$TEMP_FILE" "$TARGET_FILE"
echo "Updated: $TARGET_FILE"
