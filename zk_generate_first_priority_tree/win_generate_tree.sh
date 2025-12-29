#!/usr/bin/env bash
# zk_generate_cached_tree_v7_4_fixed.sh
# v7.4.9-decision-kind-badge+decision-layered+superseded_by + win-opt-lite(+to_posix)
#
# Windows(Git Bash)向け最適化(Lite):
# - ループ内の basename 外部コマンド起動を廃止（Bash展開へ）
# - build_tree_safe 内の display_name も basename 廃止（ノード数ぶん効く）
# - START_KEY も basename 廃止
# - ★追加: VS Code ${file} が C:\... で来ても動くように to_posix(cygpath) で正規化
#
set -Eeuo pipefail
export LANG=en_US.UTF-8

trap 'rc=$?; printf "[ERR] exit=%d line=%d cmd=%s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

OUTDIR_NAME="dashboards"
FIXED_FILENAME="TREE_VIEW.md"

CACHE_VERSION="v7.4.9"
CACHE_FILE=".zk_metadata_cache_${CACHE_VERSION}.tsv"
CACHE_MAGIC="#ZK_CACHE\tv7.4.9\tcols=5\tlinks=pipe"

# lifecycle
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "

# markers
ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "
ICON_BLOCK="🧱 "
ICON_CYCLE="🔁 (infinite loop) "
ICON_ALREADY="🔗 (already shown) "

# decision kind badge (always shown when decision: exists)
ICON_DECISION_NOTE="🗳️ "

# decision layer (accepted is NOT ✅ to avoid collision with closed)
ICON_ACCEPT="🆗 "
ICON_REJECT="❌ "
ICON_SUPER="♻️ "
ICON_DROP="💤 "
ICON_PROPOSE="📝 "

ZK_DEBUG="${ZK_DEBUG:-0}"
ZK_DIAG="${ZK_DIAG:-0}"

dbg() { if [[ "${ZK_DEBUG:-0}" != 0 ]]; then printf '[DBG] %s\n' "$*" >&2; fi; return 0; }
info() { printf '[INFO] %s\n' "$*" >&2; return 0; }
die()  { printf '[ERR] %s\n' "$*" >&2; exit 1; }

if (( BASH_VERSINFO[0] < 4 )); then
  die "bash >= 4 required. Use /opt/homebrew/bin/bash (brew bash) or Git Bash."
fi

to_posix() {
  local p="$1"
  # VS Code on Windows often passes "C:\path\to\file.md"
  if command -v cygpath >/dev/null 2>&1; then
    if [[ "$p" =~ ^[A-Za-z]:[\\/].* ]] || [[ "$p" == *\\* ]]; then
      cygpath -u "$p"
      return 0
    fi
  fi
  printf '%s\n' "$p"
}

TARGET_FILE="${1:-}"
[[ -z "$TARGET_FILE" ]] && die "Usage: $0 <file.md>"

# ★ WindowsパスをPOSIXへ
TARGET_FILE="$(to_posix "$TARGET_FILE")"

# ここは1回だけの外部コマンドでOK（dirname/cd/pwd）
TARGET_FILE="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)/${TARGET_FILE##*/}"
[[ -f "$TARGET_FILE" ]] || die "File not found: $TARGET_FILE"

ROOT_REASON=""

detect_root() {
  local start d
  start="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"

  case "$start" in
    */"$OUTDIR_NAME")
      ROOT_REASON="from_dashboards_dir"
      printf "%s\n" "$(cd "$start/.." && pwd -P)"
      return
      ;;
    */"$OUTDIR_NAME"/*)
      ROOT_REASON="from_dashboards_child"
      printf "%s\n" "${start%%/$OUTDIR_NAME/*}"
      return
      ;;
  esac

  d="$start"
  while :; do
    if [[ -d "$d/.obsidian" ]]; then ROOT_REASON="found_.obsidian"; printf "%s\n" "$d"; return; fi
    if [[ -d "$d/.foam"     ]]; then ROOT_REASON="found_.foam";     printf "%s\n" "$d"; return; fi
    if [[ -d "$d/.git"      ]]; then ROOT_REASON="found_.git";      printf "%s\n" "$d"; return; fi
    if [[ -d "$d/.vscode"   ]]; then ROOT_REASON="found_.vscode";   printf "%s\n" "$d"; return; fi
    [[ "$d" == "/" ]] && break
    d="$(dirname "$d")"
  done

  ROOT_REASON="fallback_to_start_dir"
  printf "%s\n" "$start"
}

ROOT="$(detect_root)"

# ★外部 basename 廃止（Bash展開）
if [[ "${ROOT##*/}" == "$OUTDIR_NAME" ]]; then
  ROOT_REASON="${ROOT_REASON}+auto_fix_parent"
  ROOT="$(cd "$ROOT/.." && pwd -P)"
fi

OUTDIR="${ROOT}/${OUTDIR_NAME}"
mkdir -p "$OUTDIR"
OUTPUT_FILE="${OUTDIR}/${FIXED_FILENAME}"
CACHE_PATH="${OUTDIR}/${CACHE_FILE}"

OS_NAME="$(uname)"

# stat コマンドは「配列」で保持（スペース含みの事故防止）
STAT_CMD=(stat -c %Y)
if [[ "$OS_NAME" == "Darwin" ]]; then
  STAT_CMD=(stat -f %m)
fi

info "TARGET_FILE=$TARGET_FILE"
info "ROOT=$ROOT (reason=$ROOT_REASON)"
info "OUTDIR=$OUTDIR"
info "OUTPUT_FILE=$OUTPUT_FILE"
info "CACHE_PATH=$CACHE_PATH"
dbg  "STAT_CMD=${STAT_CMD[*]}"

if [[ "$ZK_DIAG" != 0 ]]; then
  cnt="$(find "$ROOT" \( -path "*/.*" \) -prune -o -type f -name "*.md" -print 2>/dev/null | wc -l | tr -d ' ')"
  info "DIAG md_count_under_ROOT=$cnt"
  info "DIAG sample_md_files:"
  find "$ROOT" \( -path "*/.*" \) -prune -o -type f -name "*.md" -print 2>/dev/null \
    | head -n 20 | sed 's/^/[INFO]   /' >&2
  exit 0
fi

declare -A ID_MAP=()
declare -A STATUS_MAP=()
declare -A LINKS_MAP=()
declare -A MTIME_MAP=()
declare -A PATH_TO_ID=()
declare -A DIRTY=()

is_digits() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
now_ts() { date '+%Y%m%d%H%M%S'; }

backup_bad_cache() {
  local src="$1"
  [[ -f "$src" ]] || return
  local dst="${src}.bak.$(now_ts)"
  mv -f "$src" "$dst"
  info "cache invalid -> moved to: $dst"
}

# ------------------------------------------------------------
# scan_file: frontmatter + marker + wikilinks (+ superseded_by)
# 出力: fid<TAB>status<TAB>links
# status は「life + decision_kind + decision_state + marker...」の合成
# ------------------------------------------------------------
scan_file() {
  awk \
    -v ic="$ICON_CLOSED" -v io="$ICON_OPEN" \
    -v idec="$ICON_DECISION_NOTE" \
    -v iacc="$ICON_ACCEPT" -v irej="$ICON_REJECT" -v isup="$ICON_SUPER" -v idrp="$ICON_DROP" -v iprp="$ICON_PROPOSE" \
    -v ifoc="$ICON_FOCUS" -v ib="$ICON_BLOCK" -v ia="$ICON_AWAIT" '
  function norm_ws(s){ gsub(/　/, " ", s); return s }
  function trim(s){
    s = norm_ws(s)
    sub(/^\xef\xbb\xbf/, "", s)
    gsub(/\r/, "", s)
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return s
  }
  function strip_container(s){
    s = trim(s)
    while (1) {
      if (s ~ /^>[ \t]*/) { sub(/^>[ \t]*/, "", s); s=trim(s); continue }
      if (s ~ /^([-*+])[ \t]+/) { sub(/^([-*+])[ \t]+/, "", s); s=trim(s); continue }
      if (s ~ /^[0-9]+[.)][ \t]+/) { sub(/^[0-9]+[.)][ \t]+/, "", s); s=trim(s); continue }
      break
    }
    return s
  }
  function fence_count(s, c, n){ n=0; while (substr(s, n+1, 1) == c) n++; return n }
  function strip_quotes(v){
    v=trim(v)
    gsub(/^"+|"+$/, "", v)
    gsub(/^\047+|\047+$/, "", v)
    gsub(/^\140+|\140+$/, "", v)
    return v
  }

  BEGIN {
    in_fm=0; first=0; fid="none"; closed=0;
    decision_state=""; allow_marker=1;
    sup_by="";
    marker=""; marker_text=""; links="";
    in_code=0; fence_ch=""; fence_len=0;
    delete seen
  }

  {
    line=$0
    sub(/\r$/, "", line)
    if(NR==1){ sub(/^\xef\xbb\xbf/, "", line) }

    t = trim(line)

    # frontmatter
    if(!first){
      if(t==""){ next }
      first=1
      if(t ~ /^---[ \t]*$/){ in_fm=1; next }
    }
    if(in_fm){
      if(t ~ /^---[ \t]*$/){ in_fm=0; next }

      if(t ~ /^[ \t]*id:[ \t]*/){
        fid=line
        sub(/^[ \t]*id:[ \t]*/, "", fid)
        fid=trim(fid)
      }
      if(t ~ /^[ \t]*closed:[ \t]*/){ closed=1 }

      if(t ~ /^[ \t]*decision:[ \t]*/){
        ds=line
        sub(/^[ \t]*decision:[ \t]*/, "", ds)
        ds=trim(ds)
        decision_state=tolower(ds)
      }

      if(t ~ /^[ \t]*superseded_by:[ \t]*/){
        v=line
        sub(/^[ \t]*superseded_by:[ \t]*/, "", v)
        v=strip_quotes(v)
        sup_by=v
      }
      next
    }

    # decision が終端状態なら marker は抑制
    if(decision_state!=""){
      if(decision_state ~ /^(accepted|rejected|superseded|dropped)$/){
        allow_marker=0
      } else {
        allow_marker=1
      }
    } else {
      allow_marker=1
    }

    # fenced code skip
    u = strip_container(line)

    if(in_code){
      if(substr(u,1,1)==fence_ch){
        n = fence_count(u, fence_ch)
        if(n >= fence_len){
          rest = trim(substr(u, n+1))
          if(rest==""){ in_code=0; next }
        }
      }
      next
    } else {
      c = substr(u,1,1)
      if(c=="`" || c=="~"){
        n = fence_count(u, c)
        if(n >= 3){
          fence_ch=c
          fence_len=n
          in_code=1
          next
        }
      }
    }

    # marker（許可されている場合のみ）
    if(allow_marker==1 && marker == ""){
      low=tolower(u)
      if(low ~ /@focus/){
        marker=ifoc
      } else if(low ~ /@blocked/){
        marker=ib; marker_text=u
        sub(/.*@blocked[[:space:]]*/, "", marker_text)
        marker_text=" (🧱 " trim(marker_text) ")"
      } else if(low ~ /@awaiting/){
        marker=ia; marker_text=u
        sub(/.*@awaiting[[:space:]]*/, "", marker_text)
        marker_text=" (⏳ " trim(marker_text) ")"
      }
    }

    # inline code remove
    temp=line
    gsub(/`[^`]*`/, "", temp)

    # wikilink extract
    while(match(temp, /\[\[[^][]+\]\]/)){
      lnk=substr(temp, RSTART+2, RLENGTH-4)
      if(lnk ~ /^[ \t]/){ temp=substr(temp, RSTART+RLENGTH); continue }

      split(lnk, p, "|"); split(p[1], f, "#")
      name=trim(f[1])
      if(name ~ /[*…]/){ temp=substr(temp, RSTART+RLENGTH); continue }

      if(name!="" && !(name in seen)){
        seen[name]=1
        links = links name "|"
      }
      temp=substr(temp, RSTART+RLENGTH)
    }
  }

  END {
    gsub(/\t/, " ", marker_text)
    gsub(/\t/, " ", links)
    gsub(/\n/, " ", links)
    if(links=="") links="|"

    life = (closed?ic:io)
    kind = (decision_state != "" ? idec : "")

    dec = ""
    if(decision_state!=""){
      if(decision_state ~ /^accepted$/) dec=iacc
      else if(decision_state ~ /^rejected$/) dec=irej
      else if(decision_state ~ /^superseded$/) dec=isup
      else if(decision_state ~ /^dropped$/) dec=idrp
      else dec=iprp
    }

    status_out = life kind dec marker marker_text

    if(decision_state ~ /^superseded$/ && sup_by!=""){
      gsub(/\t/, " ", sup_by)
      gsub(/\n/, " ", sup_by)
      status_out = status_out " (→ " sup_by ")"
    }

    printf "%s\t%s\t%s\n", fid, status_out, links
  }' "$1"
}

# ------------------------------------------------------------
# 1) キャッシュ読み込み
# ------------------------------------------------------------
CACHE_OK=0
if [[ -f "$CACHE_PATH" ]]; then
  IFS= read -r firstline < "$CACHE_PATH" || firstline=""
  if [[ "$firstline" == "$CACHE_MAGIC" ]]; then
    CACHE_OK=1
    info "Loading cache..."
    while IFS=$'\t' read -r f_path mtime fid status links extra; do
      [[ -z "${f_path:-}" ]] && continue
      [[ -f "$f_path" ]] || continue

      if [[ -n "${extra:-}" ]]; then MTIME_MAP["$f_path"]="INVALID"; continue; fi
      if ! [[ "${mtime:-}" =~ ^[0-9]+$ ]]; then MTIME_MAP["$f_path"]="INVALID"; continue; fi

      links="${links//$'\r'/}"

      if [[ -z "$links" || "$links" != *"|"* ]]; then
        MTIME_MAP["$f_path"]="INVALID"
        STATUS_MAP["$f_path"]="$status"
        LINKS_MAP["$f_path"]=""
        PATH_TO_ID["$f_path"]="$fid"
        [[ -n "$fid" && "$fid" != "none" ]] && ID_MAP["$fid"]="$f_path"
        continue
      fi

      MTIME_MAP["$f_path"]="$mtime"
      STATUS_MAP["$f_path"]="$status"
      LINKS_MAP["$f_path"]="$links"
      PATH_TO_ID["$f_path"]="$fid"
      [[ -n "$fid" && "$fid" != "none" ]] && ID_MAP["$fid"]="$f_path"
    done < <(tail -n +2 "$CACHE_PATH")
  else
    info "cache header mismatch -> backup & rebuild"
    backup_bad_cache "$CACHE_PATH"
    CACHE_OK=0
  fi
else
  dbg "cache not found: $CACHE_PATH"
fi

# ------------------------------------------------------------
# 2) ファイル名→パス(ID_MAP)を毎回構築（外部basename無し）
# ------------------------------------------------------------
FIND_ERR="$(mktemp 2>/dev/null || echo "/tmp/zk_find_err.$$")"
FILE_COUNT=0

while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue
  name="${f##*/}"
  name="${name%.md}"
  ID_MAP["$name"]="$f"
  FILE_COUNT=$((FILE_COUNT+1))
done < <(find "$ROOT" \( -path "*/.*" \) -prune -o -type f -name "*.md" ! -path "$OUTPUT_FILE" -print0 2>"$FIND_ERR" || true)

if [[ -s "$FIND_ERR" ]]; then
  info "find produced warnings/errors (non-fatal):"
  sed 's/^/[INFO]   /' "$FIND_ERR" >&2
fi
rm -f "$FIND_ERR" || true

info "indexed_by_filename count=$FILE_COUNT under ROOT=$ROOT"
(( FILE_COUNT > 0 )) || die "vault scan returned 0 md files. ROOT is wrong or find failed."

# ------------------------------------------------------------
# 3) オンデマンドでメタを保証
# ------------------------------------------------------------
ensure_meta() {
  local f="$1"
  [[ -f "$f" ]] || return

  local cur m_cached need=0
  cur="$("${STAT_CMD[@]}" "$f" 2>/dev/null || echo 0)"
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=0

  m_cached="${MTIME_MAP["$f"]:-}"
  if [[ -z "$m_cached" || "$m_cached" == "INVALID" || "$m_cached" != "$cur" ]]; then
    need=1
  fi

  if (( need == 0 )); then
    [[ -z "${STATUS_MAP["$f"]+x}" ]] && need=1
    [[ -z "${LINKS_MAP["$f"]+x}"  ]] && need=1
  fi

  if (( need == 1 )); then
    dbg "scan(on-demand): $f"
    local res fid status links
    res="$(scan_file "$f")"
    IFS=$'\t' read -r fid status links <<< "$res"

    MTIME_MAP["$f"]="$cur"
    STATUS_MAP["$f"]="$status"
    LINKS_MAP["$f"]="$links"
    PATH_TO_ID["$f"]="$fid"
    [[ -n "$fid" && "$fid" != "none" ]] && ID_MAP["$fid"]="$f"

    DIRTY["$f"]=1
  fi
}

# ------------------------------------------------------------
# 4) ツリー構築
# ------------------------------------------------------------
declare -A visited_global=()
TREE_CONTENT=""

normalize_token() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s#"${s%%[!$' \t　']*}"}"
  s="${s%"${s##*[!$' \t　']}"}"
  if [[ "$s" == \[\[*\]\] ]]; then
    s="${s#\[\[}"; s="${s%\]\]}"
  fi
  s="${s%.md}"
  s="${s#"${s%%[!$' \t　']*}"}"
  s="${s%"${s##*[!$' \t　']}"}"
  printf "%s" "$s"
}

build_tree_safe() {
  local target="$1" depth="$2" stack="$3"
  local indent="" i
  for ((i=0; i<depth; i++)); do indent+="  "; done

  target="$(normalize_token "$target")"
  if [[ -z "$target" ]]; then
    TREE_CONTENT+="${indent}- [[UNKNOWN]] ${ICON_ERROR}\n"
    dbg "MISS token(empty) depth=$depth"
    return
  fi

  local f_path="${ID_MAP["$target"]:-}"
  if [[ -z "$f_path" || ! -f "$f_path" ]]; then
    TREE_CONTENT+="${indent}- [[${target}]] ${ICON_ERROR}\n"
    dbg "MISS token=$target (not found in ID_MAP)"
    return
  fi

  ensure_meta "$f_path"

  local display_name status
  display_name="${f_path##*/}"
  display_name="${display_name%.md}"
  status="${STATUS_MAP["$f_path"]:-$ICON_OPEN}"

  if [[ "$stack" == *"[${f_path}]"* ]]; then
    TREE_CONTENT+="${indent}- [[${display_name}]] ${status}${ICON_CYCLE}\n"
    dbg "CYCLE file=$f_path"
    return
  fi
  if [[ -n "${visited_global["$f_path"]:-}" ]]; then
    TREE_CONTENT+="${indent}- [[${display_name}]] ${status}${ICON_ALREADY}\n"
    return
  fi

  visited_global["$f_path"]=1
  TREE_CONTENT+="${indent}- [[${display_name}]] ${status}\n"

  local raw_links="${LINKS_MAP["$f_path"]:-}"
  [[ -z "$raw_links" ]] && { dbg "NO_LINKS(meta-missing?) file=$f_path"; return; }
  [[ "$raw_links" == "|" ]] && return

  local old_ifs="$IFS"
  IFS='|'
  local -a children=()
  read -r -a children <<< "$raw_links"
  IFS="$old_ifs"

  local child
  for child in "${children[@]}"; do
    child="$(normalize_token "$child")"
    [[ -z "$child" ]] && continue
    build_tree_safe "$child" $((depth + 1)) "${stack}[${f_path}]"
  done
}

START_KEY="${TARGET_FILE##*/}"
START_KEY="${START_KEY%.md}"

info "Generating Tree for: $START_KEY"
build_tree_safe "$START_KEY" 0 ""

# ------------------------------------------------------------
# 5) キャッシュ保存
# ------------------------------------------------------------
if (( ${#DIRTY[@]} > 0 )) || (( CACHE_OK == 0 )); then
  info "Saving Cache... touched=${#DIRTY[@]}"
  tmp="$(mktemp "${OUTDIR}/.zk_cache_tmp.XXXXXX" 2>/dev/null || echo "${CACHE_PATH}.tmp")"

  {
    printf "%s\n" "$CACHE_MAGIC"
    for f in "${!MTIME_MAP[@]}"; do
      [[ -f "$f" ]] || continue

      m="${MTIME_MAP[$f]:-0}"
      [[ "$m" == "INVALID" ]] && continue

      links="${LINKS_MAP[$f]:-|}"
      [[ -z "$links" ]] && links="|"
      [[ "$links" != *"|"* ]] && links="|"

      printf "%s\t%s\t%s\t%s\t%s\n" \
        "$f" \
        "$m" \
        "${PATH_TO_ID[$f]:-none}" \
        "${STATUS_MAP[$f]:-$ICON_OPEN}" \
        "$links"
    done
  } > "$tmp"

  mv -f "$tmp" "$CACHE_PATH"
fi

# ------------------------------------------------------------
# 6) 出力
# ------------------------------------------------------------
{
  echo "---"
  echo "id: $(date '+%Y%m%d%H%M')-TREE-VIEW"
  echo "tags: [system, zk-archive]"
  echo "title: Status Tree - $START_KEY"
  echo "closed: $(date '+%Y-%m-%dT%H:%M:%S')"
  echo "---"
  echo "# 🌲 High-Speed Tree View: [[${START_KEY}]]"
  echo -e "$TREE_CONTENT"
} > "$OUTPUT_FILE"

info "[OK] saved to $OUTPUT_FILE"

if command -v code >/dev/null 2>&1; then
  code "$OUTPUT_FILE"
fi
