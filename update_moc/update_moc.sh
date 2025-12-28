#!/usr/bin/env bash
# update_in_place.sh

export LC_ALL=C.UTF-8
set -euo pipefail

TARGET_FILE="${1:-}"

VAULT_ROOT="$(pwd -P)"

# --- lifecycle icons (open/closed/error) ---
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "

# --- markers (suffix) ---
ICON_FOCUS="🎯"
ICON_AWAIT="⏳"
ICON_BLOCK="🧱"

# --- decision state icons (separate layer) ---
# NOTE: accepted は closed(✅) と被るので、別アイコンに変更
ICON_ACCEPT="🆗 "
ICON_REJECT="❌ "
ICON_SUPER="♻️ "
ICON_DROP="💤 "
ICON_PROPOSE="📝 "

if [[ -z "$TARGET_FILE" ]]; then
  echo "usage: $0 <target.md>" >&2
  exit 2
fi

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "Error: File not found: $TARGET_FILE" >&2
  exit 1
fi

PARENT_DIR="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
TEMP_FILE="$(mktemp)"

resolve_file_path() {
  local target_name="$1"
  if [[ -f "$PARENT_DIR/$target_name" ]]; then
    echo "$PARENT_DIR/$target_name"
    return
  fi
  find "$VAULT_ROOT" -maxdepth 6 -name "$target_name" -not -path "*/.*" -print -quit 2>/dev/null
}

# 先頭(prefix)から「既存アイコン」を剥がす（何回実行しても増殖しない）
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

# リンク直後(suffix)から marker と (→ xxx) を剥がす
clean_suffix() {
  local s="$1"
  echo "$s" | sed -E \
    -e 's/^[[:space:]]*(🎯|🧱|⏳)\([^)]*\)//' \
    -e 's/^[[:space:]]*\(→[^)]*\)//'
}

# frontmatter 先頭80行程度から decision: を読む
get_decision_state() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && { echo ""; return; }
  head -n 80 "$f_path" | tr -d '\r' | awk '
    BEGIN{ inFM=0; started=0 }
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      line=$0
      t=line
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if(started==0){
        if(t=="") next
        started=1
        if(t=="---"){ inFM=1; next } else { exit }
      }
      if(inFM==1){
        if(t=="---"){ exit }
        if(t ~ /^decision:[ \t]*/){
          sub(/^decision:[ \t]*/, "", t)
          t=trim(t)
          out=""
          for(i=1;i<=length(t);i++){
            c=substr(t,i,1)
            if(c>="A" && c<="Z") c=tolower(c)
            out=out c
          }
          print out
          exit
        }
      }
    }'
}

# superseded_by を読む（"xxx.md" 形式の文字列想定。quoteは剥がす）
get_superseded_by() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && { echo ""; return; }
  head -n 120 "$f_path" | tr -d '\r' | awk '
    BEGIN{ inFM=0; started=0 }
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function stripq(s){
      s=trim(s)
      gsub(/^"+|"+$/, "", s)
      gsub(/^\047+|\047+$/, "", s)  # single quote
      gsub(/^\140+|\140+$/, "", s)  # backtick
      return s
    }
    {
      line=$0
      t=line
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if(started==0){
        if(t=="") next
        started=1
        if(t=="---"){ inFM=1; next } else { exit }
      }
      if(inFM==1){
        if(t=="---"){ exit }
        if(t ~ /^superseded_by:[ \t]*/){
          sub(/^superseded_by:[ \t]*/, "", t)
          t=stripq(t)
          print t
          exit
        }
      }
    }'
}

# closed の判定（decisionの有無に関係なく別レイヤで表示）
has_closed() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && return 1
  head -n 40 "$f_path" | tr -d '\r' | grep -qE '^closed:[[:space:]]*.+'
}

# リンク先の状態を取得
# 戻り: life|decision|prio|text|arrow
get_link_info() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && { echo "$ICON_ERROR||||"; return; }

  local life="$ICON_OPEN"
  local dec=""
  local prio=""
  local text=""
  local arrow=""
  local dstate=""

  if has_closed "$f_path"; then
    life="$ICON_CLOSED"
  else
    life="$ICON_OPEN"
  fi

  dstate="$(get_decision_state "$f_path")"
  if [[ -n "$dstate" ]]; then
    case "$dstate" in
      accepted)   dec="$ICON_ACCEPT" ;;
      rejected)   dec="$ICON_REJECT" ;;
      superseded) dec="$ICON_SUPER" ;;
      dropped)    dec="$ICON_DROP" ;;
      *)          dec="$ICON_PROPOSE" ;;
    esac

    if [[ "$dstate" == "superseded" ]]; then
      arrow="$(get_superseded_by "$f_path")"
    fi
  fi

  # 終端 decision は marker 抑制（ただし superseded の矢印は表示）
  if [[ "$dstate" =~ ^(accepted|rejected|superseded|dropped)$ ]]; then
    printf "%s|%s|%s|%s|%s" "$life" "$dec" "" "" "$arrow"
    return
  fi

  # marker は awaiting > blocked > focus
  local match
  match=$(grep -Ei -m1 '@awaiting|@blocked|@focus' "$f_path" | tr -d '\r' || true)
  if [[ -n "$match" ]]; then
    if [[ "$match" =~ @awaiting ]]; then
      prio="$ICON_AWAIT"
      text=$(echo "$match" | sed -E 's/.*@awaiting[[:space:]]*//I')
    elif [[ "$match" =~ @blocked ]]; then
      prio="$ICON_BLOCK"
      text=$(echo "$match" | sed -E 's/.*@blocked[[:space:]]*//I')
    elif [[ "$match" =~ @focus ]]; then
      prio="$ICON_FOCUS"
      text=$(echo "$match" | sed -E 's/.*@focus[[:space:]]*//I')
    fi
  fi

  printf "%s|%s|%s|%s|%s" "$life" "$dec" "$prio" "$text" ""
}

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ (.*)\[\[([^]|]+)(\|[^]]+)?\]\](.*) ]]; then
    prefix="${BASH_REMATCH[1]}"
    link_target="${BASH_REMATCH[2]}"
    link_alias="${BASH_REMATCH[3]}"
    suffix="${BASH_REMATCH[4]}"

    [[ "$link_target" != *.md ]] && filename="${link_target}.md" || filename="$link_target"
    resolved_path="$(resolve_file_path "$filename")"

    info="$(get_link_info "$resolved_path")"
    life_icon="$(echo "$info" | cut -d'|' -f1)"
    dec_icon="$(echo "$info" | cut -d'|' -f2)"
    pr_icon="$(echo "$info" | cut -d'|' -f3)"
    extra_txt="$(echo "$info" | cut -d'|' -f4)"
    arrow_txt="$(echo "$info" | cut -d'|' -f5)"

    new_prefix="$(clean_prefix "$prefix")"
    new_suffix="$(clean_suffix "$suffix")"

    prio_part=""
    if [[ -n "$pr_icon" ]]; then
      if [[ -n "$extra_txt" ]]; then
        prio_part="${pr_icon}(${extra_txt})"
      else
        prio_part="${pr_icon}"
      fi
    fi

    arrow_part=""
    if [[ -n "$arrow_txt" ]]; then
      arrow_part=" (→ ${arrow_txt})"
    fi

    # ★ここがポイント：life + decision を並べて表示
    echo "${new_prefix}${life_icon}${dec_icon}[[${link_target}${link_alias}]]${prio_part}${arrow_part}${new_suffix}" >> "$TEMP_FILE"
  else
    echo "$line" >> "$TEMP_FILE"
  fi
done < "$TARGET_FILE"

mv "$TEMP_FILE" "$TARGET_FILE"
echo "Updated: $TARGET_FILE"
