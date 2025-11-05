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

[ "${VERBOSE:-}" = "1" ] && {
  echo "== DEBUG =="
  echo "PARENT: $PARENT"
  echo "ROOT:   $ROOT"
}

# A) 親のローカル未完 @行（@done除外）
mapfile -t LOCAL_TASKS < <(awk '
  BEGIN{inFM=0}
  { sub(/\r$/,"",$0); if (NR==1) sub(/^\xEF\xBB\xBF/,"",$0) }
  $0=="---"{inFM=1-inFM; next}
  inFM==0 && $0 ~ /^[[:space:]]*@/ && $0 !~ /^[[:space:]]*@done/ { print $0 }
' "$PARENT")
local_open=${#LOCAL_TASKS[@]}
[ "${VERBOSE:-}" = "1" ] && echo "local_open: $local_open"

# B1) Children 行の open= を直接読む
children_open_from_line=0
awk '
  BEGIN{inFM=0}
  { sub(/\r$/,"",$0) }
  $0=="---"{inFM=1-inFM; next}
  inFM==0 && $0 ~ /^Children:[[:space:]]*open=/ {
    s=$0; sub(/^Children:[[:space:]]*open=/,"",s)
    n=""
    for (i=1;i<=length(s);i++){ c=substr(s,i,1); if (c ~ /[0-9]/) n=n c; else break }
    if (n!="") print n
    exit
  }
' "$PARENT" | read -r n || true
if [ -n "${n:-}" ]; then children_open_from_line="$n"; fi
[ "${VERBOSE:-}" = "1" ] && echo "children_open_from_line: $children_open_from_line"

# B2) 本文の wikilink を走査（Front Matter外・コードフェンス外のみ）
#     ![[...]] は EMBED で除外、[[...]] のみ LINK として扱う。行番号も残す。
mapfile -t LINKS_RAW < <(awk '
  BEGIN{inFM=0; inFence=0}
  { raw=$0; sub(/\r$/,"",raw); line=raw }
  NR==1 { sub(/^\xEF\xBB\xBF/,"",line) }

  # Front Matter トグル
  line=="---" { inFM=1-inFM; next }

  # FM内はスキップ
  inFM==1 { next }

  # コードフェンス（``` または ~~~）の開始/終了
  if (match(line,/^(```|~~~)/)) { inFence = 1-inFence; next }
  if (inFence==1) { next }

  # 本文のみで [[...]] / ![[...]] を抽出（行番号付き）
  {
    s=line
    while (match(s, /!?(\[\[[^]]+\]\])/)) {
      token=substr(s,RSTART,RLENGTH)          # [[note]] or ![[img.png]]
      body=token; sub(/^!\[\[/,"[[",body)
      inner=substr(body,3,length(body)-4)     # [[...]] の ... 部分
      kind=(token ~ /^!\[\[/ ? "EMBED":"LINK")
      printf("%s\t%s\t%s\n", kind, inner, NR) # KIND<TAB>INNER<TAB>LINENO
      s=substr(s,RSTART+RLENGTH)
    }
  }
' "$PARENT")

[ "${VERBOSE:-}" = "1" ] && {
  echo "LINKS_RAW count: ${#LINKS_RAW[@]}"
  for e in "${LINKS_RAW[@]:-}"; do
    IFS=$'\t' read -r k inner ln <<<"$e"
    echo "  token: kind=$k line=$ln inner=[[${inner}]]"
  done
}

resolve_child() {
  local spec="$1"

  # [[ID|別名]] → 左側、末尾空白除去
  spec="${spec%%|*}"
  spec="${spec%%[[:space:]]*}"

  # [[#heading]] / [[^block]]：本体空ならスキップ
  if [[ "$spec" == \#* || "$spec" == \^* || -z "$spec" ]]; then
    echo "__SKIP__"
    return
  fi

  # [[Note#heading]] / [[Note^block]] → 本体
  spec="${spec%%#*}"
  spec="${spec%%^*}"

  # 拡張子判定
  local lower ext
  lower="$(printf '%s' "$spec" | tr "A-Z" "a-z")"
  ext="${lower##*.}"

  # 拡張子あり、かつ md/markdown 以外は添付 → 除外
  if [[ "$spec" == *.* ]] && [[ "$ext" != "md" && "$ext" != "markdown" ]]; then
    echo "__ATTACH__"
    return
  fi

  # 1) 拡張子付き（.md/.markdown）: 相対→ROOT
  if [[ "$ext" == "md" || "$ext" == "markdown" ]]; then
    local p1="$(dirname "$PARENT")/$spec"
    local p2="$ROOT/$spec"
    [ -f "$p1" ] && { echo "$(cd "$(dirname "$p1")" && pwd -P)/$(basename "$p1")"; return; }
    [ -f "$p2" ] && { echo "$(cd "$(dirname "$p2")" && pwd -P)/$(basename "$p2")"; return; }
  else
    # 2) 拡張子なし：name.md / name.markdown
    local p3="$(dirname "$PARENT")/$spec.md"
    local p4="$(dirname "$PARENT")/$spec.markdown"
    [ -f "$p3" ] && { echo "$p3"; return; }
    [ -f "$p4" ] && { echo "$p4"; return; }
    # 3) ワークスペース内探索
    local f
    f="$(/usr/bin/find "$ROOT" -maxdepth 8 -type f \( -name "$spec.md" -o -name "$spec.markdown" \) 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] && { echo "$f"; return; }
    f="$(/usr/bin/find "$ROOT" -maxdepth 8 -type f \( -path "*/$spec.md" -o -path "*/$spec.markdown" \) 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] && { echo "$f"; return; }
  fi

  echo ""  # 解決失敗
}

unresolved=0
child_open_scan=0
link_candidates=0

for raw in "${LINKS_RAW[@]:-}"; do
  IFS=$'\t' read -r kind inner lineno <<<"$raw"

  # 埋め込みは除外
  if [ "$kind" = "EMBED" ]; then
    [ "${VERBOSE:-}" = "1" ] && echo "[SKIP] embed: line=$lineno [[${inner}]]"
    continue
  fi

  path="$(resolve_child "$inner")"

  # 添付 / #heading / 空は除外
  if [ "$path" = "__ATTACH__" ] || [ "$path" = "__SKIP__" ]; then
    [ "${VERBOSE:-}" = "1" ] && echo "[SKIP] non-note: line=$lineno [[${inner}]]"
    continue
  fi

  # ここまで来たら「ノート候補」
  link_candidates=$((link_candidates+1))

  if [ -z "$path" ]; then
    unresolved=$((unresolved+1))
    [ "${VERBOSE:-}" = "1" ] && echo "[UNRESOLVED] line=$lineno [[${inner}]]"
    continue
  fi

  # 子の closed: をFMで検出
  flag=""
  awk '
    BEGIN{inFM=0}
    { sub(/\r$/,"",$0); if (NR==1) sub(/^\xEF\xBB\xBF/,"",$0) }
    $0=="---"{inFM=1-inFM; next}
    inFM==1 && $0 ~ /^closed:[[:space:]]*/ { print "CLOSED"; exit }
  ' "$path" | read -r flag || true

  if [ "${flag:-}" != "CLOSED" ]; then
    child_open_scan=$((child_open_scan+1))
    [ "${VERBOSE:-}" = "1" ] && echo "[OPEN] $(basename "${path%.*}") (from line $lineno)"
  fi
done

# ★ 安全ガード：本文にノート候補の LINK が1件も無ければ unresolved は 0 扱いにする
if [ "$link_candidates" -eq 0 ]; then
  unresolved=0
fi

[ "${VERBOSE:-}" = "1" ] && {
  echo "link_candidates: $link_candidates"
  echo "unresolved:      $unresolved"
  echo "child_open_scan: $child_open_scan"
}

# 最終判定
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
