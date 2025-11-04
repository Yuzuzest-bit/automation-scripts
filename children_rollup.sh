  #!/usr/bin/env bash
# zk_children_rollup.sh (Windows Git Bash 対応)
# 親MD内の [[...]] を子候補として走査し、
#   - 子が closed: 無し ＝ open とみなす
#   - 子の行頭@…から due:YYYY-MM-DD を拾い最も近い日付を求める
# 親の FM 直後に "Children: open=N next_due=..." を挿入/更新
# ※ 子の状態は子だけ（Single Source of Truth）

set -eu
PARENT_IN="${1:-}"
[ -n "$PARENT_IN" ] || { echo "usage: $0 <parent.md>" >&2; exit 1; }

# Windowsパス -> POSIX
PARENT="$PARENT_IN"
if command -v cygpath >/dev/null 2>&1; then
  [[ "$PARENT" =~ ^[A-Za-z]:\\ ]] && PARENT="$(cygpath -u "$PARENT")"
fi
[ -f "$PARENT" ] || { echo "Not a regular file: $PARENT_IN (resolved: $PARENT)" >&2; exit 1; }

root_dir="$(cd "$(dirname "$PARENT")/.." 2>/dev/null || cd "$(dirname "$PARENT")"; pwd -P)"
# ↑ 雑に1階層上も見る。固定したい場合は適宜 root_dir を設定。

# 親から wikilink を抽出（[[...]]）
# awkで [[ と ]] に挟まれたテキストを素朴に抽出
mapfile -t LINKS < <(awk '
  {
    line=$0
    # CR除去
    sub(/\r$/,"",line)
    while (match(line, /\[\[[^]]+\]\]/)) {
      body=substr(line, RSTART+2, RLENGTH-4)
      print body
      line=substr(line, RSTART+RLENGTH)
    }
  }' "$PARENT" | sed 's/[[:space:]]*$//' | awk 'NF>0')

# 子が無ければ Children 行は消す/空更新
open_count=0
earliest="9999-99-99"

resolve_child_path () {
  local name="$1"
  # 1) 同ディレクトリ直接
  if [ -f "$(dirname "$PARENT")/$name.md" ]; then
    echo "$(dirname "$PARENT")/$name.md"; return
  fi
  # 2) ルート配下でファイル名一致（最初の1件）
  local found
  found="$(/usr/bin/find "$root_dir" -maxdepth 4 -type f -name "$name.md" 2>/dev/null | head -n1 || true)"
  if [ -n "$found" ]; then echo "$found"; return; fi
  # 3) 見つからない
  echo ""
}

get_child_status () {
  local f="$1"
  # 返り値: "OPEN YYYY-MM-DD" or "CLOSED -"
  local inFM=0 closed=""
  while IFS= read -r line; do
    [[ "$line" == $'\r' ]] && line="${line%$'\r'}"
    if [ "$line" = "---" ]; then inFM=$((1-inFM)); continue; fi
    if [ $inFM -eq 1 ] && [[ "$line" == closed:* ]]; then
      closed="${line#closed: }"; closed="${closed%%[[:space:]]*}"
      break
    fi
  done < "$f"

  if [ -n "$closed" ]; then
    echo "CLOSED -"; return
  fi

  # OPENなら本文の @… due 最小日付
  local earliest_due="9999-99-99"
  while IFS= read -r line; do
    [[ "$line" == $'\r' ]] && line="${line%$'\r'}"
    [[ "${line:0:1}" = "@" ]] || continue
    # @doneは除外
    [[ "$line" == @done* ]] && continue
    if [[ "$line" == *"due:"* ]]; then
      local after="${line#*due:}"
      local cand="${after:0:10}"
      [[ "$cand" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
      [[ "$cand" < "$earliest_due" ]] && earliest_due="$cand"
    fi
  done < "$f"

  if [ "$earliest_due" = "9999-99-99" ]; then
    echo "OPEN -"
  else
    echo "OPEN $earliest_due"
  fi
}

for link in "${LINKS[@]:-}"; do
  # wikilinkの表示名が "ID | ラベル" 形式の場合に備えて前半だけ採用
  base="${link%%|*}"
  base="$(echo "$base" | sed 's/[[:space:]]*$//')"
  ch_path="$(resolve_child_path "$base")"
  [ -f "$ch_path" ] || continue

  read -r state due <<<"$(get_child_status "$ch_path")"
  if [ "$state" = "OPEN" ]; then
    open_count=$((open_count+1))
    if [[ "$due" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$due" < "$earliest" ]]; then
      earliest="$due"
    fi
  fi
done

# Children行を作る
children="Children: open=${open_count}"
[ "$earliest" != "9999-99-99" ] && children="${children} next_due=${earliest}"

# 親へ書き戻し（FM直後の既存 Children を置換/挿入、以降の重複 Children は除去）
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
inFM=0 inserted=0
while IFS= read -r line; do
  if [ "$line" = "---" ]; then
    inFM=$((1-inFM))
    echo "$line" >> "$TMP"
    if [ $inFM -eq 0 ] && [ $inserted -eq 0 ]; then
      echo "$children" >> "$TMP"
      inserted=1
    fi
    continue
  fi
  # 既存 Children 行は捨てる（Rollup同様、常に最新で上書き）
  if [ $inFM -eq 0 ] && [[ "$line" == "Children:"* ]]; then
    continue
  fi
  echo "$line" >> "$TMP"
done < "$PARENT"

mv "$TMP" "$PARENT"
echo "[OK] Children rollup updated -> $PARENT"
