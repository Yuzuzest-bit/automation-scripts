# -----------------------------
# 文字列クリーニング（増殖対策・強化版）
# - prefix: [[ の直前にある「自動付与アイコン」を末尾から全部はがす
# - suffix: ]] の直後にある「自動付与コメント(⏳/🧱/🎯...)」「(→ ...)」を
#          先頭から何個でも連続で除去（過去に増殖した分も一掃）
# - () 内に ')' が含まれても壊れないよう、括弧はバランスで除去
# -----------------------------

ltrim_ws() { # leading whitespace (space/tab + fullwidth space)
  local s="$1"
  while [[ -n "$s" ]]; do
    case "${s:0:1}" in
      ' '|$'\t'|$'\r'|$'\n'|$'\v'|$'\f'|'　')
        s="${s:1}"
        ;;
      *)
        break
        ;;
    esac
  done
  printf '%s' "$s"
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

  # unmatched
  printf '%s' ""
}

clean_prefix() {
  local s="$1"
  local changed=1
  local icon icon2

  # 「prefixの末尾」に付いた自動アイコンだけを剥がす（テキスト中の絵文字は壊しにくい）
  while (( changed )); do
    changed=0
    for icon in \
      "$ICON_CLOSED" "$ICON_OPEN" "$ICON_ERROR" \
      "$ICON_MINUTES_NOTE" "$ICON_DECISION_NOTE" \
      "$ICON_ACCEPT" "$ICON_REJECT" "$ICON_SUPER" "$ICON_DROP" "$ICON_PROPOSE"
    do
      # 末尾が "ICON(末尾スペース込み)" なら剥がす
      if [[ "$s" == *"$icon" ]]; then
        s="${s%$icon}"
        changed=1
      fi

      # 末尾スペースが消えたケースにも対応（ICONの末尾スペース無し版）
      icon2="${icon% }"
      if [[ "$icon2" != "$icon" && "$s" == *"$icon2" ]]; then
        s="${s%$icon2}"
        changed=1
      fi
    done
  done

  printf '%s' "$s"
}

clean_suffix() {
  local orig="$1"
  local s="$orig"

  local removed=0
  local progressed=0

  # 元々 ]] の後に空白があった行は、除去後も 1 つ空白を残す（くっつき防止）
  local orig_had_ws=0
  case "$orig" in
    " "*|$'\t'*|'　'*) orig_had_ws=1;;
  esac

  s="$(ltrim_ws "$s")"

  # 先頭から「自動付与パーツ」を何個でも連続で剥がす（過去に増殖した分も一掃）
  while :; do
    progressed=0

    # prio: ⏳ / 🧱 / 🎯 (optional "(...)" )
    if [[ "$s" == ⏳* ]]; then
      removed=1; progressed=1
      s="${s#⏳}"; s="$(ltrim_ws "$s")"
      if [[ "${s:0:1}" == "(" ]]; then s="$(strip_balanced_parens "$s")"; fi
      s="$(ltrim_ws "$s")"
    elif [[ "$s" == 🧱* ]]; then
      removed=1; progressed=1
      s="${s#🧱}"; s="$(ltrim_ws "$s")"
      if [[ "${s:0:1}" == "(" ]]; then s="$(strip_balanced_parens "$s")"; fi
      s="$(ltrim_ws "$s")"
    elif [[ "$s" == 🎯* ]]; then
      removed=1; progressed=1
      s="${s#🎯}"; s="$(ltrim_ws "$s")"
      if [[ "${s:0:1}" == "(" ]]; then s="$(strip_balanced_parens "$s")"; fi
      s="$(ltrim_ws "$s")"
    fi

    # arrow: (→ ... )
    if [[ "$s" == \(→* ]]; then
      removed=1; progressed=1
      s="$(strip_balanced_parens "$s")"
      s="$(ltrim_ws "$s")"
    fi

    (( progressed )) || break
  done

  # 残りが空なら suffix は空で返す
  if [[ -z "$s" ]]; then
    printf '%s' ""
    return 0
  fi

  # 元が空白始まりだった or 自動パーツを剥がした → 区切り用に空白1個を付けて返す
  if (( removed || orig_had_ws )); then
    printf ' %s' "$s"
  else
    printf '%s' "$s"
  fi
}
