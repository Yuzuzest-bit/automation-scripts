#!/usr/bin/env bash
# zk_can_close.sh <parent.md>
# 0=閉じてOK / 1=NG（未完あり or リンク未解決）
set -eu

PARENT_IN="${1:-}"; [ -n "$PARENT_IN" ] || { echo "usage: $0 <parent.md>"; exit 2; }

# Windowsパス→POSIX
PARENT="$PARENT_IN"
if command -v cygpath >/dev/null 2>&1; then
  [[ "$PARENT" =~ ^[A-Za-z]:\\ ]] && PARENT="$(cygpath -u "$PARENT")"
fi
[ -f "$PARENT" ] || { echo "No such file: $PARENT_IN (resolved: $PARENT)"; exit 2; }

# ワークスペース根（環境変数 > Git root > 親DIR）
if [ -n "${WORKSPACE_ROOT:-}" ] && [ -d "$WORKSPACE_ROOT" ]; then
  ROOT="$WORKSPACE_ROOT"
elif command -v git >/dev/null 2>&1 && git -C "$(dirname "$PARENT")" rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git -C "$(dirname "$PARENT")" rev-parse --show-toplevel)"
else
  ROOT="$(cd "$(dirname "$PARENT")" && pwd -P)"
fi

# A) 親のローカル未完 @行（@done除外）
mapfile -t LOCAL_TASKS < <(awk '
  BEGIN{inFM=0}
  { sub(/\r$/,"",$0); if (NR==1) sub(/^\xEF\xBB\xBF/,"",$0) }
  $0=="---"{inFM=1-inFM; next}
  inFM==0 && $0 ~ /^[[:space:]]*@/ && $0 !~ /^[[:space:]]*@done/ { print $0 }
' "$PARENT")
local_open=${#LOCAL_TASKS[@]}

# B1) Children 行の open= を直接読む（Rollupが最新ならこれが最速・確実）
children_open_from_line=0
awk '
  BEGIN{inFM=0; got=0}
  { sub(/\r$/,"",$0) }
  $0=="---"{inFM=1-inFM; next}
  inFM==0 && $0 ~ /^Children:[[:space:]]*open=/ {
    # 例: Children: open=2 next_due=2025-11-04
    s=$0
    sub(/^Children:[[:space:]]*open=/,"",s)
    n=""
    for (i=1;i<=length(s);i++){ c=substr(s,i,1); if (c ~ /[0-9]/) n=n c; else break }
    if (n!="") print n
    exit
  }
' "$PARENT" | read -r n || true
if [ -n "${n:-}" ]; then children_open_from_line="$n"; fi

# B2) 念のため、親本文の wikilink を走査して未クローズ子を数える（リンク未解決はNG）
resolve_child() {
  local spec="$1"
  spec="${spec%%|*}"; spec="${spec%%[[:space:]]*}"
  # 拡張子つき相対/絶対
  if [[ "$spec" == *.md || "$spec" == *.markdown ]]; then
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
    f="$(/usr/bin/find "$ROOT" -maxdepth 8 -type f \( -name "$spec.md" -o -name "$spec.markdown" \) 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] && { echo "$f"; return; }
    f="$(/usr/bin/find "$ROOT" -maxdepth 8 -type f \( -path "*/$spec.md" -o -path "*/$spec.markdown" \) 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] && { echo "$f"; return; }
  fi
  echo ""
}

mapfile -t LINKS < <(awk '
  { sub(/\r$/,"",$0); s=$0 }
  {
    while (match(s, /\[\[[^]]+\]\]/)) {
      body=substr(s,RSTART+2,RLENGTH-4)
      print body
      s=substr(s,RSTART+RLENGTH)
    }
  }
' "$PARENT")

unresolved=0
child_open_scan=0
for raw in "${LINKS[@]:-}"; do
  path="$(resolve_child "$raw")"
  if [ -z "$path" ]; then
    unresolved=$((unresolved+1))
    continue
  fi
  # 子の closed: をFMで検出
  closed=""
  awk '
    BEGIN{inFM=0}
    { sub(/\r$/,"",$0); if (NR==1) sub(/^\xEF\xBB\xBF/,"",$0) }
    $0=="---"{inFM=1-inFM; next}
    inFM==1 && $0 ~ /^closed:[[:space:]]*/ { print "CLOSED"; exit }
  ' "$path" | read -r flag || true
  if [ "${flag:-}" != "CLOSED" ]; then
    child_open_scan=$((child_open_scan+1))
  fi
done

# 最終判定（どれか1つでも残ってたらNG）
if [ "$unresolved" -gt 0 ] || [ "$children_open_from_line" -gt 0 ] || [ "$child_open_scan" -gt 0 ] || [ "$local_open" -gt 0 ]; then
  echo "[NG] not closable."
  echo "  - local open tasks: $local_open"
  echo "  - children(open) by line: $children_open_from_line"
  echo "  - children(open) by scan: $child_open_scan"
  echo "  - unresolved links: $unresolved"
  exit 1
fi

echo "[OK] closable: no local @tasks, no open children, no unresolved links."
exit 0
