#!/usr/bin/env bash
# zk_children_rollup.sh (Windows Git Bash / mac / Linux)
# 親MDの本文（= Front Matter外・コードフェンス外）にある [[...]] だけを子候補として走査
# - ![[...]]（埋め込み）は無視
# - [[note#heading]] / [[^block]] は無視
# - [[image.png]] など .md/.markdown 以外は無視
# - [[ID|別名]] は ID 側を採用
# 子: FMに closed: があれば CLOSED
# 子: 本文先頭@行の due:YYYY-MM-DD の最小を next_due に採用（@done は除外）
# 結果は FM 直後の "Children: open=N [next_due=YYYY-MM-DD]" として挿入/更新

set -euo pipefail

PARENT_IN="${1:-}"
[ -n "$PARENT_IN" ] || { echo "usage: $0 <parent.md>" >&2; exit 1; }

# Windowsパス -> POSIX
PARENT="$PARENT_IN"
if command -v cygpath >/dev/null 2>&1; then
  [[ "$PARENT" =~ ^[A-Za-z]:\\ ]] && PARENT="$(cygpath -u "$PARENT")"
fi
[ -f "$PARENT" ] || { echo "Not a regular file: $PARENT_IN (resolved: $PARENT)" >&2; exit 1; }

# ルート（WORKSPACE_ROOT > git root > 親DIR）
if [ -n "${WORKSPACE_ROOT:-}" ] && [ -d "$WORKSPACE_ROOT" ]; then
  ROOT="$WORKSPACE_ROOT"
elif command -v git >/dev/null 2>&1 && git -C "$(dirname "$PARENT")" rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git -C "$(dirname "$PARENT")" rev-parse --show-toplevel)"
else
  ROOT="$(cd "$(dirname "$PARENT")" && pwd -P)"
fi

AWK_BIN="$(command -v gawk || command -v awk)"
FIND_BIN="$(command -v find || true)"
[ -n "$AWK_BIN" ] || { echo "awk not found"; exit 1; }
[ -n "$FIND_BIN" ] || { echo "find not found"; exit 1; }

# --- 本文（FM外・コードフェンス外）から [[...]] / ![[...]] を抽出（行番号つき） ---
# kind=LINK だけを採用（EMBEDは無視）
mapfile -t LINKS_RAW < <("$AWK_BIN" '
BEGIN { inFM=0; inFence=0 }
{
  raw=$0; sub(/\r$/, "", raw); line=raw;
  if (NR==1) sub(/^\xEF\xBB\xBF/, "", line);
}
# FMトグル（--- の行、末尾空白許容）
line ~ /^---[[:space:]]*$/ { inFM=1-inFM; next }
(inFM==1) { next }

# コードフェンス（行頭空白OK、``` or ~~~ でトグル）
{
  t=line; sub(/^[[:space:]]+/, "", t);
  head3 = (length(t)>=3 ? substr(t,1,3) : t);
  if (head3=="```" || head3=="~~~") { inFence = (inFence==0 ? 1 : 0); next }
  if (inFence==1) { next }
}

# 本文の [[...]] / ![[...]]（行番号付き）
{
  s=line;
  while (match(s, /!?(\[\[[^]]+\]\])/)) {
    token = substr(s, RSTART, RLENGTH);  # [[...]] or ![[...]]
    body  = token; sub(/^!\[\[/, "[[", body);    # ![[...]] → [[...]]
    inner = substr(body, 3, length(body)-4);     # ... 部分
    kind  = (token ~ /^!\[\[/ ? "EMBED":"LINK"); # 種別
    printf("%s\t%s\t%s\t%s\n", kind, inner, NR, token);
    s = substr(s, RSTART+RLENGTH);
  }
}
' "$PARENT")

[ "${VERBOSE:-0}" -ge 1 ] && {
  echo "== DEBUG: LINKS_RAW (FM外/フェンス外) =="
  for e in "${LINKS_RAW[@]:-}"; do
    IFS=$'\t' read -r kind inner ln tok <<<"$e"
    echo "  line=$ln kind=$kind inner=[[${inner}]] raw=${tok}"
  done
}

# --- spec → 実パス解決（.md/.markdown のみ、添付/アンカー除外） ---
canon() {
  local p="$1"
  (cd "$(dirname "$p")" 2>/dev/null && pwd -P)/"$(basename "$p")"
}

resolve_child_path() {
  local spec="$1" ; local debugpfx="$2"
  local raw="$spec"
  spec="${spec%%|*}"          # [[ID|別名]] → ID
  # [[#heading]] / [[^block]] / 空 → スキップ（子扱いしない）
  [[ -z "$spec" || "$spec" == \#* || "$spec" == \^* ]] && { echo "__SKIP__"; return; }
  spec="${spec%%#*}"; spec="${spec%%^*}"   # アンカー除去（内部空白は保持）

  # 添付（拡張子あり かつ md/markdown 以外）は無視
  local lower ext
  lower="$(printf '%s' "$spec" | tr "A-Z" "a-z")"
  ext="${lower##*.}"
  if [[ "$spec" == *.* ]] && [[ "$ext" != "md" && "$ext" != "markdown" ]]; then
    echo "__ATTACH__"; return
  fi

  # 候補
  local p1="$(canon "$(dirname "$PARENT")/$spec")"
  local p2="$(canon "$ROOT/$spec")"
  local p3="$(canon "$(dirname "$PARENT")/$spec.md")"
  local p4="$(canon "$(dirname "$PARENT")/$spec.markdown")"

  [ -f "$p1" ] && { echo "$p1"; return; }
  [ -f "$p2" ] && { echo "$p2"; return; }
  [ -f "$p3" ] && { echo "$p3"; return; }
  [ -f "$p4" ] && { echo "$p4"; return; }

  # ルート検索（スペース/日本語OK）
  local f=""
  f="$("$FIND_BIN" "$ROOT" -maxdepth 8 -type f \( -name "$spec.md" -o -name "$spec.markdown" -o -path "*/$spec.md" -o -path "*/$spec.markdown" \) -print 2>/dev/null | head -n1 || true)"
  [ -n "$f" ] && { echo "$(canon "$f")"; return; }

  [ "${VERBOSE:-0}" -ge 2 ] && {
    echo "[DBG] $debugpfx unresolved [[${raw}]]" >&2
    echo "      tried: $p1" >&2
    echo "             $p2" >&2
    echo "             $p3" >&2
    echo "             $p4" >&2
  }
  echo ""
}

# --- 子の状態と due 最小を集計 ---
open_count=0
earliest="9999-99-99"
link_candidates=0

for rec in "${LINKS_RAW[@]:-}"; do
  IFS=$'\t' read -r kind inner ln tok <<<"$rec"

  # 埋め込みは無視
  [ "$kind" = "EMBED" ] && continue

  # spec を解決
  ch_path="$(resolve_child_path "$inner" "line=$ln")"

  # 添付・アンカー・空は無視
  if [ "$ch_path" = "__ATTACH__" ] || [ "$ch_path" = "__SKIP__" ]; then
    [ "${VERBOSE:-0}" -ge 2 ] && echo "[DBG] line=$ln skip non-note: ${tok}" >&2
    continue
  fi

  # 実体が無ければスキップ（未解決リンクは子扱いしない）
  [ -z "$ch_path" ] && { [ "${VERBOSE:-0}" -ge 1 ] && echo "[SKIP] unresolved: line=$ln ${tok}"; continue; }

  link_candidates=$((link_candidates+1))

  # 子が CLOSED かどうか（FMの closed: で判定）
  state="OPEN"; due="-"
  closed_flag="$("$AWK_BIN" '
    BEGIN{inFM=0}
    {
      sub(/\r$/, "", $0);
      if (NR==1) sub(/^\xEF\xBB\xBF/, "", $0);
    }
    $0 ~ /^---[[:space:]]*$/ { inFM=1-inFM; next }
    inFM==1 && $0 ~ /^closed:[[:space:]]*/ { print "CLOSED"; exit }
  ' "$ch_path" || true)"

  if [ "$closed_flag" = "CLOSED" ]; then
    [ "${VERBOSE:-0}" -ge 1 ] && echo "[OK-CHILD-CLOSED] $(basename "${ch_path%.*}") (line $ln)"
    continue
  fi

  # OPEN の場合、本文の @行から due 最小を拾う（@done は除外）
  dmin="9999-99-99"
  while IFS= read -r cl; do
    cl="${cl%$'\r'}"
    [[ "${cl:0:1}" = "@" ]] || continue
    [[ "$cl" == @done* ]] && continue
    [[ "$cl" == *"due:"* ]] || continue
    cand="${cl#*due:}"; cand="${cand:0:10}"
    [[ "$cand" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    [[ "$cand" < "$dmin" ]] && dmin="$cand"
  done < "$ch_path"

  open_count=$((open_count+1))
  if [ "$dmin" != "9999-99-99" ] && [[ "$dmin" < "$earliest" ]]; then
    earliest="$dmin"
  fi
  [ "${VERBOSE:-0}" -ge 1 ] && echo "[OPEN] child $(basename "${ch_path%.*}") due=${dmin} (from line $ln)"
done

# --- 書き戻し（FM直後） ---
children="Children: open=${open_count}"
[ "$earliest" != "9999-99-99" ] && children="${children} next_due=${earliest}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
inFM=0 inserted=0
while IFS= read -r line; do
  # CRLF 耐性
  [ "${line%$'\r'}" != "$line" ] && line="${line%$'\r'}"

  if [ "$line" = "---" ]; then
    inFM=$((1-inFM))
    echo "$line" >> "$TMP"
    if [ $inFM -eq 0 ] && [ $inserted -eq 0 ]; then
      echo "$children" >> "$TMP"
      inserted=1
    fi
    continue
  fi

  # 既存 Children 行は捨てる（常に最新へ差し替え）
  if [ $inFM -eq 0 ] && [[ "$line" == "Children:"* ]]; then
    continue
  fi

  echo "$line" >> "$TMP"
done < "$PARENT"

mv "$TMP" "$PARENT"
echo "[OK] Children rollup updated -> $PARENT"
[ "${VERBOSE:-0}" -ge 1 ] && echo "summary: candidates=${link_candidates} open=${open_count} earliest=${earliest}"
