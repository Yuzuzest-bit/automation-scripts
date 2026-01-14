#!/usr/bin/env bash
# win_zk_dashboard_updated_asc_nogawk_v1.sh
# gawk不要（strftime不要）版:
# - mdファイルを更新日時(mtime)で昇順に並べてダッシュボード生成
# - closed は見ない
# - 日付表示は stat の %y を使う（awkでstrftimeしない）
#
# usage:
#   ./win_zk_dashboard_updated_asc_nogawk_v1.sh [ROOT]
#
# env:
#   SCAN_MAX_LINES=40         # 本文スキャン行数（@focus等検出用。不要なら0）
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
OUTPUT_FILENAME="DASHBOARD_UPDATED_ASC.md"
SCAN_MAX_LINES="${SCAN_MAX_LINES:-40}"
SORT_ORDER="${SORT_ORDER:-asc}"   # asc|desc

# --- アイコン（必要なものだけ） ---
ICON_OPEN="📄 "
ICON_SEED="🌱 "
ICON_RES="📚 "
ICON_LOG="✍️ "
ICON_MINUTES="🕒 "
ICON_FOCUS="🎯 "
ICON_AWAIT="⏳ "
ICON_BLOCK="🧱 "

# --- ルート ---
ROOT="${1:-$PWD}"
ROOT="$(cd "$ROOT" && pwd -P)"

OUTDIR="${ROOT}/${OUTDIR_NAME}"
mkdir -p "$OUTDIR"
OUTPUT_FILE="${OUTDIR}/${OUTPUT_FILENAME}"

echo "Scanning workspace (mtime sort, no gawk): $ROOT"

AWK_BIN="awk"

TMP_LIST="$(mktemp)"

# 重要: “本物のタブ” を渡す
# %Y = epoch, %y = 人間が読む更新日時, %n = path
# 例: 1700000000<TAB>2026-01-14 10:22:33.123456789 +0900<TAB>/path/file.md
STAT_FMT=$'%Y\t%y\t%n'

find "$ROOT" \
  \( -path "*/.*" -o -path "*/${OUTDIR_NAME}" \) -prune -o \
  -type f -name "*.md" -print0 \
| xargs -0 -r stat -c "$STAT_FMT" 2>/dev/null \
| "$AWK_BIN" \
  -v output_file="$OUTPUT_FILE" \
  -v scan_max_lines="$SCAN_MAX_LINES" \
  -v io="$ICON_OPEN" \
  -v iseed="$ICON_SEED" -v ires="$ICON_RES" -v ilog="$ICON_LOG" -v imin="$ICON_MINUTES" \
  -v ifoc="$ICON_FOCUS" -v ia="$ICON_AWAIT" -v ib="$ICON_BLOCK" \
  '
  function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function strip_quotes(s){ gsub(/^["\047]+|["\047]+$/, "", s); return s }

  function basename_no_ext(path,   p){
    p = path
    sub(/^.*[\/\\]/, "", p)
    sub(/\.md$/, "", p)
    return p
  }

  function apply_tags(s,   x){
    x = tolower(s)
    if (x ~ /zk-seed/)        is_seed = 1
    if (x ~ /type-log/)       is_log = 1
    if (x ~ /type-resource/)  is_res = 1
    if (x ~ /minutes/)        is_minutes = 1
  }

  function scan_one_file(path,   line, n, in_fm, tags_mode, body_count, v){
    summary = ""
    marker = ""
    is_seed = is_log = is_res = is_minutes = 0

    if (scan_max_lines <= 0) return

    in_fm = 0
    tags_mode = 0
    body_count = 0
    n = 0

    while ((getline line < path) > 0) {
      n++
      sub(/\r$/, "", line)
      if (n == 1) sub(/^\xef\xbb\xbf/, "", line)

      if (n == 1 && line ~ /^---[ \t]*$/) { in_fm = 1; continue }

      if (in_fm) {
        if (line ~ /^(---|\.\.\.)[ \t]*$/) { in_fm = 0; continue }

        if (line ~ /^summary:[ \t]*/) {
          v = line; sub(/^summary:[ \t]*/, "", v)
          summary = strip_quotes(trim(v))
          continue
        }

        if (line ~ /^tags:[ \t]*/) {
          v = line; sub(/^tags:[ \t]*/, "", v)
          v = trim(v)
          apply_tags(v)
          if (v == "") tags_mode = 1
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
  }

  {
    # 期待形式: epoch<TAB>human<TAB>path
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

    # 初期化してスキャン
    summary = ""
    marker = ""
    is_seed = is_log = is_res = is_minutes = 0

    scan_one_file(path)

    fname = basename_no_ext(path)

    type_icon = ""
    if (is_seed)    type_icon = type_icon iseed
    if (is_log)     type_icon = type_icon ilog
    if (is_res)     type_icon = type_icon ires
    if (is_minutes) type_icon = type_icon imin

    display_summary = (summary != "" ? "  _(" summary ")_" : "")

    # human は "YYYY-MM-DD HH:MM:SS..." なので、見た目は先頭16文字くらいで十分
    hd = human
    if (length(hd) > 16) hd = substr(hd, 1, 16)

    date_disp = " `updated : " hd "`"

    printf "%d\t- [[%s]] %s%s%s%s%s\n", mtime, fname, io, type_icon, marker, display_summary, date_disp
  }
' > "$TMP_LIST"

{
  echo "---"
  echo "id: $(date '+%Y%m%d%H%M')-DASHBOARD_UPDATED"
  echo "tags: [system, dashboard]"
  echo "title: All Notes (Updated mtime order)"
  echo "updated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "---"
  echo ""
  echo "# 🗂️ Updated Order Dashboard"
  echo "> **Order:** mtime (${SORT_ORDER}) / **Tip:** SCAN_MAX_LINES=0 で最速"
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
