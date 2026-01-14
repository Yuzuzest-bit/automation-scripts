#!/usr/bin/env bash
# win_zk_dashboard_updated_with_status_v1.sh
# Windows(Git Bash/MSYS2)向け:
# - .md を全スキャンしてダッシュボード生成
# - 並び順: 更新日時(mtime)のみ（デフォルト昇順）
# - 判定: closed / decision / superseded_by / minutes / seed/log/resource / @focus/@awaiting/@blocked / summary
# - gawk不要（strftime不使用）: 日付表示は stat の %y を使う
#
# usage:
#   ./win_zk_dashboard_updated_with_status_v1.sh [ROOT]
#
# env:
#   SCAN_MAX_LINES=80         # 本文スキャン行数（@focus等検出用。不要なら0）
#   SORT_ORDER=asc|desc       # デフォルト asc（古い→新しい）
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
OUTPUT_FILENAME="DASHBOARD_UPDATED_STATUS.md"
SCAN_MAX_LINES="${SCAN_MAX_LINES:-80}"
SORT_ORDER="${SORT_ORDER:-asc}"   # asc|desc

# --- アイコン（提示スクリプトに合わせる） ---
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "

ICON_SEED="🌱 "
ICON_RES="📚 "
ICON_LOG="✍️ "
ICON_MINUTES="🕒 "

ICON_DECISION="🗳️ "
ICON_ACCEPT="🆗 "
ICON_REJECT="❌ "
ICON_SUPER="♻️ "
ICON_DROP="💤 "
ICON_PROPOSE="📝 "

ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "
ICON_BLOCK="🧱 "

# --- ルート ---
ROOT="${1:-$PWD}"
ROOT="$(cd "$ROOT" && pwd -P)"

OUTDIR="${ROOT}/${OUTDIR_NAME}"
mkdir -p "$OUTDIR"
OUTPUT_FILE="${OUTDIR}/${OUTPUT_FILENAME}"

echo "Scanning workspace (mtime sort + closed/decision): $ROOT"

AWK_BIN="awk"
TMP_LIST="$(mktemp)"

# 重要: “本物のタブ” を渡す
# %Y = epoch(mtime), %y = 人間が読める更新日時, %n = path
STAT_FMT=$'%Y\t%y\t%n'

find "$ROOT" \
  \( -path "*/.*" -o -path "*/${OUTDIR_NAME}" \) -prune -o \
  -type f -name "*.md" -print0 \
| xargs -0 -r stat -c "$STAT_FMT" 2>/dev/null \
| "$AWK_BIN" \
  -v output_file="$OUTPUT_FILE" \
  -v scan_max_lines="$SCAN_MAX_LINES" \
  -v ic="$ICON_CLOSED" -v io="$ICON_OPEN" -v ierr="$ICON_ERROR" \
  -v iseed="$ICON_SEED" -v ires="$ICON_RES" -v ilog="$ICON_LOG" -v imin="$ICON_MINUTES" \
  -v idec="$ICON_DECISION" \
  -v iacc="$ICON_ACCEPT" -v irej="$ICON_REJECT" -v isup="$ICON_SUPER" -v idrp="$ICON_DROP" -v iprp="$ICON_PROPOSE" \
  -v ifoc="$ICON_FOCUS" -v ia="$ICON_AWAIT" -v ib="$ICON_BLOCK" \
  '
  BEGIN { IGNORECASE = 1 }

  function trim(s){ sub(/^\xef\xbb\xbf/, "", s); sub(/\r$/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function strip_quotes(v){ v=trim(v); gsub(/^"+|"+$/, "", v); gsub(/^\047+|\047+$/, "", v); return v }

  # POSIX awkでも動くASCII限定tolower（必要なら）
  function tolower_ascii(s, out, i, c){
    out=""
    for(i=1;i<=length(s);i++){
      c=substr(s,i,1)
      if(c>="A" && c<="Z") c=tolower(c)
      out=out c
    }
    return out
  }

  function basename_no_ext(path,   p){
    p = path
    sub(/^.*[\/\\]/, "", p)
    sub(/\.md$/, "", p)
    return p
  }

  function apply_tags(s,   x){
    x = tolower_ascii(s)
    if (x ~ /zk-seed/)       is_seed = 1
    if (x ~ /type-log/)      is_log = 1
    if (x ~ /type-resource/) is_res = 1
    if (x ~ /minutes/)       is_minutes = 1
  }

  function scan_one_file(path,   line, t, in_fm, tags_mode, body_count, v, low){
    # 初期化
    closed = 0
    decision = ""
    sup_by = ""
    summary = ""

    is_seed = is_log = is_res = is_minutes = 0

    marker = ""
    marker_text = ""

    in_fm = 0
    tags_mode = 0
    body_count = 0

    while ((getline line < path) > 0) {
      sub(/\r$/, "", line)

      if (NR == 1) {
        # （注）NRは入力ストリーム全体なので使わない。BOMは個別に処理する
      }

      # BOM対策：ファイル先頭行だけ除去したいので、tの先頭にBOMが残ってもtrimで消える
      t = trim(line)

      # frontmatter 開始
      if (!seen_first) {
        if (t == "") continue
        seen_first = 1
        if (t ~ /^---[ \t]*$/) { in_fm = 1; next }
      }

      if (in_fm) {
        if (t ~ /^(---|\.\.\.)[ \t]*$/) { in_fm = 0; next }

        if (t ~ /^closed:[ \t]*/) { closed = 1; next }

        if (t ~ /^decision:[ \t]*/) {
          v = t
          sub(/^decision:[ \t]*/, "", v)
          decision = tolower_ascii(trim(v))
          next
        }

        if (t ~ /^superseded_by:[ \t]*/) {
          v = t
          sub(/^superseded_by:[ \t]*/, "", v)
          sup_by = strip_quotes(v)
          next
        }

        if (t ~ /^summary:[ \t]*/) {
          v = t
          sub(/^summary:[ \t]*/, "", v)
          summary = strip_quotes(v)
          next
        }

        if (t ~ /^tags:[ \t]*/) {
          v = t
          sub(/^tags:[ \t]*/, "", v)
          v = trim(v)
          apply_tags(v)
          if (v == "") tags_mode = 1
          next
        }

        if (tags_mode) {
          if (t ~ /^[ \t]*-[ \t]*/) {
            v = t
            sub(/^[ \t]*-[ \t]*/, "", v)
            v = trim(v)
            apply_tags(v)
            next
          }
          if (t ~ /^[A-Za-z0-9_-]+:[ \t]*/) tags_mode = 0
        }

        # frontmatter中に minutes が直接書かれていても拾えるように（update_in_place寄せ）
        if (tolower_ascii(t) ~ /minutes/) is_minutes = 1

        next
      }

      # ここから本文（必要ならスキャン）
      if (scan_max_lines <= 0) continue

      if (marker == "") {
        low = tolower_ascii(line)
        if (index(low, "@awaiting")) { marker = ia; marker_text = trim(substr(line, index(low,"@awaiting")+9)); }
        else if (index(low, "@blocked")) { marker = ib; marker_text = trim(substr(line, index(low,"@blocked")+8)); }
        else if (index(low, "@focus")) { marker = ifoc; marker_text = trim(substr(line, index(low,"@focus")+6)); }
        # タブは壊れるので潰す
        gsub(/\t/, " ", marker_text)
      }

      body_count++
      if (body_count >= scan_max_lines) break
      if (marker != "" && body_count >= 3) break
    }
    close(path)
    seen_first = 0
  }

  function build_dec_icon(dec,   out){
    out = ""
    if (dec == "") return out
    if (dec == "accepted") out = iacc
    else if (dec == "rejected") out = irej
    else if (dec == "superseded") out = isup
    else if (dec == "dropped") out = idrp
    else out = iprp
    return out
  }

  function trim_human_date(h,   d){
    # 例: "2026-01-14 10:22:33.123456789 +0900" -> "2026-01-14 10:22"
    d = h
    if (length(d) > 16) d = substr(d, 1, 16)
    return d
  }

  {
    # 入力: epoch<TAB>human<TAB>path  （FSに依存しないで分割）
    line = $0
    sub(/\r$/, "", line)

    t1 = index(line, "\t"); if (t1 == 0) next
    rest = substr(line, t1+1)
    t2 = index(rest, "\t"); if (t2 == 0) next

    mtime = substr(line, 1, t1-1) + 0
    human = substr(rest, 1, t2-1)
    path  = substr(rest, t2+1)

    if (path == "" || mtime <= 0) next
    if (path == output_file) next

    # meta scan
    scan_one_file(path)

    fname = basename_no_ext(path)

    status_icon = (closed ? ic : io)

    type_icon = ""
    if (is_seed)    type_icon = type_icon iseed
    if (is_log)     type_icon = type_icon ilog
    if (is_res)     type_icon = type_icon ires
    if (is_minutes) type_icon = type_icon imin

    decision_note = (decision != "" ? idec : "")
    dec_icon = build_dec_icon(decision)

    # decisionが確定系の場合は、優先マーカーを消す（update_in_placeの思想）
    prio_part = ""
    if (!(decision ~ /^(accepted|rejected|superseded|dropped)$/) && marker != "") {
      if (marker_text != "") prio_part = marker "(" marker_text ")"
      else prio_part = marker
    }

    arrow_part = ""
    if (decision == "superseded" && sup_by != "") {
      gsub(/\t/, " ", sup_by)
      arrow_part = " (→ " sup_by ")"
    }

    summary_part = (summary != "" ? "  _(" summary ")_" : "")

    date_disp = " `updated : " trim_human_date(human) "`"

    # sort key: mtime（更新日時のみ）
    printf "%d\t- [[%s]] %s%s%s%s[[%s]]%s%s%s\n",
      mtime,
      fname,
      status_icon, type_icon, decision_note, dec_icon,
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
  echo "title: All Notes (Updated mtime order)"
  echo "updated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "---"
  echo ""
  echo "# 📅 Timeline Dashboard (mtime)"
  echo "> **Order:** updated(mtime) only / **Status:** closed + decision reflected"
  echo ""

  if [[ "$SORT_ORDER" == "desc" ]]; then
    LC_ALL=C sort -rn "$TMP_LIST" | cut -f2-
  else
    LC_ALL=C sort -n "$TMP_LIST" | cut -f2-
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
