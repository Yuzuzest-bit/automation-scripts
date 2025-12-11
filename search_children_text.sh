#!/usr/bin/env bash
# search_children_text.sh <current_file> <query> [ROOT_DIR]
#
# 目的:
# - 今開いている Markdown の本文に含まれる wikilink を「子ノート」とみなし
# - その子ノート群の本文から <query> を検索
# - ヒットした子ノートのリンクをダッシュボードに出力
#
# 重要:
# - Tasks 側の ${file} が想定とズレる問題を疑うための自己診断版をベースにしているが、
#   出力は「Result セクションのみ」に簡略化する。
#
# - 孫ノートは辿らない
# - 検索は固定文字列 (grep -F)
# - Foam でノートが別フォルダに散っていても find で解決
# - dashboard / dashboards どちらでも対応
#
# macOS / Linux / Windows(Git Bash)

set -u
set -o pipefail

CUR="${1:-}"
QUERY="${2:-}"
ROOT="${3:-${PWD}}"

# Windowsパス→POSIX 変換（Git Bash のとき）
to_posix() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    if [[ "$p" =~ ^[A-Za-z]:[\\/]|\\ ]]; then
      cygpath -u "$p"
      return
    fi
  fi
  printf '%s\n' "$p"
}

CUR="$(to_posix "$CUR")"
ROOT="$(to_posix "$ROOT")"

# dashboard / dashboards 自動吸収
if [[ -d "$ROOT/dashboard" ]]; then
  DASH_DIR="$ROOT/dashboard"
else
  DASH_DIR="$ROOT/dashboards"
fi
mkdir -p "$DASH_DIR"
OUT_MD="${DASH_DIR}/children_text_search.md"

tmp_links="$(mktemp)"
tmp_resolved="$(mktemp)"
tmp_notfound="$(mktemp)"
trap 'rm -f "$tmp_links" "$tmp_resolved" "$tmp_notfound"' EXIT

# 0) 入力検証（落とさず内部用に保持）
cur_exists="no"
root_exists="no"
[[ -n "$CUR" && -f "$CUR" ]] && cur_exists="yes"
[[ -n "$ROOT" && -d "$ROOT" ]] && root_exists="yes"

if [[ "$root_exists" != "yes" ]]; then
  ROOT="${PWD}"
  root_exists="yes"
fi

###############################################################################
# 1) wikilink 抽出（awkで堅牢に）
###############################################################################
if [[ "$cur_exists" == "yes" ]]; then
  awk '
  {
    line = $0
    while (match(line, /\[\[[^]]+\]\]/)) {
      s = substr(line, RSTART+2, RLENGTH-4)
      sub(/\|.*/, "", s)
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (length(s) > 0) print s
      line = substr(line, RSTART + RLENGTH)
    }
  }
  ' "$CUR" | sort -u > "$tmp_links"
else
  : > "$tmp_links"
fi

###############################################################################
# 2) link文字列から実ファイル解決
###############################################################################
resolve_link_to_file() {
  local t="$1"
  local candidate=""
  local has_ext=0

  [[ "$t" == *.* ]] && has_ext=1

  # パス指定があれば直指定優先
  if [[ "$t" == */* ]]; then
    if [[ "$has_ext" == "1" ]]; then
      candidate="$ROOT/$t"
      [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
    else
      candidate="$ROOT/$t.md"
      [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
    fi
  fi

  local name1="$t"
  local name2="$t.md"

  # dashboard / dashboards 等を除外して find
  if [[ "$has_ext" == "1" ]]; then
    candidate="$(find "$ROOT" \
      -type f \
      -not -path "*/.git/*" \
      -not -path "*/.foam/*" \
      -not -path "*/dashboards/*" \
      -not -path "*/dashboard/*" \
      -not -path "*/tags/*" \
      -name "$name1" \
      2>/dev/null | sort | head -n 1)"
    [[ -n "$candidate" ]] && { echo "$candidate"; return 0; }
  else
    candidate="$(find "$ROOT" \
      -type f \
      -not -path "*/.git/*" \
      -not -path "*/.foam/*" \
      -not -path "*/dashboards/*" \
      -not -path "*/dashboard/*" \
      -not -path "*/tags/*" \
      \( -name "$name2" -o -name "$name1" \) \
      2>/dev/null | sort | head -n 1)"
    [[ -n "$candidate" ]] && { echo "$candidate"; return 0; }
  fi

  return 1
}

resolved_count=0
notfound_count=0

: > "$tmp_resolved"
: > "$tmp_notfound"

while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  f="$(resolve_link_to_file "$t" 2>/dev/null || true)"
  if [[ -n "$f" && -f "$f" ]]; then
    echo "$t	$f" >> "$tmp_resolved"
    resolved_count=$((resolved_count + 1))
  else
    echo "$t" >> "$tmp_notfound"
    notfound_count=$((notfound_count + 1))
  fi
done < "$tmp_links"

###############################################################################
# 3) 検索
###############################################################################
matches=()
snippets=()

while IFS=$'\t' read -r t f; do
  [[ -z "$t" || -z "$f" ]] && continue
  if grep -nF -- "$QUERY" "$f" >/dev/null 2>&1; then
    matches+=("$t")
    first_line="$(grep -nF -m 1 -- "$QUERY" "$f" 2>/dev/null || true)"
    snippets+=("$first_line")
  fi
done < "$tmp_resolved"

###############################################################################
# 4) ダッシュボード出力（Result セクションのみ）
###############################################################################
link_count="$(wc -l < "$tmp_links" 2>/dev/null | tr -d ' ')"
found_count="${#matches[@]}"

{
  echo "---"
  echo "id: $(date +%Y%m%d)-children_text_search"
  echo "parent: -"
  echo "tags: [dashboard]"
  echo "created: $(date '+%Y-%m-%d %H:%M')"
  echo "---"
  echo "# Children text search"
  echo ""
  echo "## Result"
  echo ""

  if [[ "$cur_exists" != "yes" ]]; then
    echo "Current file was not passed correctly from task."
  elif [[ "$link_count" == "0" ]]; then
    echo "Wikilink extraction returned 0. (Check that the active file is really your dashboard note.)"
  elif [[ "$found_count" == "0" ]]; then
    echo "No matches found in direct children."
  else
    for i in "${!matches[@]}"; do
      t="${matches[$i]}"
      echo "- [[${t}]]"

      s="${snippets[$i]:-}"
      if [[ -n "$s" ]]; then
        ln="${s%%:*}"
        tx="${s#*:}"
        tx="$(echo "$tx" | sed -E 's/^[[:space:]]+//')"

        # 箇条書き配下の引用として表示（Markdown的に > を使う）
        # インデント2スペース + > でリストにネスト
        if [[ -n "$ln" && -n "$tx" ]]; then
          echo "  > L${ln}: ${tx}"
        fi
      fi
    done
  fi
} > "$OUT_MD"

###############################################################################
# 5) VS Code で開く
###############################################################################
if command -v code >/dev/null 2>&1; then
  code -r "$OUT_MD"
else
  echo "Wrote $OUT_MD"
fi

exit 0
