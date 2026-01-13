#!/usr/bin/env bash
# win_zk_dashboard_list_v6_1.sh
# Windows(Git Bash/MSYS2)向け: 1回のawkで全ファイル処理して高速化
# Fix v6.1: statの区切りタブ問題を回避（pathが空になってgawkが落ちる件）

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

# --- 設定 ---
OUTDIR_NAME="dashboards"
OUTPUT_FILENAME="DASHBOARD_LIST.md"
SCAN_MAX_LINES="${SCAN_MAX_LINES:-80}"

# --- アイコン ---
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

echo "Scanning workspace (Windows fast): $ROOT"

# --- awk選択（gawk推奨） ---
AWK_BIN="awk"
if command -v gawk >/dev/null 2>&1; then
  AWK_BIN="gawk"
fi

TMP_LIST="$(mktemp)"

# 重要: statのフォーマットに “本物のタブ” を渡す（\t解釈しない環境がある）
STAT_FMT=$'%Y\t%n'

find "$ROOT" \
  \( -path "*/.*" -o -path "*/${OUTDIR_NAME}" \) -prune -o \
  -type f -name "*.md" -print0 \
| xargs -0 -r stat -c "$STAT_FMT" 2>/dev/null \
| "$AWK_BIN" \
  -v output_file="$OUTPUT_FILE" \
  -v scan_max_lines="$SCAN_MAX_LINES" \
  -v ic="$ICON_CLOSED" -v io="$ICON_OPEN" -v ierr="$ICON_ERROR" \
  -v iseed="$ICON_SEED" -v ires="$ICON_RES" -v ilog="$ICON_LOG" -v imin="$ICON_MINUTES" \
  -v idec="$ICON_DECISION" -v iacc="$ICON_ACCEPT" -v irej="$ICON_REJECT" -v isup="$ICON_SUPER" -v idrp="$ICON_DROP" -v iprp="$ICON_PROPOSE" \
  -v ifoc="$ICON_FOCUS" -v ia="$ICON_AWAIT" -v ib="$ICON_BLOCK" \
  '
  BEGIN { IGNORECASE = 1 }

  function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function strip_quotes(s){ gsub(/^["\047]+|["\047]+$/, "", s); return s }

  function to_sort_key(ts,   t){
    t = ts
    gsub(/[-:T ]/, "", t)
    t = substr(t, 1, 14)
    while(length(t) < 14) t = t "0"
    return t
  }

  function basename_no_ext(path,   p){
    p = path
    sub(/^.*[\/\\]/, "", p)
    sub(/\.md$/, "", p)
    return p
  }

  function apply_tags(s,   x){
    x = s
    if (x ~ /zk-seed/) is_seed = 1
    if (x ~ /type-log/) is_log = 1
    if (x ~ /type-resource/) is_res = 1
    if (x ~ /minutes/) is_minutes = 1
  }

  function scan_one_file(path, mtime,   line, n, in_fm, tags_mode, body_count, v){
    closed_date = ""
    decision = ""
    summary = ""

    is_seed = is_log = is_res = is_minutes = 0
    marker = ""

    in_fm = 0
    tags_mode = 0
    body_count = 0
    n = 0

    while ((getline line < path) > 0) {
      n++
      sub(/\r$/, "", line)                 # CRLF対策
      if (n == 1) sub(/^\xef\xbb\xbf/, "", line)  # BOM対策

      if (n == 1 && line ~ /^---[ \t]*$/) { in_fm = 1; continue }

      if (in_fm) {
        if (line ~ /^(---|\.\.\.)[ \t]*$/) { in_fm = 0; continue }

        if (line ~ /^closed:[ \t]*/) {
          v = line; sub(/^closed:[ \t]*/, "", v)
          closed_date = trim(v)
          continue
        }
        if (line ~ /^decision:[ \t]*/) {
          v = line; sub(/^decision:[ \t]*/, "", v)
          decision = tolower(trim(v))
          continue
        }
        if (line ~ /^summary:[ \t]*/) {
          v = line; sub(/^summary:[ \t]*/, "", v)
          summary = strip_quotes(trim(v))
          continue
        }

        if (line ~ /^tags:[ \t]*/) {
          v = line; sub(/^tags:[ \t]*/, "", v)
          v = trim(v)
          apply_tags(v)
          if (v == "" || v ~ /^$/) tags_mode = 1
          continue
        }
        if (tags_mode) {
          if (line ~ /^[ \t]*-[ \t]*/) {
            v = line; sub(/^[ \t]*-[ \t]*/, "", v)
            v = trim(v)
            apply_tags(v)
            continue
          }
          if (line ~ /^[A-Za-z0-9_-]+:[ \t]*/) tags_mode = 0
        }
        continue
      }

      if (marker == "" && line ~ /@focus/)    marker = ifoc
      if (marker == "" && line ~ /@awaiting/) marker = ia
      if (marker == "" && line ~ /@blocked/)  marker = ib

      body_count++
      if (body_count >= scan_max_lines) break
      if (marker != "" && body_count >= 3) break
    }
    close(path)

    status_icon = (closed_date != "" ? ic : io)

    type_icon = ""
    if (is_seed)    type_icon = type_icon iseed
    if (is_log)     type_icon = type_icon ilog
    if (is_res)     type_icon = type_icon ires
    if (is_minutes) type_icon = type_icon imin

    dec_icon = ""
    if (decision != "") {
      if (decision == "accepted")        dec_icon = iacc
      else if (decision == "rejected")   dec_icon = irej
      else if (decision == "superseded") dec_icon = isup
      else if (decision == "dropped")    dec_icon = idrp
      else                               dec_icon = iprp
    }

    display_summary = (summary != "" ? "  _(" summary ")_" : "")

    if (closed_date != "") {
      sort_key = to_sort_key(closed_date)
      clean_date = substr(closed_date, 1, 10)
      date_disp = " `closed : " clean_date "`"
    } else {
      sort_key = mtime
      date_disp = " `updated : " strftime("%Y-%m-%d", mtime) "`"
    }

    printf "%s\t- [[%s]] %s%s%s%s%s%s\n", sort_key, fname, status_icon, type_icon, dec_icon, marker, display_summary, date_disp
  }

  {
    line = $0
    sub(/\r$/, "", line)

    # 1個目のタブで分割（FSに依存しない）
    t = index(line, "\t")
    if (t == 0) next

    mtime = substr(line, 1, t-1) + 0
    path  = substr(line, t+1)

    if (path == "" || mtime <= 0) next
    if (path == output_file) next

    fname = basename_no_ext(path)
    scan_one_file(path, mtime)
  }
' > "$TMP_LIST"

{
  echo "---"
  echo "id: $(date '+%Y%m%d%H%M')-DASHBOARD"
  echo "tags: [system, dashboard]"
  echo "title: All Notes (Timeline)"
  echo "updated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "---"
  echo ""
  echo "# 📅 Timeline Dashboard"
  echo "> **Order:** Recently Closed > Recently Modified"
  echo ""

  LC_ALL=C sort -rn "$TMP_LIST" | cut -f2-
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
