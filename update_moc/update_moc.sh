#!/usr/bin/env bash
# update_in_place.sh (FAST + idempotent, no growth)
#
# ポイント:
# - 1行に複数の [[wikilink]] があっても「左から全部」更新
# - 各リンクの直前/直後にある“自動装飾”を毎回必ず除去してから付け直す
#   -> 何回実行しても増殖しない（置換になる）
#
# Optional env:
#   ZK_DEBUG=1
#   ZK_PRUNE_DIRS="attachments,exports,archive,node_modules"
#

# --- if not running under bash, re-exec with bash (POSIX-safe) ---
[ -n "${BASH_VERSION-}" ] || exec bash "$0" "$@"

if command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qi '^c\.utf-8$'; then
  export LC_ALL=C.UTF-8
elif command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qi '^en_us\.utf-8$'; then
  export LC_ALL=en_US.UTF-8
fi

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

# --- minutes kind badge (always when tags include minutes) ---
ICON_MINUTES_NOTE="🕒 "

# --- decision kind badge (always when decision: exists) ---
ICON_DECISION_NOTE="🗳️ "

# --- decision state icons (separate layer) ---
ICON_ACCEPT="🆗 "
ICON_REJECT="❌ "
ICON_SUPER="♻️ "
ICON_DROP="💤 "
ICON_PROPOSE="📝 "

# ===== DEBUG/normalize switches =====
ZK_TRACE="${ZK_TRACE:-0}"          # 1 でデバッグ出力
ZK_TRACE_MAX="${ZK_TRACE_MAX:-30}" # 出しすぎ防止
_trace_n=0

# Variation Selector-16 (emoji presentation)
VS16=$'\uFE0F'   # "️"


hex_head() { # show first ~48 bytes in hex (for invisible diffs)
  # mac/linux/git-bash だいたい od がある前提
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

# bash 4+ required (assoc array)
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
# 文字列ユーティリティ
# -----------------------------
ltrim_wsFWSP=$'\u3000'  # 全角スペース

ltrim_ws() {
  local s="$1"
  while :; do
    case "$s" in
      " "*)    s="${s# }" ;;
      $'\t'*)  s="${s#$'\t'}" ;;
      $'\r'*)  s="${s#$'\r'}" ;;
      $'\n'*)  s="${s#$'\n'}" ;;
      $'\v'*)  s="${s#$'\v'}" ;;
      $'\f'*)  s="${s#$'\f'}" ;;
      "$FWSP"*) s="${s#"$FWSP"}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

strip_paren_group_any() {
  local s="$1"
  case "$s" in
    "("* )  printf '%s' "${s#*)}" ;;
    "（"* ) printf '%s' "${s#*）}" ;;
    * )     printf '%s' "$s" ;;
  esac
}


# strip balanced parentheses: supports "("...")" and "（"... "）"
strip_balanced_parens_any() {
  local s="$1"
  local open="${s:0:1}"
  local close=")"
  [[ "$open" == "（" ]] && close="）"

  [[ "$open" == "(" || "$open" == "（" ]] || { printf '%s' "$s"; return 0; }

  local depth=0 i ch
  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    if [[ "$ch" == "$open" ]]; then
      ((depth++))
    elif [[ "$ch" == "$close" ]]; then
      ((depth--))
      if (( depth == 0 )); then
        printf '%s' "${s:i+1}"
        return 0
      fi
    fi
  done
  printf '%s' ""  # unmatched -> drop rest
}

# s starts with '(' -> return remainder after the matching ')'
# if unmatched, return empty (drop the rest)
strip_balanced_parens() {
  local s="$1"
  [[ "${s:0:1}" == "(" ]] || { printf '%s' "$s"; return 0; }

  local depth=0 i ch
  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    if [[ "$ch" == "(" ]]; then
      ((depth++))
    elif [[ "$ch" == ")" ]]; then
      ((depth--))
      if (( depth == 0 )); then
        printf '%s' "${s:i+1}"
        return 0
      fi
    fi
  done
  printf '%s' ""
}

trim_ws_basic() {
  local s
  s="$(ltrim_ws "$1")"
  while :; do
    case "$s" in
      *" ")     s="${s% }" ;;
      *$'\t')   s="${s%$'\t'}" ;;
      *$'\r')   s="${s%$'\r'}" ;;
      *$'\n')   s="${s%$'\n'}" ;;
      *$'\v')   s="${s%$'\v'}" ;;
      *$'\f')   s="${s%$'\f'}" ;;
      *"$FWSP") s="${s%$FWSP}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

# -----------------------------
# ここが “増殖しない” の核心
#  - prefix(リンク直前)から自動アイコンを全部除去（位置がズレてても消す）
#  - suffix(リンク直後)から自動コメント/矢印を連続除去（何個でも）
# -----------------------------

# -----------------------------
# prefix: “自動付与アイコン”を確実に削除（VS16有無/末尾スペース有無も両対応）
# -----------------------------
clean_prefix_segment() {
  local s="$1"
  local icon icon_no_vs icon_no_vs_nospace icon_nospace

  for icon in \
    "$ICON_CLOSED" "$ICON_OPEN" "$ICON_ERROR" \
    "$ICON_MINUTES_NOTE" "$ICON_DECISION_NOTE" \
    "$ICON_ACCEPT" "$ICON_REJECT" "$ICON_SUPER" "$ICON_DROP" "$ICON_PROPOSE"
  do
    # 1) そのまま
    s="${s//$icon/}"

    # 2) 末尾スペース無し
    icon_nospace="${icon% }"
    [[ "$icon_nospace" != "$icon" ]] && s="${s//$icon_nospace/}"

    # 3) VS16 を落とした版（見た目同じで別文字を潰す）
    icon_no_vs="${icon//$VS16/}"
    [[ "$icon_no_vs" != "$icon" ]] && s="${s//$icon_no_vs/}"

    icon_no_vs_nospace="${icon_no_vs% }"
    [[ "$icon_no_vs_nospace" != "$icon_no_vs" ]] && s="${s//$icon_no_vs_nospace/}"
  done

  # 念のため “️”(VS16) 単体が残っても消す（見えないゴミ対策）
  s="${s//$VS16/}"
  printf '%s' "$s"

}

# -----------------------------
# suffix: link直後の “自動装飾” を連続で食べ尽くす（全角括弧にも対応）
# -----------------------------
consume_auto_suffix() {
  local orig="$1"
  local s="$orig"
  local had_ws=0 removed=0 progressed=0

  case "$s" in
    " "*|$'\t'*|'　'*) had_ws=1;;
  esac

  s="$(ltrim_ws "$s")"

  while :; do
    progressed=0

    # prio marks: ⏳ / 🧱 / 🎯（VS16 “️” 付きも剥がす）
    if [[ "$s" == ⏳* || "$s" == 🧱* || "$s" == 🎯* ]]; then
      removed=1; progressed=1

      # どのマークか判定して “そのマーク + (あればVS16)” を prefix で削る
      if [[ "$s" == ⏳$VS16* ]]; then
        s="${s#⏳$VS16}"
      elif [[ "$s" == ⏳* ]]; then
        s="${s#⏳}"
      elif [[ "$s" == 🧱$VS16* ]]; then
        s="${s#🧱$VS16}"
      elif [[ "$s" == 🧱* ]]; then
        s="${s#🧱}"
      elif [[ "$s" == 🎯$VS16* ]]; then
        s="${s#🎯$VS16}"
      elif [[ "$s" == 🎯* ]]; then
        s="${s#🎯}"
      fi

      # アイコン直後に VS16 が単独で残るケースも掃除
      while [[ "$s" == "$VS16"* ]]; do
        s="${s#"$VS16"}"
      done

      s="$(ltrim_ws "$s")"

      # optional "(...)" or "（...）"
      if [[ "$s" == \(* || "$s" == （* ]]; then
        s="$(strip_paren_group_any "$s")"
      fi
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

  # debug: “剥がすべきっぽいのに残ってる”を検知
  if (( ZK_TRACE )); then
    local t
    t="$(ltrim_ws "$orig")"
    if [[ "$t" == ⏳* || "$t" == 🧱* || "$t" == 🎯* || "$t" == \(→* || "$t" == （→* ]]; then
      local t2
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
# 1) Vault内mdを一度だけ索引化（findの多重起動を撲滅）
# -----------------------------
declare -A FILE_MAP=()    # key: basename(no ext) -> fullpath
declare -A FILE_MAP_MD=() # key: basename(with .md) -> fullpath

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

  if [[ -z "${FILE_MAP["$base_no_ext"]+x}" ]]; then
    FILE_MAP["$base_no_ext"]="$f"
  fi
  if [[ -z "${FILE_MAP_MD["$base"]+x}" ]]; then
    FILE_MAP_MD["$base"]="$f"
  fi
  FILE_COUNT=$((FILE_COUNT+1))
done < "$LIST_TMP"

rm -f "$LIST_TMP" 2>/dev/null || true

(( FILE_COUNT > 0 )) || { echo "[ERR] vault scan returned 0 md files. VAULT_ROOT is wrong?" >&2; exit 1; }
dbg "Indexed md count=$FILE_COUNT"

resolve_file_path_fast() {
  local filename="$1"  # "xxx.md" or "xxx"

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
# 2) リンク先メタ情報を mtime でキャッシュ
# -----------------------------
declare -A META_MTIME=()
declare -A META_INFO=()  # fpath -> "life<TAB>min<TAB>kind<TAB>dec<TAB>prio<TAB>text<TAB>arrow"

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
    if(a_txt=="" && low ~ /@awaiting/){ a_txt=line; sub(/.*@awaiting[[:space:]]*/, "", a_txt); a_txt=trim(a_txt) }
    if(b_txt=="" && low ~ /@blocked/ ){ b_txt=line; sub(/.*@blocked[[:space:]]*/,  "", b_txt); b_txt=trim(b_txt) }
    if(f_txt=="" && low ~ /@focus/   ){ f_txt=line; sub(/.*@focus[[:space:]]*/,    "", f_txt); f_txt=trim(f_txt) }
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
      if(a_txt!=""){ prio="⏳"; text=a_txt }
      else if(b_txt!=""){ prio="🧱"; text=b_txt }
      else if(f_txt!=""){ prio="🎯"; text=f_txt }
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
# 3) 本体: 1行の中の [[...]] を左から全部処理（ここが重要）
# -----------------------------
while IFS= read -r line || [[ -n "$line" ]]; do
  # まず quick check
  if [[ "$line" != *\[\[* ]]; then
    printf '%s\n' "$line" >> "$TEMP_FILE"
    continue
  fi

  rest="$line"
  out=""

  # [[...]] を左から順に処理
  while [[ "$rest" == *\[\[* ]]; do
    pre="${rest%%\[\[*}"        # first [[ の手前
    after_open="${rest#*\[\[}"  # first [[ の後ろ

    # 閉じ ]] が無いなら壊さずに終了
    if [[ "$after_open" != *"]]"* ]]; then
      out+="$rest"
      rest=""
      break
    fi

    inside="${after_open%%]]*}"     # [[ ... ]] の中身
    after_close="${after_open#*]]}" # ]] の後ろ

    # このリンクの直後に付いている “自動装飾” を食べて消す（増殖対策）
    after_close="$(consume_auto_suffix "$after_close")"

    # inside を target / alias に分解（表示は維持）
    link_target="$inside"
    link_alias=""
    if [[ "$inside" == *"|"* ]]; then
      link_target="${inside%%|*}"
      link_alias="|${inside#*|}"
    fi

    # 解決対象は link_target 側（#anchor も含むがファイル解決は # より前）
    target_filepart="${link_target%%#*}"
    target_filepart="$(trim_ws_basic "$target_filepart")"

    # prefix からは “自動アイコン” を全部消す（乱暴だが確実）
    pre_clean="$(clean_prefix_segment "$pre")"

    if [[ -z "$target_filepart" ]]; then
      # 空リンクはそのまま
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

    # 組み立て（この時点で「過去の装飾」は必ず消えているので増えない）
    out+="${pre_clean}${life_icon:-$ICON_OPEN}${minutes_icon:-}${kind_icon:-}${dec_icon:-}[[${link_target}${link_alias}]]${prio_part}${arrow_part}"

    # 次のリンクへ
    rest="$after_close"
  done
  # 残りを付けて1行完成
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
