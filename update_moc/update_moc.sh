#!/usr/bin/env bash
# update_in_place.sh (Aggressive Prefix Clean)
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

# --- Icons ---
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

VS16=$'\uFE0F'

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
  echo "[ERR] bash >= 4 required." >&2
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

OS_NAME="$(uname)"
STAT_CMD=(stat -c %Y)
if [[ "$OS_NAME" == "Darwin" ]]; then
  STAT_CMD=(stat -f %m)
fi

# -----------------------------
# String Utils
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
      *"$FWSP")  s="${s%$FWSP}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

trim_ws() { trim_ws_basic "$1"; }

# 括弧の中身を安全に食う
strip_paren_group_any() {
  local s="$1"
  case "$s" in
    "("* )  printf '%s' "${s#*)}" ;;
    "（"* ) printf '%s' "${s#*）}" ;;
    * )     printf '%s' "$s" ;;
  esac
}

# アイコン直後のテキスト（括弧または単語）を食う
consume_prio_text_token() {
  local s="$1"
  while [[ "$s" == "$VS16"* ]]; do s="${s#"$VS16"}"; done
  s="$(ltrim_ws "$s")"

  if [[ "$s" == \(* || "$s" == （* ]]; then
    s="$(strip_paren_group_any "$s")"
    printf '%s' "$s"
    return 0
  fi

  while [[ -n "$s" ]]; do
    case "$s" in
      " "*|$'\t'*|$'\r'*|$'\n'*|$'\v'*|$'\f'*|"$FWSP"*) break ;;
      *) s="${s:1}" ;;
    esac
  done
  printf '%s' "$s"
}

starts_with_icon() {
  local str="$1"
  local icon="$2"
  [[ "$str" == "$icon"* ]] && return 0
  [[ "$str" == "${icon}${VS16}"* ]] && return 0
  return 1
}

strip_icon_head() {
  local str="$1"
  local icon="$2"
  if [[ "$str" == "${icon}${VS16}"* ]]; then
    printf '%s' "${str#"${icon}${VS16}"}"
  elif [[ "$str" == "$icon"* ]]; then
    printf '%s' "${str#"$icon"}"
  else
    printf '%s' "$str"
  fi
}

# ★行頭の構造（インデント＋リスト記号）だけを抽出し、それ以外を捨てる
extract_list_structure() {
  local s="$1"
  if [[ "$s" =~ ^([[:space:]]*[-*+][[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$s" =~ ^([[:space:]]*[0-9]+\.[[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$s" =~ ^([[:space:]]*) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  printf ''
}

clean_prefix_segment() {
  local s="$1"
  local changed=1
  local icons=(
    "$ICON_CLOSED" "$ICON_OPEN" "$ICON_ERROR"
    "$ICON_MINUTES_NOTE" "$ICON_DECISION_NOTE"
    "$ICON_ACCEPT" "$ICON_REJECT" "$ICON_SUPER" "$ICON_DROP" "$ICON_PROPOSE"
  )
  while (( changed )); do
    changed=0
    s="$(ltrim_ws "$s")"
    for icon_raw in "${icons[@]}"; do
      local icon_nosp="${icon_raw% }"
      if starts_with_icon "$s" "$icon_raw"; then
        s="$(strip_icon_head "$s" "$icon_raw")"
        changed=1; break
      elif starts_with_icon "$s" "$icon_nosp"; then
        s="$(strip_icon_head "$s" "$icon_nosp")"
        changed=1; break
      fi
    done
  done
  while [[ "$s" == "$VS16"* ]]; do s="${s#"$VS16"}"; done
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
    for icon in "⏳" "🧱" "🎯"; do
      if starts_with_icon "$s" "$icon"; then
        removed=1; progressed=1
        s="$(strip_icon_head "$s" "$icon")"
        while [[ "$s" == "$VS16"* ]]; do s="${s#"$VS16"}"; done
        s="$(ltrim_ws "$s")"
        s="$(consume_prio_text_token "$s")"
        s="$(ltrim_ws "$s")"
        break
      fi
    done
    (( progressed )) && continue

    if [[ "$s" == \(→* || "$s" == （→* ]]; then
      removed=1; progressed=1
      s="$(strip_paren_group_any "$s")"
      s="$(ltrim_ws "$s")"
    fi
    (( progressed )) && continue

    break
  done

  if [[ -z "$s" ]]; then
    printf '%s' ""
    return 0
  fi
  if (( had_ws || removed )); then
    printf ' %s' "$s"
  else
    printf '%s' "$s"
  fi
}

# ★【追加】prio を必ず「左側」に出すための整形（末尾スペース込み）
format_prio_prefix() {
  local icon="${1:-}"
  local text="${2:-}"
  if [[ -z "$icon" ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ -n "$text" ]]; then
    printf '%s(%s) ' "$icon" "$text"
  else
    printf '%s ' "$icon"
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
      if [[ "$f" == *"/$d/"* ]]; then skip=1; break; fi
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
(( FILE_COUNT > 0 )) || { echo "[ERR] vault scan returned 0 md files." >&2; exit 1; }

resolve_file_path_fast() {
  local filename="$1"
  if [[ -f "$PARENT_DIR/$filename" ]]; then printf '%s\n' "$PARENT_DIR/$filename"; return 0; fi
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
  function trim(s){ sub(/^\xef\xbb\xbf/, "", s); gsub(/\r/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function strip_quotes(v){ v=trim(v); gsub(/^"+|"+$/, "", v); gsub(/^\047+|\047+$/, "", v); return v }
  function tolower_ascii(s, out, i, c){
    out=""; for(i=1;i<=length(s);i++){ c=substr(s,i,1); if(c>="A" && c<="Z") c=tolower(c); out=out c }
    return out
  }
  BEGIN{
    IGNORECASE=1; in_fm=0; first=0; closed=0; decision=""; sup_by=""; is_minutes=0; prio_set=0;
  }
  {
    line=$0; sub(/\r$/, "", line); t=trim(line);
    if(NR==1) sub(/^\xef\xbb\xbf/, "", t)

    if(!first){
      if(t=="") next
      first=1
      if(t ~ /^---[ \t]*$/){ in_fm=1; next }
    }
    if(in_fm){
      if(t ~ /^---[ \t]*$/){ in_fm=0; next }
      if(t ~ /^closed:[ \t]*/){ closed=1 }
      if(t ~ /^decision:[ \t]*/){ sub(/^decision:[ \t]*/, "", t); decision=tolower_ascii(trim(t)) }
      if(t ~ /^superseded_by:[ \t]*/){ sub(/^superseded_by:[ \t]*/, "", t); sup_by=strip_quotes(t) }
      if(t ~ /minutes/){ is_minutes=1 }
      next
    }
    low=tolower(line)
    if(prio_set==0){
      if(index(low,"@awaiting")){ prio_icon="⏳"; sub(/.*@awaiting[[:space:]]*/, "", line); prio_text=trim(line); prio_set=1 }
      else if(index(low,"@blocked")){ prio_icon="🧱"; sub(/.*@blocked[[:space:]]*/, "", line); prio_text=trim(line); prio_set=1 }
      else if(index(low,"@focus")){ prio_icon="🎯"; sub(/.*@focus[[:space:]]*/, "", line); prio_text=trim(line); prio_set=1 }
    }
  }
  END{
    life=(closed?ic:io); min=(is_minutes?imin:""); kind=(decision!=""?idec:"");
    dec="";
    if(decision=="accepted") dec=iacc; else if(decision=="rejected") dec=irej;
    else if(decision=="superseded") dec=isup; else if(decision=="dropped") dec=idrp;
    else if(decision!="") dec=iprp;

    prio=""; text="";
    if(!(decision ~ /^(accepted|rejected|superseded|dropped)$/) && prio_set==1){
       prio=prio_icon; text=prio_text;
    }
    arrow=""; if(decision=="superseded" && sup_by!=""){ arrow=sup_by; }

    gsub(/\t/, " ", text); gsub(/\t/, " ", arrow);
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", life, min, kind, dec, prio, text, arrow
  }' "$f_path"
}

ensure_meta() {
  local f_path="$1"
  [[ -f "$f_path" ]] || return 1
  local cur
  cur="$("${STAT_CMD[@]}" "$f_path" 2>/dev/null || echo 0)"
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

    # Suffix Cleanup（右側に残ってる⏳(xxx)等はここで除去）
    after_close="$(consume_auto_suffix "$after_close")"

    link_target="$inside"
    link_alias=""
    if [[ "$inside" == *"|"* ]]; then
      link_target="${inside%%|*}"
      link_alias="|${inside#*|}"
    fi

    target_filepart="${link_target%%#*}"
    target_filepart="$(trim_ws_basic "$target_filepart")"

    # Prefix Cleanup: Aggressive
    if (( first_link_in_line )); then
      pre_clean="$(extract_list_structure "$pre")"
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

    # ★prio は「リンクの左」に出す（末尾スペース込み）
    prio_prefix="$(format_prio_prefix "${pr_icon:-}" "${extra_txt:-}")"

    arrow_part=""
    if [[ -n "${arrow_txt:-}" ]]; then
      arrow_part=" (→ ${arrow_txt})"
    fi

    # ★順番を変更：... prio_prefix + [[link]] ...
    out+="${pre_clean}${life_icon:-$ICON_OPEN}${minutes_icon:-}${kind_icon:-}${dec_icon:-}${prio_prefix}[[${link_target}${link_alias}]]${arrow_part}"
    rest="$after_close"
  done

  out+="$rest"
  printf '%s\n' "$out" >> "$TEMP_FILE"
done < "$TARGET_FILE"

mv "$TEMP_FILE" "$TARGET_FILE"
echo "Updated: $TARGET_FILE"
