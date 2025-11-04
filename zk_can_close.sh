#!/usr/bin/env bash
# zk_can_close.sh <parent.md>
# 返り値: 0=閉じてOK / 1=NG（未完あり）
# 出力: 理由を標準出力に要約

set -eu
PARENT_IN="${1:-}"; [ -n "$PARENT_IN" ] || { echo "usage: $0 <parent.md>"; exit 2; }

# Windowsパス→POSIX
PARENT="$PARENT_IN"
if command -v cygpath >/dev/null 2>&1; then
  [[ "$PARENT" =~ ^[A-Za-z]:\\ ]] && PARENT="$(cygpath -u "$PARENT")"
fi
[ -f "$PARENT" ] || { echo "No such file: $PARENT_IN (resolved: $PARENT)"; exit 2; }

root_dir="$(cd "$(dirname "$PARENT")" && pwd -P)"

# A) 親自身の未完 @ タスク（@doneは除外）
local_open=0
mapfile -t LOCAL_TASKS < <(awk '
  BEGIN{inFM=0}
  { sub(/\r$/,"",$0) }
  $0=="---"{inFM=1-inFM; next}
  inFM==0 && $0 ~ /^@/ {
    if ($0 ~ /^@done/) next
    print $0
  }' "$PARENT")
local_open=${#LOCAL_TASKS[@]}

# B) 子ノート（wikilink）の未クローズ数
resolve() {
  local base="$1"
  # 1) 同ディレクトリ
  [ -f "$(dirname "$PARENT")/$base.md" ] && { echo "$(dirname "$PARENT")/$base.md"; return; }
  # 2) 近場探索（深さ控えめ）
  local f; f="$(/usr/bin/find "$root_dir" -maxdepth 5 -type f -name "$base.md" 2>/dev/null | head -n1 || true)"
  [ -n "$f" ] && { echo "$f"; return; }
  echo ""
}
mapfile -t LINKS < <(awk '
  { sub(/\r$/,"",$0) }
  {
    s=$0
    while (match(s, /\[\[[^]]+\]\]/)) {
      body=substr(s,RSTART+2,RLENGTH-4)
      # [[A|B]] 形式は左側
      split(body,a,"|"); print a[1]
      s=substr(s,RSTART+RLENGTH)
    }
  }' "$PARENT" | awk 'NF>0')

child_open=0
OPEN_CHILD_SUMMARY=()
for link in "${LINKS[@]:-}"; do
  base="${link%%|*}"; base="${base%%[[:space:]]*}"
  path="$(resolve "$base")"
  [ -f "$path" ] || continue
  # closed: の有無だけ見る（子の真実は子が持つ）
  closed=""
  while IFS= read -r L; do
    L="${L%$'\r'}"
    [ "$L" = "---" ] && { inFM=$((1-inFM)); continue; }
    [ "${inFM:-0}" -eq 1 ] && [[ "$L" == closed:* ]] && { closed="${L#closed: }"; break; }
  done < "$path"
  if [ -z "$closed" ]; then
    child_open=$((child_open+1))
    # 参考：子の最も近い due を1つ拾う（@done除外）
    due="-"
    while IFS= read -r L; do
      L="${L%$'\r'}"
      [[ "$L" == @* ]] || continue
      [[ "$L" == @done* ]] && continue
      [[ "$L" == *"due:"* ]] || continue
      cand="${L#*due:}"; cand="${cand:0:10}"
      [[ "$cand" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
      if [ "$due" = "-" ] || [[ "$cand" < "$due" ]]; then due="$cand"; fi
    done < "$path"
    OPEN_CHILD_SUMMARY+=("• ${base} (next_due:${due})")
  fi
done

# 判定
if [ "$local_open" -eq 0 ] && [ "$child_open" -eq 0 ]; then
  echo "[OK] closable: no local @tasks and no open children."
  exit 0
fi

echo "[NG] not closable."
echo "  - local open tasks: $local_open"
for t in "${LOCAL_TASKS[@]:-}"; do echo "    • $t"; done
echo "  - open children: $child_open"
for s in "${OPEN_CHILD_SUMMARY[@]:-}"; do echo "    $s"; done
exit 1
