#!/usr/bin/env bash
# zk_add_priority_if_missing.sh
#
# frontmatter を持つ Markdown に対して:
# - priority: が無ければ priority: 2 を frontmatter 終端直前に挿入
# - priority: が既にあれば何もしない
#
# 使い方:
#   ./zk_add_priority_if_missing.sh [ROOT]
#   ROOT省略時はカレントディレクトリ
#
# オプション環境変数:
#   DRY_RUN=1   変更せずログだけ出す

set -Eeuo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT="${1:-.}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf "%s\n" "$*" >&2; }

process_file() {
  local file="$1"
  local tmp first_line
  first_line="$(head -n 1 "$file" || true)"

  # frontmatter必須（1行目が --- じゃないならスキップ）
  if [[ "$first_line" != "---" ]]; then
    log "[SKIP] frontmatter無し: $file"
    return 0
  fi

  tmp="$(mktemp)"
  awk '
    BEGIN{
      infm=0
      has_priority=0
      closed_fm=0
    }
    NR==1{
      print $0
      if ($0=="---") infm=1
      next
    }

    # frontmatter終端
    infm==1 && ($0=="---" || $0=="...") {
      if (!has_priority) print "priority: 2"
      print $0
      infm=0
      closed_fm=1
      next
    }

    # frontmatter領域
    infm==1 {
      # priority: の存在確認（インデント許容）
      if ($0 ~ /^[[:space:]]*priority:[[:space:]]*/) has_priority=1
      print $0
      next
    }

    # 本文
    { print $0 }

    END{
      # 壊れたfrontmatter(終端が無い)は閉じない（安全側：変更しない方が良い）
      # ここで has_priority==0 でも何もしない
      if (infm==1 && closed_fm==0) {
        # 何も出さない（呼び出し側で cmp で差分が出ない＝更新なし）
      }
    }
  ' "$file" > "$tmp"

  if [[ "$DRY_RUN" == "1" ]]; then
    if cmp -s "$file" "$tmp"; then
      log "[OK ] no change: $file"
    else
      log "[DRY] would update: $file  (priority missing)"
    fi
    rm -f "$tmp"
    return 0
  fi

  if cmp -s "$file" "$tmp"; then
    log "[OK ] no change: $file"
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
    log "[UPD] inserted missing priority: $file"
  fi
}

export -f process_file log

log "[INFO] scanning: $ROOT"
while IFS= read -r -d '' f; do
  process_file "$f"
done < <(find "$ROOT" -type f -name "*.md" -print0)

log "[DONE]"
