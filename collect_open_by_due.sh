#!/usr/bin/env bash
# collect_open_by_due.sh
# Scan Markdown files under ROOT, pick notes WITHOUT 'closed:' in the first front matter,
# sort by 'due:' ascending, and write a single dashboard markdown.
# Target: Windows Git Bash (also works on macOS/Linux)

set -euo pipefail

# --- Args & defaults ----------------------------------------------------------
ROOT_IN="${1:-.}"
OUT_IN="${2:-dashboards/open_by_due.md}"

# Windowsパス→POSIX（Git Bash/cygwin想定）
ROOT="$ROOT_IN"
OUT="$OUT_IN"
if command -v cygpath >/dev/null 2>&1; then
  # 引数が C:\ などの形式なら POSIX に変換
  [[ "$ROOT" =~ ^[A-Za-z]:[\\/].* ]] && ROOT="$(cygpath -u "$ROOT")"
  BASEDIR="$(dirname "$OUT")"
  [[ "$BASEDIR" =~ ^[A-Za-z]:[\\/].* ]] && OUT="$(cygpath -u "$OUT")"
fi

# 絶対パス化（realpath 不在でもOKにする）
abspath() { (
  set -e
  cd "$(dirname "$1")" >/dev/null 2>&1 || exit 1
  bn="$(basename "$1")"
  printf '%s/%s\n' "$(pwd -P)" "$bn"
); }
ROOT="$(abspath "$ROOT")"
OUT="$(abspath "$OUT")"

# 出力ディレクトリ
mkdir -p "$(dirname "$OUT")"

# 一時ファイル
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# --- Find + Parse -------------------------------------------------------------
# ・dashboards, .git, node_modules, .obsidian などは探索から除外
# ・ファイル名/パスに空白があってもOK（-print0 & read -d ''）
# ・YAML front matter は先頭の --- から次の --- までのみ解析
# ・closed が存在すれば除外
# ・due が無ければ末尾へ行くように 9999-12-31 にする

# awk: 状態機械で front matter を読む。配列 data[...] に格納。
parse_awk='
BEGIN{
  infm=0; seen_start=0; has_closed=0
  due=""; id=""; created=""; tags=""; parent=""
}
NR==1{
  if ($0=="---") {infm=1; seen_start=1; next}
  else {exit} # 先頭がfront matterでないなら対象外
}
infm{
  if ($0=="---"){ infm=0; done=1; next }
  # key: value の単純形のみ（必要十分）。値はそのまま格納。
  # 例: due: 2025-11-04
  #     tags: [design, restore, daily]
  #     closed: 2025-11-06T09:24:52*900
  if (match($0, /^([A-Za-z0-9_-]+):[ \t]*/)){
    key=substr($0, RSTART, RLENGTH)
    sub(/:.*$/,"",key)
    val=$0
    sub(/^[A-Za-z0-9_-]+:[ \t]*/,"",val)
    if (key=="closed" && length(val)>0) has_closed=1
    if (key=="due") due=val
    else if (key=="id") id=val
    else if (key=="created") created=val
    else if (key=="tags") tags=val
    else if (key=="parent") parent=val
  }
  next
}
# front matter 直後で終了（本文は見ない）
!infm && seen_start && !done { next }
END{
  if (has_closed) { exit }
  # due が YYYY-MM-DD でなければ末尾に飛ばす
  if (due !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) due="9999-12-31"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n", due, FILENAME, id, created, tags, parent
}'

# 収集
while IFS= read -r -d '' f; do
  # awk の終了コードは使わず、出力有無で判断（closed なら何も出ない）
  awk "$parse_awk" "$f" >>"$TMP" || true
done < <(
  find "$ROOT" \
    \( -type d \( -name .git -o -name node_modules -o -name .obsidian -o -name dashboards \) -prune \) -o \
    \( -type f -name '*.md' -print0 \)
)

# --- Sort & Render ------------------------------------------------------------
# due 昇順で整列
# フィールド:
#   1: due, 2: path, 3: id, 4: created, 5: tags, 6: parent
if [ -s "$TMP" ]; then
  LC_ALL=C sort -t $'\t' -k1,1 "$TMP" -o "$TMP"
fi

# 相対パス化（見やすさ優先。ROOT/ を取り除く）
relpath() {
  local p="$1"
  case "$p" in
    "$ROOT"/*) printf '%s\n' "${p#"$ROOT/"}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

# 出力Markdown
{
  printf '# Open Tasks by Due Date\n\n'
  printf '- Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '\n- Root: `%s`\n\n' "$ROOT"
  if [ ! -s "$TMP" ]; then
    printf '_No open notes found (all closed or no front matter)._ \n'
    exit 0
  fi
  printf '| Due | File | id | created | tags |\n'
  printf '| :-- | :--- | :-- | :------ | :--- |\n'
  while IFS=$'\t' read -r due path id created tags parent; do
    rp="$(relpath "$path")"
    # Markdown のリンクはローカル相対パスのまま
    printf '| %s | [%s](%s) | %s | %s | %s |\n' \
      "$due" "$rp" "$rp" "${id:-}" "${created:-}" "${tags:-}"
  done < "$TMP"
} > "$OUT"

echo "[OK] Wrote -> $OUT"
