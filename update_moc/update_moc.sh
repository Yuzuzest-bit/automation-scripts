#!/usr/bin/env bash
# update_in_place.sh (FAST + idempotent, no growth)
#
# Optional env:
#   ZK_DEBUG=1
#   ZK_TRACE=1
#   ZK_TRACE_MAX=80
#   ZK_PRUNE_DIRS="attachments,exports,archive,node_modules"
#

[ -n "${BASH_VERSION-}" ] || exec bash "$0" "$@"

if command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qi '^c\.utf-8$'; then
  export LC_ALL=C.UTF-8
elif command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qi '^en_us\.utf-8$'; then
  export LC_ALL=en_US.UTF-8
fi

set -Eeuo pipefail
trap 'rc=$?; printf "[ERR] exit=%d line=%d cmd=%s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

TARGET_FILE="${1:-}"

ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "

ICON_FOCUS="🎯"
ICON_AWAIT="⏳"
ICON_BLOCK="🧱"

ICON_MINUTES_NOTE="🕒 "
ICON_DECISION_NOTE="🗳️ "

ICON_ACCEPT="🆗 "
ICON_REJECT="❌ "
ICON_SUPER="♻️ "
ICON_DROP="💤 "
ICON_PROPOSE="📝 "

ZK_TRACE="${ZK_TRACE:-0}"
ZK_TRACE_MAX="${ZK_TRACE_MAX:-30}"
_trace_n=0

VS16=$'\uFE0F'   # "️"

hex_head() {
  printf '%s' "$1" | LC_ALL=C od -An -tx1 -v 2>/dev/null | tr -d ' \n' | cut -c1-96
}
trace() {
  (( ZK_TRACE )) || return 0
  ((_trace_n++))
  ((_trace_n > ZK_TRACE_MAX)) && return 0
  printf '[TRACE] %s\n' "$*" >&2
}

ZK_DEBUG="${ZK_DEBUG:-0}"
dbg(){ if [[ "${ZK_DEBUG}" != 0 ]]; then printf '[DBG] %s\n' "$*" >&2; fi; }

if (( BASH_VERSINFO[0] < 4 )); then
  echo "[ERR] bash >= 4 required. Please run with Git Bash / MSYS2 bash 4+." >&2
  exit 2
fi

if [[ -z "${TARGET_FILE}" ]]; then
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

TARGET_FILE="$(to_posix "$TARGET_FILE")"
TARGET_FILE="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)/${TARGET_FILE##*/}"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "Error: File not found: $TARGET_FILE" >&2
  exit 1
fi

PARENT_DIR="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
TEMP_FILE="$(mktemp)"

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

OS_NAME="$(uname)"
STAT_CMD=(stat -c %Y)
if [[ "$OS_NAME" == "Darwin" ]]; then
  STAT_CMD=(stat -f %m)
fi

# -----------------------------
# string utils (no ${s:0:1})
# -----------------------------
FWSP=$'\u3000'

ltrim_ws() {
  local s="$1"
  while :; do
    case "$s" in
      " "*)      s="${s# }" ;;
      $'\t'*)    s="${s#$'\t'}" ;;
      $'\r'*)    s="${s#$'\r'}" ;;
      $'\n'*)    s="${s#$'\n'}" ;;
      $'\v'*)    s="${s#$'\v'}" ;;
      $'\f'*)    s="${s#$'\f'}" ;;
      "$FWSP"*)  s="${s#"$FWSP"}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

trim_ws_basic() {
  local s
  s="$(ltrim_ws "$1")"
  while :; do
    case "$s" in
      *" ")      s="${s% }" ;;
      *$'\t')    s="${s%$'\t'}" ;;
      *$'\r')    s="${s%$'\r'}" ;;
      *$'\n')    s="${s%$'\n'}" ;;
      *$'\v')    s="${s%$'\v'}" ;;
      *$'\f')    s="${s%$'\f'}" ;;
      *"$FWSP")  s="${s%$FWSP}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

# ★ここが今回のエラー対策（trim_ws 未定義を潰す）
trim_ws() { trim_ws_basic "$1"; }

# ★追加：先頭インデント（空白/タブ/全角スペース等）だけを抽出して返す
leading_ws() {
  local s="$1"
  local out=""
  while :; do
    case "$s" in
      " "*)      out+=" ";      s="${s# }" ;;
      $'\t'*)    out+=$'\t';    s="${s#$'\t'}" ;;
      $'\r'*)    out+=$'\r';    s="${s#$'\r'}" ;;
      $'\n'*)    out+=$'\n';    s="${s#$'\n'}" ;;
      $'\v'*)    out+=$'\v';    s="${s#$'\v'}" ;;
      $'\f'*)    out+=$'\f';    s="${s#$'\f'}" ;;
      "$FWSP"*)  out+="$FWSP";  s="${s#"$FWSP"}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$out"
}

# prioアイコン直後の「説明文字」も剥がす
# - "(...)" / "（...）" があればそれを消す
# - 無ければ「次の空白まで」を1トークンとして消す（⏳待ち 等を想定）
consume_prio_text_token() {
  local s="$1"

  # 先頭のVS16ゴミを掃除
  while [[ "$s" == "$VS16"* ]]; do
    s="${s#"$VS16"}"
  done

  s="$(ltrim_ws "$s")"

  # 括弧があれば括弧ごと捨てる
  if [[ "$s" == \(* || "$s" == （* ]]; then
    s="$(strip_paren_group_any "$s")"
    printf '%s' "$s"
    return 0
  fi

  # 括弧なし → 次の空白までを捨てる（日本語でも空白まで）
  while [[ -n "$s" ]]; do
    case "$s" in
      " "*|$'\t'*|$'\r'*|$'\n'*|$'\v'*|$'\f'*|"$FWSP"*) break ;;
      *) s="${s:1}" ;;
    esac
  done
  printf '%s' "$s"
}

# "(...)" / "（...）" を最初の閉じ括弧まで食う（安全）
strip_paren_group_any() {
  local s="$1"
  case "$s" in
    "("* )  printf '%s' "${s#*)}" ;;
    "（"* ) printf '%s' "${s#*）}" ;;
    * )     printf '%s' "$s" ;;
  esac
}

clean_prefix_segment() {
  local s="$1"
  local icon icon_no_vs icon_no_vs_nospace icon_nospace

  for icon in \
    "$ICON_CLOSED" "$ICON_OPEN" "$ICON_ERROR" \
    "$ICON_MINUTES_NOTE" "$ICON_DECISION_NOTE" \
    "$ICON_ACCEPT" "$ICON_REJECT" "$ICON_SUPER" "$ICON_DROP" "$ICON_PROPOSE"
  do
    s="${s//$icon/}"

    icon_nospace="${icon% }"
    [[ "$icon_nospace" != "$icon" ]] && s="${s//$icon_nospace/}"

    icon_no_vs="${icon//$VS16/}"
    [[ "$icon_no_vs" != "$icon" ]] && s="${s//$icon_no_vs/}"

    icon_no_vs_nospace="${icon_no_vs% }"
    [[ "$icon_no_vs_nospace" != "$icon_no_vs" ]] && s="${s//$icon_no_vs_nospace/}"
  done

  s="${s//$VS16/}"
  printf '%s' "$s"
}

consume_auto_suffix() {
  local orig="$1"
  local s="$orig"
  local had_ws=0 removed=0 progressed=0

  case "$s" in
    " "*|$'\t'*|"$FWSP"*) had_ws=1;;
  esac

  s="$(ltrim_ws "$s")"

  while :; do
    progressed=0

    # prio marks: ⏳ / 🧱 / 🎯（VS16 “️” 付きも含む）
    if [[ "$s" == ⏳* || "$s" == 🧱* || "$s" == 🎯* ]]; then
      removed=1; progressed=1

      # アイコン本体を剥がす（VS16付きも対応）
      if   [[ "$s" == ⏳$VS16* ]]; then s="${s#⏳$VS16}"
      elif [[ "$s" == ⏳*      ]]; then s="${s#⏳}"
      elif [[ "$s" == 🧱$VS16* ]]; then s="${s#🧱$VS16}"
      elif [[ "$s" == 🧱*      ]]; then s="${s#🧱}"
      elif [[ "$s" == 🎯$VS16* ]]; then s="${s#🎯$VS16}"
      elif [[ "$s" == 🎯*      ]]; then s="${s#🎯}"
      fi

      # アイコン直後に残るVS16単体も掃除
      while [[ "$s" == "$VS16"* ]]; do
        s="${s#"$VS16"}"
      done

      s="$(ltrim_ws "$s")"

      # ★ここが追加：絵文字の横の「文字」も剥がす（括弧 or 1トークン）
      s="$(consume_prio_text_token "$s")"
      s="$(ltrim_ws "$s")"
    fi

    # arrow part: (→ ... ) / （→ ...）
    if [[ "$s" == \(→* || "$s" == （→* ]]; then
      removed=1; progressed=1
      s="$(strip_paren_group_any "$s")"
      s="$(ltrim_ws "$s")"
    fi

    (( progressed )) || break
  done

  if (( ZK_TRACE )); then
    local t t2
    t="$(ltrim_ws "$orig")"
    if [[ "$t" == ⏳* || "$t" == 🧱* || "$t" == 🎯* || "$t" == \(→* || "$t" == （→* ]]; then
      t2="$(ltrim_ws "$s")"
      if [[ "$t2" == ⏳* || "$t2" == 🧱* || "$t2" == 🎯* || "$t2" == \(→* || "$t2" == （→* ]]; then
        trace "suffix NOT fully consumed"
        trace "  raw(head) : $(printf '%s' "$orig" | head -c 80)"
        trace "  left(head): $(printf '%s' "$s" | head -c 80)"
        trace "  raw(hex)  : $(hex_head "$orig")"
        trace "  left(hex) : $(hex_head "$s")"
      fi
    fi
  fi

  if [[ -z "$s" ]]; then
    printf '%s' ""
    return 0
  fi

  # もともと空白があった or 何か剥がしたなら区切り空白1個を付ける
  if (( had_ws || removed )); then
    printf ' %s' "$s"
  else
    printf '%s' "$s"
  fi
}

# -----------------------------
# 1) index vault md
# -----------------------------
declare -A FILE_MAP=()
declare -A FILE_MAP_MD=()

PRUNE_DIRS="${ZK_PRUNE_DIRS:-}"
IFS=',' read -r -a PRUNE_ARR <<< "$PRUNE_DIRS"
unset IFS

LIST_TMP="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/zk_md_list.$$")"
find "$VAULT_ROOT" -path "*/.*" -prune -o -type f -name "*.md" -print0 2>/dev/null > "$LIST_TMP" || true

dbg "Indexing md files..."
FILE_COUNT=0
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue

  if [[ "${#PRUNE_ARR[@]}" -gt 0 ]]; then
    skip=0
    for d in "${PRUNE_ARR[@]}"; do
      d="$(trim_ws_basic "$d")"
      [[ -z "$d" ]] && continue
      if [[ "$f" == *"/$d/"* ]]; then
        skip=1
        break
      fi
    done
    (( skip == 1 )) && continue
  fi

  base="${f##*/}"
  base_no_ext="${base%.md}"

  [[ -z "${FILE_MAP["$base_no_ext"]+x}" ]] && FILE_MAP["$base_no_ext"]="$f"
  [[ -z "${FILE_MAP_MD["$base"]+x}" ]] && FILE_MAP_MD["$base"]="$f"
  FILE_COUNT=$((FILE_COUNT+1))
done < "$LIST_TMP"

rm -f "$LIST_TMP" 2>/dev/null || true

(( FILE_COUNT > 0 )) || { echo "[ERR] vault scan returned 0 md files. VAULT_ROOT is wrong?" >&2; exit 1; }
dbg "Indexed md count=$FILE_COUNT"

resolve_file_path_fast() {
  local filename="$1"
  if [[ -f "$PARENT_DIR/$filename" ]]; then
    printf '%s\n' "$PARENT_DIR/$filename"
    return 0
  fi

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

  printf '%s\n' ""
}

# -----------------------------
# 2) meta cache by mtime
# -----------------------------
declare -A META_MTIME=()
declare -A META_INFO=()

scan_meta() {
  local f_path="$1"
  awk \
    -v ic="$ICON_CLOSED" -v io="$ICON_OPEN" \
    -v imin="$ICON_MINUTES_NOTE" \
    -v idec="$ICON_DECISION_NOTE" \
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
  function tolower_ascii(s, out, i, c){
    out=""
    for(i=1;i<=length(s);i++){
      c=substr(s,i,1)
      if(c>="A" && c<="Z") c=tolower(c)
      out=out c
    }
    return out
  }

  BEGIN{
    IGNORECASE=1
    in_fm=0; first=0;
    closed=0; decision=""; sup_by="";
    in_code=0; fence_ch=""; fence_len=0;

    in_tags_block=0
    is_minutes=0

    a_txt=""; b_txt=""; f_txt="";
  }

  {
    line=$0
    sub(/\r$/, "", line)
    if(NR==1){ sub(/^\xef\xbb\xbf/, "", line) }
    t=trim(line)

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
        decision=tolower_ascii(trim(t))
      }

      if(t ~ /^superseded_by:[ \t]*/){
        sub(/^superseded_by:[ \t]*/, "", t)
        sup_by=strip_quotes(t)
      }

      if(t ~ /^tags:[ \t]*\[/){
        v=t
        sub(/^tags:[ \t]*\[/, "", v)
        sub(/\][ \t]*$/, "", v)
        n=split(v, arr, ",")
        for(i=1;i<=n;i++){
          tag=strip_quotes(arr[i])
          tag=tolower_ascii(trim(tag))
          if(tag=="minutes"){ is_minutes=1 }
        }
        in_tags_block=0
      } else if(t ~ /^tags:[ \t]*$/){
        in_tags_block=1
      } else if(t ~ /^tags:[ \t]*/){
        v=t
        sub(/^tags:[ \t]*/, "", v)
        tag=tolower_ascii(strip_quotes(v))
        if(tag=="minutes"){ is_minutes=1 }
        in_tags_block=0
      } else if(in_tags_block==1){
        if(t ~ /^-[ \t]*/){
          v=t
          sub(/^-+[ \t]*/, "", v)
          tag=tolower_ascii(strip_quotes(v))
          if(tag=="minutes"){ is_minutes=1 }
        } else if(t ~ /^[A-Za-z0-9_.-]+:[ \t]*/){
          in_tags_block=0
        }
      }

      next
    }

    u=trim(line)
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
        if(n>=3){ fence_ch=c; fence_len=n; in_code=1; next }
      }
    }

low=tolower(line)

# まだ何も選ばれていない時だけ、「最初に現れたもの」を採用する
if(prio_set==0){
  pa=index(low,"@awaiting")
  pb=index(low,"@blocked")
  pf=index(low,"@focus")

  best=0
  tag=""
  if(pa>0 && (best==0 || pa<best)){ best=pa; tag="awaiting" }
  if(pb>0 && (best==0 || pb<best)){ best=pb; tag="blocked" }
  if(pf>0 && (best==0 || pf<best)){ best=pf; tag="focus" }

  if(best>0){
    tmp=line
    if(tag=="awaiting"){
      prio_icon="⏳"
      sub(/.*@awaiting[[:space:]]*/, "", tmp)
    } else if(tag=="blocked"){
      prio_icon="🧱"
      sub(/.*@blocked[[:space:]]*/, "", tmp)
    } else if(tag=="focus"){
      prio_icon="🎯"
      sub(/.*@focus[[:space:]]*/, "", tmp)
    }
    prio_text=trim(tmp)
    prio_set=1
  }
  }

  END{
    life = (closed?ic:io)

    min = (is_minutes?imin:"")
    kind = (decision!="" ? idec : "")

    dec=""
    if(decision!=""){
      if(decision=="accepted") dec=iacc
      else if(decision=="rejected") dec=irej
      else if(decision=="superseded") dec=isup
      else if(decision=="dropped") dec=idrp
      else dec=iprp
    }

prio=""; text=""
if(!(decision ~ /^(accepted|rejected|superseded|dropped)$/)){
  if(prio_set==1){
    prio=prio_icon
    text=prio_text
  }
}

    arrow=""
    if(decision=="superseded" && sup_by!=""){ arrow=sup_by }

    gsub(/\t/, " ", text)
    gsub(/\t/, " ", arrow)

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", life, min, kind, dec, prio, text, arrow
  }' "$f_path"
}

ensure_meta() {
  local f_path="$1"
  [[ -f "$f_path" ]] || return 1

  local cur
  cur="$("${STAT_CMD[@]}" "$f_path" 2>/dev/null || echo 0)"
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=0

  if [[ "${META_MTIME["$f_path"]:-}" != "$cur" ]]; then
    META_INFO["$f_path"]="$(scan_meta "$f_path")"
    META_MTIME["$f_path"]="$cur"
  fi
  return 0
}

get_link_info_fast() {
  local f_path="$1"
  if [[ -z "$f_path" || ! -f "$f_path" ]]; then
    printf "%s\t\t\t\t\t\t\n" "$ICON_ERROR"
    return 0
  fi
  ensure_meta "$f_path" || { printf "%s\t\t\t\t\t\t\n" "$ICON_ERROR"; return 0; }
  printf "%s\n" "${META_INFO["$f_path"]}"
}

# -----------------------------
# 3) main
# -----------------------------
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" != *\[\[* ]]; then
    printf '%s\n' "$line" >> "$TEMP_FILE"
    continue
  fi

  rest="$line"
  out=""

  # ★追加：この行の「最初の wikilink」だけ、行頭〜[[ を全消し（インデントだけ残す）
  first_link_in_line=1

  while [[ "$rest" == *\[\[* ]]; do
    pre="${rest%%\[\[*}"
    after_open="${rest#*\[\[}"

    if [[ "$after_open" != *"]]"* ]]; then
      out+="$rest"
      rest=""
      break
    fi

    inside="${after_open%%]]*}"
    after_close="${after_open#*]]}"

    after_close="$(consume_auto_suffix "$after_close")"

    link_target="$inside"
    link_alias=""
    if [[ "$inside" == *"|"* ]]; then
      link_target="${inside%%|*}"
      link_alias="|${inside#*|}"
    fi

    target_filepart="${link_target%%#*}"
    target_filepart="$(trim_ws_basic "$target_filepart")"

    # ★ここが変更点
    # - 行頭の最初の[[の左側は「インデントだけ」残して完全に捨てる
    # - 2つ目以降は従来通り（間のテキストは残す）
    if (( first_link_in_line )); then
      pre_clean="$(leading_ws "$pre")"
      first_link_in_line=0
    else
      pre_clean="$(clean_prefix_segment "$pre")"
    fi

    if [[ -z "$target_filepart" ]]; then
      out+="$pre_clean[[${inside}]]"
      rest="$after_close"
      continue
    fi

    if [[ "$target_filepart" != *.md ]]; then
      filename="${target_filepart}.md"
    else
      filename="$target_filepart"
    fi

    resolved_path="$(resolve_file_path_fast "$filename")"

    info_line="$(get_link_info_fast "$resolved_path")"
    IFS=$'\t' read -r life_icon minutes_icon kind_icon dec_icon pr_icon extra_txt arrow_txt <<< "$info_line"
    unset IFS

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

    out+="${pre_clean}${life_icon:-$ICON_OPEN}${minutes_icon:-}${kind_icon:-}${dec_icon:-}[[${link_target}${link_alias}]]${prio_part}${arrow_part}"
    rest="$after_close"
  done

  out+="$rest"
  if (( ZK_TRACE )); then
    if [[ "$line" != "$out" ]]; then
      trace "LINE changed"
      trace "  IN : $line"
      trace "  OUT: $out"
    fi
  fi
  printf '%s\n' "$out" >> "$TEMP_FILE"
done < "$TARGET_FILE"

mv "$TEMP_FILE" "$TARGET_FILE"
echo "Updated: $TARGET_FILE"
