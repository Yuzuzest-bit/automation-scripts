#!/usr/bin/env bash
# win_zk_dashboard_mtime_with_status_v1.sh
# - gawk不要（strftime不使用）
# - mtime(更新日時)でソートして一覧を生成
# - closed/decision/priority/comment/arrow の仕様は update_in_place.sh(scan_meta) に準拠
#
# usage:
#   ./win_zk_dashboard_mtime_with_status_v1.sh [ROOT]
#
# env:
#   SCAN_MAX_LINES=80         # 本文スキャン行数（@focus等検出用。不要なら0）
#   SORT_ORDER=desc|asc       # デフォルト desc（新しい→古い）
#
set -Eeuo pipefail

# --- ロケール（sort速度&文字化け対策） ---
if command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qi '^c\.utf-8$'; then
  export LC_ALL=C.UTF-8
elif command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qi '^en_us\.utf-8$'; then
  export LC_ALL=en_US.UTF-8
else
  export LC_ALL=C
fi
export LANG="${LC_ALL}"

trap 'rc=$?; printf "[ERR] exit=%d line=%d cmd=%s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

# --- 設定 ---
OUTDIR_NAME="dashboards"
OUTPUT_FILENAME="DASHBOARD_MTIME_STATUS.md"
SCAN_MAX_LINES="${SCAN_MAX_LINES:-80}"
SORT_ORDER="${SORT_ORDER:-desc}"   # ★デフォルト: desc（新しい→古い）

# --- Icons（update_in_place準拠）---
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

# --- ルート ---
ROOT="${1:-$PWD}"
ROOT="$(cd "$ROOT" && pwd -P)"

OUTDIR="${ROOT}/${OUTDIR_NAME}"
mkdir -p "$OUTDIR"
OUTPUT_FILE="${OUTDIR}/${OUTPUT_FILENAME}"

echo "Scanning workspace (mtime + update_in_place meta): $ROOT"

AWK_BIN="awk"
TMP_LIST="$(mktemp)"

# --- stat フォーマット（Windows/MSYS2/Git Bash想定: GNU stat） ---
# 本物タブを渡す。epoch<TAB>human<TAB>path
# human は "%y"（例: 2026-01-14 10:22:33.123456789 +0900）
STAT_FMT=$'%Y\t%y\t%n'

find "$ROOT" \
  \( -path "*/.*" -o -path "*/${OUTDIR_NAME}" \) -prune -o \
  -type f -name "*.md" -print0 \
| xargs -0 -r stat -c "$STAT_FMT" 2>/dev/null \
| "$AWK_BIN" \
  -v output_file="$OUTPUT_FILE" \
  -v scan_max_lines="$SCAN_MAX_LINES" \
  -v ic="$ICON_CLOSED" -v io="$ICON_OPEN" -v ierr="$ICON_ERROR" \
  -v imin="$ICON_MINUTES_NOTE" \
  -v idec="$ICON_DECISION_NOTE" \
  -v iacc="$ICON_ACCEPT" -v irej="$ICON_REJECT" -v isup="$ICON_SUPER" -v idrp="$ICON_DROP" -v iprp="$ICON_PROPOSE" \
  -v ifoc="$ICON_FOCUS" -v ia="$ICON_AWAIT" -v ib="$ICON_BLOCK" \
  '
  function trim(s){
    sub(/^\xef\xbb\xbf/, "", s)     # BOM
    sub(/\r$/, "", s)              # CRLF
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return s
  }
  function strip_quotes(v){
    v = trim(v)
    gsub(/^"+|"+$/, "", v)
    gsub(/^\047+|\047+$/, "", v)
    return v
  }
  function tolower_ascii(s, out, i, c){
    out=""
    for(i=1;i<=length(s);i++){
      c=substr(s,i,1)
      if(c>="A" && c<="Z") c=tolower(c)
      out=out c
    }
    return out
  }
  function basename_no_ext(path, p){
    p = path
    sub(/^.*[\/\\]/, "", p)
    sub(/\.md$/, "", p)
    return p
  }
  function apply_tags(s, x){
    x = tolower_ascii(s)
    # update_in_place側は minutes を強めに拾うので同じ思想で
    if (x ~ /minutes/) is_minutes = 1
  }
  function trim_human_date(h, d){
    # "YYYY-MM-DD HH:MM:SS...." -> "YYYY-MM-DD HH:MM"
    d = h
    if (length(d) > 16) d = substr(d, 1, 16)
    return d
  }

  # --- update_in_place scan_meta準拠 ---
  function scan_meta(path,   line, t, in_fm, first, tags_mode, low, v, body_count){
    closed=0; decision=""; sup_by=""; summary=""; is_minutes=0;
    prio_set=0; prio_icon=""; prio_text="";

    in_fm=0; first=0; tags_mode=0; body_count=0;

    while ((getline line < path) > 0) {
      sub(/\r$/, "", line)
      t = trim(line)

      # 先頭の空行は飛ばす（update_in_place準拠）
      if(!first){
        if(t=="") continue
        first=1
        if(t ~ /^---[ \t]*$/){ in_fm=1; continue }
      }

      if(in_fm){
        if(t ~ /^(---|\.\.\.)[ \t]*$/){ in_fm=0; continue }

        if(t ~ /^closed:[ \t]*/){ closed=1; continue }

        if(t ~ /^decision:[ \t]*/){
          v=t; sub(/^decision:[ \t]*/, "", v)
          decision=tolower_ascii(trim(v))
          continue
        }

        if(t ~ /^superseded_by:[ \t]*/){
          v=t; sub(/^superseded_by:[ \t]*/, "", v)
          sup_by=strip_quotes(v)
          continue
        }

        if(t ~ /^summary:[ \t]*/){
          v=t; sub(/^summary:[ \t]*/, "", v)
          summary=strip_quotes(v)
          continue
        }

        if(t ~ /^tags:[ \t]*/){
          v=t; sub(/^tags:[ \t]*/, "", v)
          v=trim(v)
          apply_tags(v)
          if(v=="") tags_mode=1
          continue
        }

        if(tags_mode){
          if(t ~ /^[ \t]*-[ \t]*/){
            v=t; sub(/^[ \t]*-[ \t]*/, "", v)
            v=trim(v)
            apply_tags(v)
            continue
          }
          if(t ~ /^[A-Za-z0-9_-]+:[ \t]*/) tags_mode=0
        }

        # frontmatter中で minutes を拾う（update_in_place寄せ）
        if (tolower_ascii(t) ~ /minutes/) is_minutes=1
        continue
      }

      # 本文スキャン（prio検出）
      if(scan_max_lines > 0 && prio_set==0){
        low = tolower_ascii(line)
        if(index(low,"@awaiting")){
          prio_icon=ia
          sub(/.*@awaiting[[:space:]]*/, "", line)
          prio_text=trim(line)
          prio_set=1
        } else if(index(low,"@blocked")){
          prio_icon=ib
          sub(/.*@blocked[[:space:]]*/, "", line)
          prio_text=trim(line)
          prio_set=1
        } else if(index(low,"@focus")){
          prio_icon=ifoc
          sub(/.*@focus[[:space:]]*/, "", line)
          prio_text=trim(line)
          prio_set=1
        }
      }

      body_count++
      if(scan_max_lines > 0 && body_count >= scan_max_lines) break
      if(scan_max_lines > 0 && prio_set==1 && body_count >= 3) break
    }
    close(path)

    # タブはTSV壊すので潰す（update_in_place思想）
    gsub(/\t/, " ", prio_text)
    gsub(/\t/, " ", sup_by)
  }

  function decision_state_icon(dec){
    if(dec=="") return ""
    if(dec=="accepted") return iacc
    if(dec=="rejected") return irej
    if(dec=="superseded") return isup
    if(dec=="dropped") return idrp
    return iprp
  }

  {
    # 入力: epoch<TAB>human<TAB>path（FSに依存せず分割）
    raw=$0
    sub(/\r$/, "", raw)

    t1=index(raw,"\t"); if(t1==0) next
    rest=substr(raw,t1+1)
    t2=index(rest,"\t"); if(t2==0) next

    mtime = substr(raw,1,t1-1)+0
    human = substr(rest,1,t2-1)
    path  = substr(rest,t2+1)

    if(path=="" || mtime<=0) next
    if(path==output_file) next

    scan_meta(path)

    fname = basename_no_ext(path)

    life_icon = (closed ? ic : io)
    minutes_icon = (is_minutes ? imin : "")
    kind_icon = (decision!="" ? idec : "")
    dec_icon  = decision_state_icon(decision)

    # prio: decisionが確定系なら抑止（update_in_place準拠）
    prio_part=""
    if(!(decision ~ /^(accepted|rejected|superseded|dropped)$/) && prio_set==1){
      if(prio_text!="") prio_part = prio_icon "(" prio_text ")"
      else prio_part = prio_icon
    }

    arrow_part=""
    if(decision=="superseded" && sup_by!=""){
      arrow_part=" (→ " sup_by ")"
    }

    summary_part = (summary!="" ? "  _(" summary ")_" : "")

    date_disp = " `updated : " trim_human_date(human) "`"

    # 出力: sortkey(mtime) + 本文
    printf "%d\t- %s%s%s%s[[%s]]%s%s%s%s\n",
      mtime,
      life_icon, minutes_icon, kind_icon, dec_icon,
      fname,
      prio_part,
      arrow_part,
      summary_part,
      date_disp
  }
' > "$TMP_LIST"

{
  echo "---"
  echo "id: $(date '+%Y%m%d%H%M')-DASHBOARD"
  echo "tags: [system, dashboard]"
  echo "title: All Notes (mtime order)"
  echo "updated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "---"
  echo ""
  echo "# 📅 Timeline Dashboard (mtime)"
  echo "> **Order:** mtime (${SORT_ORDER}) / **Meta:** closed + decision + prio (update_in_place compatible)"
  echo ""

  if [[ "$SORT_ORDER" == "asc" ]]; then
    LC_ALL=C sort -n "$TMP_LIST" | cut -f2-
  else
    LC_ALL=C sort -rn "$TMP_LIST" | cut -f2-
  fi
} > "$OUTPUT_FILE"

rm -f "$TMP_LIST"
echo "[OK] Generated: $OUTPUT_FILE"

if command -v code >/dev/null 2>&1; then
  code "$OUTPUT_FILE"
else
  if command -v cygpath >/dev/null 2>&1; then
    winpath="$(cygpath -w "$OUTPUT_FILE")"
    cmd.exe /c start "" "$winpath" >/dev/null 2>&1 || true
  else
    echo "Please open '$OUTPUT_FILE' manually."
  fi
fi
