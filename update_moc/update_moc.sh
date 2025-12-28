#!/usr/bin/env bash
# update_in_place.sh

export LC_ALL=C.UTF-8
set -euo pipefail

TARGET_FILE="${1:-}"

# --- 設定 ---
VAULT_ROOT="$(pwd -P)"

# 既存アイコン
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "
ICON_FOCUS="🎯"
ICON_AWAIT="⏳"
ICON_BLOCK="🧱"

# decision state icons
ICON_ACCEPT="✅ "
ICON_REJECT="❌ "
ICON_SUPER="♻️ "
ICON_DROP="💤 "
ICON_PROPOSE="🟡 "

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

clean_prefix() {
  local s="$1"
  # 既存の状態アイコンを全部剥がす（再実行で重ならないように）
  for icon in \
    "$ICON_CLOSED" "$ICON_OPEN" "$ICON_ERROR" \
    "$ICON_ACCEPT" "$ICON_REJECT" "$ICON_SUPER" "$ICON_DROP" "$ICON_PROPOSE"
  do
    s="${s//$icon/}"
  done
  printf '%s' "$s"
}

clean_suffix() {
  local s="$1"
  # リンク直後の優先度アイコンを除去（🎯(text), 🧱(text), ⏳(text)）
  echo "$s" | sed -E 's/^[[:space:]]*(🎯|🧱|⏳)\([^)]*\)//'
}

# frontmatter から decision: を読む（無ければ空）
get_decision_state() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && { echo ""; return; }
  # frontmatter 先頭 80行くらい見れば大抵十分
  # decision: の値は小文字に正規化して返す
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

# リンク先の状態を取得（decision優先、次にclosed、最後にopen）
get_link_info() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && { echo "$ICON_ERROR||"; return; }

  local status="$ICON_OPEN"
  local prio=""
  local text=""
  local dstate

  dstate="$(get_decision_state "$f_path")"

  # decision状態があればそれを優先して表示
  if [[ -n "$dstate" ]]; then
    case "$dstate" in
      accepted)   status="$ICON_ACCEPT" ;;
      rejected)   status="$ICON_REJECT" ;;
      superseded) status="$ICON_SUPER" ;;
      dropped)    status="$ICON_DROP" ;;
      *)          status="$ICON_PROPOSE" ;; # proposed/その他
    esac
  else
    # closed判定（decisionが無いノート用）
    if head -n 30 "$f_path" | tr -d '\r' | grep -qE '^closed:[[:space:]]*.+'; then
      status="$ICON_CLOSED"
    fi
  fi

  # decisionが終端状態なら marker は抑制（awaiting残骸で汚れない）
  if [[ "$dstate" =~ ^(accepted|rejected|superseded|dropped)$ ]]; then
    printf "%s|%s|%s" "$status" "" ""
    return
  fi

  # 優先度とテキスト（awaiting > blocked > focus）
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

  printf "%s|%s|%s" "$status" "$prio" "$text"
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
    st_icon=$(echo "$info" | cut -d'|' -f1)
    pr_icon=$(echo "$info" | cut -d'|' -f2)
    extra_txt=$(echo "$info" | cut -d'|' -f3)

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

    echo "${new_prefix}${st_icon}[[${link_target}${link_alias}]]${prio_part}${new_suffix}" >> "$TEMP_FILE"
  else
    echo "$line" >> "$TEMP_FILE"
  fi
done < "$TARGET_FILE"

mv "$TEMP_FILE" "$TARGET_FILE"
echo "Updated: $TARGET_FILE"
