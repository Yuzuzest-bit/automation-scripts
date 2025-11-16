#!/usr/bin/env bash
# note_rollup.sh
# 目的:
#  - ノート本文(@行)から未完タスクを集計して
#    Rollup: tasks=N focus:x progress:y extract:z awaiting:a hold:b later:c option:d primary=XXX
#    の行を更新/挿入する
# 前提:
#  - 先頭に YAML frontmatter がある（--- で開始/終了）
#  - 本文中の --- は水平線として使われており、frontmatter とは無関係

set -euo pipefail

IN="${1:-}"
if [ -z "$IN" ]; then
  echo "usage: $0 <note.md>" >&2
  exit 1
fi

# Windows パス → POSIX
FILE="$IN"
if command -v cygpath >/dev/null 2>&1; then
  case "$FILE" in [A-Za-z]:\\*) FILE="$(cygpath -u "$FILE")" ;; esac
fi
[ -f "$FILE" ] || { echo "Not a regular file: $IN (resolved: $FILE)" >&2; exit 1; }

AWK_BIN="$(command -v gawk || command -v awk)"
[ -n "$AWK_BIN" ] || { echo "awk not found" >&2; exit 1; }

# --- 1パス目: タスク集計 + Rollup/Frontmatter の有無 ----
meta="$("$AWK_BIN" '
BEGIN{
  inFM=0; fmDone=0; inFence=0;
  tasks=0; focus=0; progress=0; extract=0; awaiting=0; hold=0; later=0; option=0;
  hasRoll=0; hasFM=0;
}
{
  # 行正規化
  sub(/\r$/, "", $0);
  if (NR==1) sub(/^\xEF\xBB\xBF/, "", $0);

  # 既存 Rollup 行チェック
  if ($0 ~ /^Rollup:[[:space:]]*tasks=/) {
    hasRoll=1;
  }

  # frontmatter の境界（最初のブロックだけ特別扱い）
  if ($0 ~ /^---[[:space:]]*$/) {
    if (fmDone==0) {
      if (NR==1 && inFM==0) {
        # 先頭の --- → frontmatter開始
        inFM=1; hasFM=1; next;
      } else if (inFM==1) {
        # 2つ目の --- → frontmatter終了
        inFM=0; fmDone=1; next;
      }
    }
  }

  # frontmatter 中は解析しない
  if (inFM==1) next;

  # コードフェンス
  t=$0; sub(/^[[:space:]]+/, "", t);
  if (t ~ /^```/ || t ~ /^~~~/) {
    inFence = 1-inFence;
    next;
  }
  if (inFence==1) next;

  # 本文の @行（行頭 or 行頭に空白可）
  if ($0 ~ /^[[:space:]]*@/) {
    # @done はクローズ済みとして無視
    if ($0 ~ /^[[:space:]]*@done([[:space:]]|:|$)/) next;

    # 代表ステータスを判定
    if ($0 ~ /^[[:space:]]*@focus([[:space:]]|:|$)/)    { focus++;   tasks++; next; }
    if ($0 ~ /^[[:space:]]*@progress([[:space:]]|:|$)/) { progress++;tasks++; next; }
    if ($0 ~ /^[[:space:]]*@extract([[:space:]]|:|$)/)  { extract++; tasks++; next; }
    if ($0 ~ /^[[:space:]]*@awaiting([[:space:]]|:|$)/) { awaiting++;tasks++; next; }
    if ($0 ~ /^[[:space:]]*@hold([[:space:]]|:|$)/)     { hold++;    tasks++; next; }
    if ($0 ~ /^[[:space:]]*@later([[:space:]]|:|$)/)    { later++;   tasks++; next; }
    if ($0 ~ /^[[:space:]]*@option([[:space:]]|:|$)/)   { option++;  tasks++; next; }

    # その他の @xxx も一応タスクとしてカウントだけ増やす
    tasks++;
  }
}
END{
  primary="none";
  if (tasks>0) {
    if      (focus   >0) primary="focus";
    else if (progress>0) primary="progress";
    else if (awaiting>0) primary="awaiting";
    else if (hold    >0) primary="hold";
    else if (later   >0) primary="later";
    else if (option  >0) primary="option";
    else if (extract >0) primary="extract";
  }
  # 出力: rollup_line \t hasRoll \t hasFM
  printf("Rollup: tasks=%d focus:%d progress:%d extract:%d awaiting:%d hold:%d later:%d option:%d primary=%s\t%d\t%d\n",
         tasks, focus, progress, extract, awaiting, hold, later, option, primary,
         hasRoll, hasFM);
}
' "$FILE")"

ROLL_LINE="${meta%%$'\t'*}"
rest="${meta#*$'\t'}"
HAS_ROLL="${rest%%$'\t'*}"
HAS_FM="${rest##*$'\t'}"

[ "${VERBOSE:-0}" -ge 1 ] && {
  echo "[DBG] ROLL_LINE=${ROLL_LINE}"
  echo "[DBG] HAS_ROLL=${HAS_ROLL} HAS_FM=${HAS_FM}"
}

# --- 2パス目: ファイルに Rollup 行を書き戻す ---
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

"$AWK_BIN" -v roll="$ROLL_LINE" -v hasRoll="$HAS_ROLL" -v hasFM="$HAS_FM" '
BEGIN{
  inFM=0; fmDone=0; inserted=0;
}
{
  sub(/\r$/, "", $0);
  if (NR==1) sub(/^\xEF\xBB\xBF/, "", $0);

  # frontmatter 開始/終了（最初のブロックだけ）
  if ($0 ~ /^---[[:space:]]*$/ && fmDone==0) {
    if (NR==1 && inFM==0) {
      inFM=1;
      print $0;
      next;
    } else if (inFM==1) {
      inFM=0; fmDone=1;
      print $0;
      # frontmatter があって Rollup がまだ無い場合はここで挿入
      if (inserted==0 && hasRoll=="0") {
        print roll;
        inserted=1;
      }
      next;
    }
  }

  # 既存 Rollup 行は差し替える
  if ($0 ~ /^Rollup:[[:space:]]*tasks=/) {
    if (inserted==0) {
      print roll;
      inserted=1;
    }
    # 古い Rollup 行は捨てる
    next;
  }

  print $0;
}
END{
  # frontmatter も Rollup も無いケース → 末尾に Rollup を追記
  if (inserted==0) {
    print roll;
  }
}
' "$FILE" > "$TMP"

mv "$TMP" "$FILE"

[ "${VERBOSE:-0}" -ge 1 ] && echo "[OK] Rollup updated in $FILE: $ROLL_LINE"
