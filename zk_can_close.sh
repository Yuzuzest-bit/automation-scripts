#!/usr/bin/env bash
# zk_can_close.sh <note.md>
# 0=閉じてOK / 1=NG（未完あり or リンク未解決）
set -eu

PARENT_IN="${1:-}"
[ -n "$PARENT_IN" ] || { echo "usage: $0 <note.md>"; exit 2; }

# Windowsパス→POSIX
PARENT="$PARENT_IN"
if command -v cygpath >/dev/null 2>&1; then
  [[ "$PARENT" =~ ^[A-Za-z]:\\ ]] && PARENT="$(cygpath -u "$PARENT")"
fi
[ -f "$PARENT" ] || { echo "No such file: $PARENT_IN (resolved: $PARENT)"; exit 2; }

# AWK 実体（gawk 優先）
AWK_BIN="$(command -v gawk || command -v awk)"
[ -n "$AWK_BIN" ] || { echo "awk not found"; exit 2; }

# ワークスペースルート
if [ -n "${WORKSPACE_ROOT:-}" ] && [ -d "$WORKSPACE_ROOT" ]; then
  ROOT="$WORKSPACE_ROOT"
elif command -v git >/dev/null 2>&1 && git -C "$(dirname "$PARENT")" rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git -C "$(dirname "$PARENT")" rev-parse --show-toplevel)"
else
  ROOT="$(cd "$(dirname "$PARENT")" && pwd -P)"
fi

TMPDIR_LOCAL="$(dirname "$PARENT")"
AWK_LOCAL_TASKS="$(mktemp "$TMPDIR_LOCAL/.zk_local_tasks.XXXX.awk")"
AWK_CHILDREN_LINE="$(mktemp "$TMPDIR_LOCAL/.zk_children_line.XXXX.awk")"
AWK_LINKS_RAW="$(mktemp "$TMPDIR_LOCAL/.zk_links_raw.XXXX.awk")"
AWK_CHILD_CLOSED="$(mktemp "$TMPDIR_LOCAL/.zk_child_closed.XXXX.awk")"
AWK_DECLARED_PARENT="$(mktemp "$TMPDIR_LOCAL/.zk_declared_parent.XXXX.awk")"
trap 'rm -f "$AWK_LOCAL_TASKS" "$AWK_CHILDREN_LINE" "$AWK_LINKS_RAW" "$AWK_CHILD_CLOSED" "$AWK_DECLARED_PARENT"' EXIT

# A) ローカル未完 @行（@done 除外）
cat >"$AWK_LOCAL_TASKS" <<'AWK'
BEGIN { inFM=0 }
{
  sub(/\r$/, "", $0);
  if (NR==1) sub(/^\xEF\xBB\xBF/, "", $0);
}
$0=="---" { inFM = 1 - inFM; next }
inFM==0 && $0 ~ /^[[:space:]]*@/ && $0 !~ /^[[:space:]]*@done/ { print $0 }
AWK

# B1) Children: open= 行
cat >"$AWK_CHILDREN_LINE" <<'AWK'
BEGIN { inFM=0 }
{
  sub(/\r$/, "", $0);
}
$0=="---" { inFM = 1 - inFM; next }
inFM==0 && $0 ~ /^Children:[[:space:]]*open=/ {
  s=$0; sub(/^Children:[[:space:]]*open=/, "", s);
  n="";
  for (i=1; i<=length(s); i++) { c=substr(s,i,1); if (c ~ /[0-9]/) n=n c; else break; }
  if (n!="") print n;
  exit;
}
AWK

# B2) 本文の [[...]] / ![[...]] 抽出（FM外・フェンス外のみ）
cat >"$AWK_LINKS_RAW" <<'AWK'
BEGIN { inFM=0; inFence=0 }
{
  raw=$0; sub(/\r$/, "", raw); line=raw;
  if (NR==1) sub(/^\xEF\xBB\xBF/, "", line);
}
# FMトグル
(line=="---") { inFM=1-inFM; next }
(inFM==1) { next }

# コードフェンス（先頭3文字が``` or ~~~）
{
  head3 = (length(line)>=3 ? substr(line,1,3) : line);
  if (head3=="```" || head3=="~~~") { inFence = (inFence==0 ? 1 : 0); next }
  if (inFence==1) { next }
}

# 本文の [[...]] / ![[...]]（行番号付き）
{
  s=line;
  while (match(s, /!?(\[\[[^]]+\]\])/)) {
    token = substr(s, RSTART, RLENGTH);
    body = token; sub(/^!\[\[/, "[[", body);
    inner = substr(body, 3, length(body) - 4);
    kind = (token ~ /^!\[\[/ ? "EMBED" : "LINK");
    printf("%s\t%s\t%s\n", kind, inner, NR);
    s = substr(s, RSTART + RLENGTH);
  }
}
AWK

# 子の closed: を FM から検出
cat >"$AWK_CHILD_CLOSED" <<'AWK'
BEGIN { inFM=0 }
{
  sub(/\r$/, "", $0);
  if (NR==1) sub(/^\xEF\xBB\xBF/, "", $0);
}
$0=="---" { inFM=1-inFM; next }
inFM==1 && $0 ~ /^closed:[[:space:]]*/ { print "CLOSED"; exit }
AWK

# ★ 追加：そのノートが明示している「親」を1つだけ拾う（FM優先→本文）
cat >"$AWK_DECLARED_PARENT" <<'AWK'
BEGIN { inFM=0; got="" }
{
  sub(/\r$/, "", $0);
  if (NR==1) sub(/^\xEF\xBB\xBF/, "", $0);
}
# FMトグル
$0=="---" { inFM=1-inFM; next }

# FM内 parent: [[...]] を最優先で1つだけ
inFM==1 && got=="" {
  if ($0 ~ /^parent:[[:space:]]*\[\[[^]]+\]\]/) {
    line=$0; sub(/^parent:[[:space:]]*\[\[/,"",line); sub(/\]\].*$/,"",line);
    print line; exit
  }
  next
}

# 本文側に parent: [[...]] があれば補助的に1つ
inFM==0 && got=="" {
  if ($0 ~ /^parent:[[:space:]]*\[\[[^]]+\]\]/) {
    line=$0; sub(/^parent:[[:space:]]*\[\[/,"",line); sub(/\]\].*$/,"",line);
    print line; exit
  }
}
AWK

# 実行：ローカル未完
mapfile -t LOCAL_TASKS < <("$AWK_BIN" -f "$AWK_LOCAL_TASKS" "$PARENT")
local_open=${#LOCAL_TASKS[@]}

# Children: open=
children_open_from_line=0
n="$("$AWK_BIN" -f "$AWK_CHILDREN_LINE" "$PARENT" || true)"
[ -n "$n" ] && children_open_from_line="$n"

# 本文リンク
mapfile -t LINKS_RAW < <("$AWK_BIN" -f "$AWK_LINKS_RAW" "$PARENT")

# 宣言された「親」名（未指定なら空）
declared_parent_spec="$("$AWK_BIN" -f "$AWK_DECLARED_PARENT" "$PARENT" || true)"

# デバッグ
[ "${VERBOSE:-}" = "1" ] && {
  echo "== DEBUG ==";
  echo "NOTE: $PARENT"
  echo "ROOT: $ROOT"
  echo "local_open: $local_open"
  echo "children_open_from_line: $children_open_from_line"
  echo "declared_parent_spec: [$declared_parent_spec]"
  echo "LINKS_RAW count: ${#LINKS_RAW[@]}"
  for e in "${LINKS_RAW[@]:-}"; do
    IFS=$'\t' read -r k inner ln <<<"$e"
    echo "  token: kind=$k line=$ln inner=[[${inner}]]"
  done
}

# 文字列spec → 実パス解決（.md/.markdownのみ）
resolve_child() {
  local spec="$1"
  spec="${spec%%|*}"; spec="${spec%%[[:space:]]*}"   # [[ID|別名]]

  # [[#heading]] / [[^block]] / 空 → スキップ
  if [[ "$spec" == \#* || "$spec" == \^* || -z "$spec" ]]; then
    echo "__SKIP__"; return
  fi

  # #heading / ^block を切り落とし
  spec="${spec%%#*}"; spec="${spec%%^*}"

  # 添付（拡張子あり・md以外）は除外
  local lower ext
  lower="$(printf '%s' "$spec" | tr 'A-Z' 'a-z')"
  ext="${lower##*.}"
  if [[ "$spec" == *.* ]] && [[ "$ext" != "md" && "$ext" != "markdown" ]]; then
    echo "__ATTACH__"; return
  fi

  # 解決
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
    f="$(/usr/bin/find "$ROOT" -maxdepth 8 -type f \( -name "$spec.md" -o -name "$spec.markdown" \) 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] && { echo "$f"; return; }
    f="$(/usr/bin/find "$ROOT" -maxdepth 8 -type f \( -path "*/$spec.md" -o -path "*/$spec.markdown" \) 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] && { echo "$f"; return; }
  fi

  echo ""  # 解決失敗
}

# 宣言された親の実パスを求める（あれば）
declared_parent_path=""
if [ -n "$declared_parent_spec" ]; then
  rp="$(resolve_child "$declared_parent_spec" || true)"
  # 親ノートが .md で存在する場合のみ採用
  if [ -n "$rp" ] && [ "$rp" != "__ATTACH__" ] && [ "$rp" != "__SKIP__" ]; then
    declared_parent_path="$rp"
  fi
fi

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

  # ★ ここが肝：そのノートが宣言している親へのリンクは「子」として扱わない
  if [ -n "$declared_parent_path" ] && [ -n "$path" ] && [ "$path" = "$declared_parent_path" ]; then
    [ "${VERBOSE:-}" = "1" ] && echo "[SKIP] backlink-to-parent: line=$lineno [[${inner}]]"
    continue
  fi

  # 自分自身へのループリンクも除外（稀にあるので）
  if [ -n "$path" ] && [ "$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")" = "$(cd "$(dirname "$PARENT")" && pwd -P)/$(basename "$PARENT")" ]; then
    [ "${VERBOSE:-}" = "1" ] && echo "[SKIP] self-link: line=$lineno [[${inner}]]"
    continue
  fi

  # ここまで来たら下向きの子リンク候補
  link_candidates=$((link_candidates+1))

  if [ -z "$path" ]; then
    unresolved=$((unresolved+1))
    [ "${VERBOSE:-}" = "1" ] && echo "[UNRESOLVED] line=$lineno [[${inner}]]"
    continue
  fi

  # 子の closed: をFMで確認
  flag="$("$AWK_BIN" -f "$AWK_CHILD_CLOSED" "$path" || true)"
  if [ "$flag" != "CLOSED" ]; then
    child_open_scan=$((child_open_scan+1))
    [ "${VERBOSE:-}" = "1" ] && echo "[OPEN] $(basename "${path%.*}") (from line $lineno)"
  fi
done

# 本文に子リンク候補が無ければ unresolved=0
if [ "$link_candidates" -eq 0 ]; then
  unresolved=0
fi

[ "${VERBOSE:-}" = "1" ] && {
  echo "declared_parent_path: $declared_parent_path"
  echo "link_candidates: $link_candidates"
  echo "unresolved:      $unresolved"
  echo "child_open_scan: $child_open_scan"
}

# 判定
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
