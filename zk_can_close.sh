#!/usr/bin/env bash
# zk_can_close.sh <parent.md>
# 0=閉じてOK / 1=NG（未完あり or リンク未解決）
set -eu

PARENT_IN="${1:-}"
[ -n "$PARENT_IN" ] || { echo "usage: $0 <parent.md>"; exit 2; }

# Windowsパス→POSIX変換（Git Bash対応）
PARENT="$PARENT_IN"
if command -v cygpath >/dev/null 2>&1; then
  [[ "$PARENT" =~ ^[A-Za-z]:\\ ]] && PARENT="$(cygpath -u "$PARENT")"
fi
[ -f "$PARENT" ] || { echo "No such file: $PARENT_IN (resolved: $PARENT)"; exit 2; }

# ===== ワークスペースルートを推定 =====
if [ -n "${WORKSPACE_ROOT:-}" ] && [ -d "$WORKSPACE_ROOT" ]; then
  ROOT="$WORKSPACE_ROOT"
elif command -v git >/dev/null 2>&1 && git -C "$(dirname "$PARENT")" rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git -C "$(dirname "$PARENT")" rev-parse --show-toplevel)"
else
  ROOT="$(cd "$(dirname "$PARENT")" && pwd -P)"
fi

[ "${VERBOSE:-}" = "1" ] && {
  echo "== DEBUG =="; echo "PARENT: $PARENT"; echo "ROOT:   $ROOT"
}

# ===== A) 親ノート内のローカル未完タスクを抽出 =====
mapfile -t LOCAL_TASKS < <(awk '
  BEGIN { inFM=0 }
  { sub(/\r$/, "", $0); if (NR==1) sub(/^\xEF\xBB\xBF/, "", $0) }
  $0=="---" { inFM = 1 - inFM; next }
  inFM==0 && $0 ~ /^[[:space:]]*@/ && $0 !~ /^[[:space:]]*@done/ { print $0 }
' "$PARENT")
local_open=${#LOCAL_TASKS[@]}
[ "${VERBOSE:-}" = "1" ] && echo "local_open: $local_open"

# ===== B1) Children 行の open= を直接読む =====
children_open_from_line=0
awk '
  BEGIN { inFM=0 }
  { sub(/\r$/, "", $0) }
  $0=="---" { inFM = 1 - inFM; next }
  inFM==0 && $0 ~ /^Children:[[:space:]]*open=/ {
    s=$0; sub(/^Children:[[:space:]]*open=/, "", s);
    n="";
    for (i=1; i<=length(s); i++) {
      c=substr(s,i,1);
      if (c ~ /[0-9]/) n=n c; else break;
    }
    if (n!="") print n;
    exit;
  }
' "$PARENT" | read -r n || true
if [ -n "${n:-}" ]; then children_open_from_line="$n"; fi
[ "${VERBOSE:-}" = "1" ] && echo "children_open_from_line: $children_open_from_line"

# ===== B2) 本文中の wikilink を抽出 =====
# mawk対策：正規表現は最小限、フェンス検出は substr 方式
mapfile -t LINKS_RAW < <(awk '
  BEGIN { inFM=0; inFence=0 }
  { raw=$0; sub(/\r$/, "", raw); line=raw }
  NR==1 { sub(/^\xEF\xBB\xBF/, "", line) }

  # Front Matter トグル
  if (line == "---") { inFM = 1 - inFM; next; }

  # FM内はスキップ
  if (inFM == 1) { next; }

  # コードフェンス開始/終了検出
  head3 = (length(line) >= 3 ? substr(line, 1, 3) : line);
  if (head3 == "```" || head3 == "~~~") { inFence = (inFence == 0 ? 1 : 0); next; }
  if (inFence == 1) { next; }

  # 本文で [[...]] / ![[...]] を抽出
  s = line;
  while (match(s, /!?($begin:math:display$\\[[^]]+$end:math:display$\])/)) {
    token = substr(s, RSTART, RLENGTH);
    body = token;
    sub(/^!\[\[/, "[[", body);
    inner = substr(body, 3, length(body) - 4);
    kind = (token ~ /^!\[\[/ ? "EMBED" : "LINK");
    printf("%s\t%s\t%s\n", kind, inner, NR);
    s = substr(s, RSTART + RLENGTH);
  }
' "$PARENT")

[ "${VERBOSE:-}" = "1" ] && {
  echo "LINKS_RAW count: ${#LINKS_RAW[@]}"
  for e in "${LINKS_RAW[@]:-}"; do
    IFS=$'\t' read -r k inner ln <<<"$e"
    echo "  token: kind=$k line=$ln inner=[[${inner}]]"
  done
}

# ===== リンク解決関数 =====
resolve_child() {
  local spec="$1"
  spec="${spec%%|*}"; spec="${spec%%[[:space:]]*}"

  # [[#heading]] / [[^block]] → skip
  if [[ "$spec" == \#* || "$spec" == \^* || -z "$spec" ]]; then
    echo "__SKIP__"; return
  fi

  spec="${spec%%#*}"; spec="${spec%%^*}"
  local lower ext
  lower="$(printf '%s' "$spec" | tr "A-Z" "a-z")"
  ext="${lower##*.}"

  # 添付など(md以外拡張子)
  if [[ "$spec" == *.* ]] && [[ "$ext" != "md" && "$ext" != "markdown" ]]; then
    echo "__ATTACH__"; return
  fi

  if [[ "$ext" == "md" || "$ext" == "markdown" ]]; then
    local p1="$(dirname "$PARENT")/$spec"
    local p2="$ROOT/$spec"
    [ -f "$p1" ] && { echo "$(cd "$(dirname "$p1")" && pwd -P)/$(basename "$p1")"; return; }
    [ -f "$p2" ] && { echo "$(cd "$(dirname "$p2")" && pwd -P)/$(basename "$p2")"; return; }
  else
    local p3="$(dirname "$PARENT")/$spec.md"
    local p4="$(dirname "$PARENT")/$spec.markdown"
    [ -f "$p3" ] && { echo "$p3"; return; }
    [ -f "$p4" ] && { echo "$p4"; return; }
    local f
    f="$(/usr/bin/find "$ROOT" -maxdepth 8 -type f $begin:math:text$ -name "$spec.md" -o -name "$spec.markdown" $end:math:text$ 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] && { echo "$f"; return; }
    f="$(/usr/bin/find "$ROOT" -maxdepth 8 -type f $begin:math:text$ -path "*/$spec.md" -o -path "*/$spec.markdown" $end:math:text$ 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] && { echo "$f"; return; }
  fi

  echo ""
}

# ===== C) 子ノート検査 =====
unresolved=0
child_open_scan=0
link_candidates=0

for raw in "${LINKS_RAW[@]:-}"; do
  IFS=$'\t' read -r kind inner lineno <<<"$raw"

  # 画像/埋め込みスキップ
  if [ "$kind" = "EMBED" ]; then
    [ "${VERBOSE:-}" = "1" ] && echo "[SKIP] embed: line=$lineno [[${inner}]]"
    continue
  fi

  path="$(resolve_child "$inner")"

  # 添付や#headingは除外
  if [ "$path" = "__ATTACH__" ] || [ "$path" = "__SKIP__" ]; then
    [ "${VERBOSE:-}" = "1" ] && echo "[SKIP] non-note: line=$lineno [[${inner}]]"
    continue
  fi

  link_candidates=$((link_candidates+1))

  if [ -z "$path" ]; then
    unresolved=$((unresolved+1))
    [ "${VERBOSE:-}" = "1" ] && echo "[UNRESOLVED] line=$lineno [[${inner}]]"
    continue
  fi

  flag=""
  awk '
    BEGIN { inFM=0 }
    { sub(/\r$/, "", $0); if (NR==1) sub(/^\xEF\xBB\xBF/, "", $0) }
    $0=="---" { inFM = 1 - inFM; next }
    inFM==1 && $0 ~ /^closed:[[:space:]]*/ { print "CLOSED"; exit }
  ' "$path" | read -r flag || true

  if [ "${flag:-}" != "CLOSED" ]; then
    child_open_scan=$((child_open_scan+1))
    [ "${VERBOSE:-}" = "1" ] && echo "[OPEN] $(basename "${path%.*}") (from line $lineno)"
  fi
done

# 本文にリンク候補が無ければ unresolved=0
if [ "$link_candidates" -eq 0 ]; then
  unresolved=0
fi

[ "${VERBOSE:-}" = "1" ] && {
  echo "link_candidates: $link_candidates"
  echo "unresolved:      $unresolved"
  echo "child_open_scan: $child_open_scan"
}

# ===== D) 判定 =====
if [ "$unresolved" -gt 0 ] \
   || [ "$children_open_from_line" -gt 0 ] \
   || [ "$child_open_scan" -gt 0 ] \
   || [ "$local_open" -gt 0 ]; then
  echo "[NG] not closable."
  echo "  - local open tasks: $local_open"
  echo "  - children(open) by line: $children_open_from_line"
  echo "  - children(open) by scan: $child_open_scan"
  echo "  - unresolved links: $unresolved"
  exit 1
fi

echo "[OK] closable: no local @tasks, no open children, no unresolved links."
exit 0
