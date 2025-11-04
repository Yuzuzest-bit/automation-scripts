#!/usr/bin/env bash
# note_rollup.sh (Windows Git Bash対応)
# 小タスク（@〜）を集計してRollup行を更新/挿入
# 変更点: @done* 行は next_due 算出から除外

set -eu
FILE="${1:-}"
if [ ! -f "$FILE" ]; then
  echo "usage: $0 <markdown-file>" >&2
  exit 1
fi

BASENAME="$(basename "$FILE" .md)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# 集計カウンタ
declare -A counts=(
  [focus]=0 [progress]=0 [awaiting]=0 [hold]=0 [later]=0 [option]=0
)

earliest_due="9999-99-99"
first_line=""
inFM=0

# -------- 第一走査：統計取得 --------
while IFS= read -r line; do
  [[ "$line" == "---" ]] && { inFM=$((1-inFM)); continue; }

  # Front Matter 外の最初の行
  if [ $inFM -eq 0 ] && [ -z "$first_line" ]; then
    first_line="$line"
  fi

  # 行頭@をチェック
  if [ $inFM -eq 0 ] && [[ "$line" == @* ]]; then
    tag="${line%% *}"      # 例: @progress / @done:2025-...
    tag="${tag#@}"         # progress / done:2025-...
    tag="${tag,,}"         # 小文字化

    # 既知タグのみカウント（@done はここで無視される）
    if [[ -n "${counts[$tag]+x}" ]]; then
      counts[$tag]=$((counts[$tag]+1))
    fi

    # --- ここが今回のポイント ---
    # @done* の行は next_due の候補から除外
    if [[ "$line" == @done* ]]; then
      continue
    fi
    # ----------------------------

    # due日付を抽出（@done 以外のみ）
    if [[ "$line" == *"due:"* ]]; then
      after="${line#*due:}"
      cand="${after:0:10}"
      # YYYY-MM-DD 形式っぽいときだけ比較
      if [[ "$cand" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        if [[ "$cand" < "$earliest_due" ]]; then
          earliest_due="$cand"
        fi
      fi
    fi
  fi
done < "$FILE"

# 状態の優先順位
order=(focus progress awaiting hold later option)
primary="none"
for t in "${order[@]}"; do
  if [ "${counts[$t]}" -gt 0 ]; then
    primary="$t"
    break
  fi
done

total=0
for v in "${counts[@]}"; do total=$((total+v)); done

rollup="Rollup: tasks=${total} [focus:${counts[focus]} progress:${counts[progress]} awaiting:${counts[awaiting]} hold:${counts[hold]} later:${counts[later]} option:${counts[option]}] primary=${primary}"
if [ "$earliest_due" != "9999-99-99" ]; then
  rollup="${rollup} next_due=${earliest_due}"
fi

# -------- 第二走査：書き戻し --------
inFM=0; inserted=0; first_done=0
while IFS= read -r line; do
  if [ "$line" == "---" ]; then
    inFM=$((1-inFM))
    echo "$line" >> "$TMP"
    if [ $inFM -eq 0 ] && [ $inserted -eq 0 ]; then
      echo "$rollup" >> "$TMP"
      inserted=1
    fi
    continue
  fi

  # 既存Rollup行を置き換え（常に最新で上書き）
  if [ $inFM -eq 0 ] && [[ "$line" == "Rollup:"* ]]; then
    continue
  fi

  # 複数タスクある場合、先頭が @〜 なら中立化
  if [ $inFM -eq 0 ] && [ $first_done -eq 0 ]; then
    first_done=1
    if [ $total -gt 1 ] && [[ "$first_line" == @* ]]; then
      rest="${first_line#*@}"
      rest="${rest#* }"
      [ -z "$rest" ] && rest="$BASENAME"
      echo "Scope: ${rest}" >> "$TMP"
      continue
    fi
  fi

  echo "$line" >> "$TMP"
done < "$FILE"

mv "$TMP" "$FILE"
echo "[OK] Rollup updated (next_due excludes @done) -> $FILE"
