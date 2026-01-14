#!/usr/bin/env bash
# win_zk_dashboard_updated_asc_v1.sh
# Windows(Git Bash/MSYS2)向け: mdファイルを更新日時(mtime)で昇順に並べてダッシュボード生成
# - closed は見ない
# - 1回のawkで全ファイル処理（高速寄り）
# - statの区切りタブ問題を回避（本物のタブを渡す）
#
# usage:
#   ./win_zk_dashboard_updated_asc_v1.sh [ROOT]
#
# env:
#   SCAN_MAX_LINES=80         # 本文スキャン行数（@focus等の検出用。不要なら0）
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

echo "Scanning workspace (mtime sort): $ROOT"

# --- awk選択（gawk推奨: strftime 使用） ---
AWK_BIN="awk"
if command -v gawk >/dev/null 2>&1; then
  AWK_BIN="gawk"
fi

# gawkが無いと strftime が無いawkがあり得るので、保守的に弾く
if ! "$AWK_BIN" 'BEGIN{ exit (typeof(strftime)=="function" ? 0 : 1) }' >/dev/null 2>&1; then
  echo "[ERR] This script requires gawk (strftime). Please install gawk in MSYS2/Git Bash." >&2
  exit 2
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
  -v io="$ICON_OPEN" \
  -v iseed="$ICON_SEED" -v ires="$ICON_RES" -v ilog="$ICON_LOG" -v imin="$ICON_MINUTES" \
  -v ifoc="$ICON_FOCUS" -v ia="$ICON_AWAIT" -v ib="$ICON_BLOCK" \
  '
  BEGIN { IGNORECASE = 1 }

  function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function strip_quotes(s){ gsub(/^["\047]+|["\047]+$/, "", s); return s }

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
    summary = ""

    is_seed = is_log = is_res = is_minutes = 0
    marker = ""

    in_fm = 0
    tags_mode = 0
    body_count = 0
    n = 0

    # scan_max_lines が 0 ならスキャンしない（最速モード）
    if (scan_max_lines <= 0) {
      return
    }

    while ((getline line < path) > 0) {
      n++
      sub(/\r$/, "", line)                 # CRLF対策
      if (n == 1) sub(/^\xef\xbb\xbf/, "", line)  # BOM対策

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
  }

  function emit_line(path, mtime,   fname, type_icon, display_summary, date_disp){
    fname = basename_no_ext(path)

    type_icon = ""
    if (is_seed)    type_icon = type_icon iseed
    if (is_log)     type_icon = type_icon ilog
    if (is_res)     type_icon = type_icon ires
    if (is_minutes) type_icon = type_icon imin

    display_summary = (summary != "" ? "  _(" summary ")_" : "")
    date_disp = " `updated : " strftime("%Y-%m-%d", mtime) "`"

    # sort_key は mtime の数値
    printf "%d\t- [[%s]] %s%s%s%s%s\n", mtime, fname, io, type_icon, marker, display_summary, date_disp
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

    # 初期化してスキャン（scan_max_lines=0ならscan_one_file内で即return）
    summary = ""
    marker = ""
    is_seed = is_log = is_res = is_minutes = 0

    scan_one_file(path, mtime)
    emit_line(path, mtime)
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
  echo "> **Order:** mtime (${SORT_ORDER})  /  **Tip:** SCAN_MAX_LINES=0 で最速"
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
