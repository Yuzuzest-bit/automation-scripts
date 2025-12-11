#!/usr/bin/env bash
# search_children_text.sh <current_file> <query> [ROOT_DIR]
#
# 今開いている Markdown の本文に含まれる wikilink を「子ノート」とみなし、
# その子ノート群の本文から <query> を検索して、
# ヒットした子ノートのリンクをダッシュボードに出力する。
#
# 特徴:
# - 孫ノートは辿らない（“今のノートに書かれているリンク先だけ”）
# - 検索は固定文字列 (grep -F)
# - Foam でリンク先が別フォルダに散っていても find で解決
# - dashboard / dashboards どちらのフォルダ名でも動作
# - grep の終了コードで set -e が暴発しないよう安全化
# - macOS / Linux / Windows(Git Bash) 想定
#
# DEBUG=1 を付けると解決ログを stderr に出します。

set -euo pipefail

CUR="${1:-}"
QUERY="${2:-}"
ROOT="${3:-${PWD}}"
DEBUG="${DEBUG:-0}"

if [[ -z "$CUR" || -z "$QUERY" ]]; then
  echo "usage: $0 <current_file> <query> [ROOT_DIR]" >&2
  exit 2
fi

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

if [[ ! -f "$CUR" ]]; then
  echo "current file not found: $CUR" >&2
  exit 1
fi
if [[ ! -d "$ROOT" ]]; then
  echo "ROOT dir not found: $ROOT" >&2
  exit 1
fi

log() { [[ "$DEBUG" == "1" ]] && echo "[DEBUG] $*" >&2; }

# dashboard / dashboards 自動吸収
if [[ -d "$ROOT/dashboard" ]]; then
  DASH_DIR="$ROOT/dashboard"
else
  DASH_DIR="$ROOT/dashboards"
fi
mkdir -p "$DASH_DIR"
OUT_MD="${DASH_DIR}/children_text_search.md"

tmp_links="$(mktemp)"
trap 'rm -f "$tmp_links"' EXIT

###############################################################################
# 1) wikilink 抽出（grep ではなく awk で堅牢に）
#    - [[path/name|alias]] -> "path/name"
#    - 前後空白をトリム
###############################################################################
awk '
{
  line = $0
  while (match(line, /\[\[[^]]+\]\]/)) {
    s = substr(line, RSTART+2, RLENGTH-4)  # [[...]] の中身
    sub(/\|.*/, "", s)                    # alias 部分除去
    gsub(/^[ \t]+|[ \t]+$/, "", s)        # trim
    if (length(s) > 0) print s
    line = substr(line, RSTART + RLENGTH)
  }
}
' "$CUR" | sort -u > "$tmp_links"

###############################################################################
# 2) link文字列から実ファイルを解決する
#    - パスを含む場合は ROOT 相対の直指定を優先
#    - 無い場合は ROOT 配下を find して名前一致解決
#    - dashboards / dashboard / tags / .foam / .git は探索除外
###############################################################################
resolve_link_to_file() {
  local t="$1"
  local candidate=""
  local has_ext=0

  [[ "$t" == *.* ]] && has_ext=1

  # パス指定がある場合は直指定優先
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

  # find
  if [[ "$has_ext" == "1" ]]; then
    candidate="$(find "$ROOT" \
      -type f \
      -not -path "*/.git/*" \
      -not -path "*/.foam/*" \
      -not -path "*/dashboards/*" \
      -not -path "*/dashboard/*" \
      -not -path "*/tags/*" \
      -name "$name1" \
      2>/dev/null | sort | head -n 1 || true)"
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
      2>/dev/null | sort | head -n 1 || true)"
    [[ -n "$candidate" ]] && { echo "$candidate"; return 0; }
  fi

  return 1
}

###############################################################################
# 3) 子ノート本文を検索
###############################################################################
matches=()
snippets=()

while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  log "link token: $t"

  f="$(resolve_link_to_file "$t" || true)"
  if [[ -z "$f" || ! -f "$f" ]]; then
    log "resolved: NOT FOUND"
    continue
  fi

  rel="${f#"$ROOT"/}"
  log "resolved: $rel"

  # grep 0件は正常扱い
  if grep -nF -- "$QUERY" "$f" >/dev/null 2>&1; then
    matches+=("$t")

    # 最初のヒット行だけ軽く抜粋
    first_line="$(grep -nF -m 1 -- "$QUERY" "$f" 2>/dev/null || true)"
    snippets+=("$first_line")
  fi
done < "$tmp_links"

###############################################################################
# 4) ダッシュボード出力
###############################################################################
{
  echo "---"
  echo "id: $(date +%Y%m%d)-children_text_search"
  echo "parent: -"
  echo "tags: [dashboard]"
  echo "created: $(date '+%Y-%m-%d %H:%M')"
  echo "---"
  echo "# Children text search"
  echo ""
  echo "- Source: \`$CUR\`"
  echo "- Query: \`$QUERY\`"
  echo "- Generated: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  if [[ ! -s "$tmp_links" ]]; then
    echo "## Result"
    echo ""
    echo "No wikilinks found in this note."
  elif [[ "${#matches[@]}" -eq 0 ]]; then
    echo "## Result"
    echo ""
    echo "No matches found in direct children."
  else
    echo "## Matches (${#matches[@]})"
    echo ""
    for i in "${!matches[@]}"; do
      t="${matches[$i]}"
      echo "- [[${t}]]"

      if [[ -n "${snippets[$i]}" ]]; then
        s="${snippets[$i]}"
        ln="${s%%:*}"
        tx="${s#*:}"
        tx="$(echo "$tx" | sed -E 's/^[[:space:]]+//')"
        [[ -n "$ln" && -n "$tx" ]] && echo "  - L${ln}: ${tx}"
      fi
    done
  fi
} > "$OUT_MD"

###############################################################################
# 5) VS Code で開く（無ければパス表示）
###############################################################################
if command -v code >/dev/null 2>&1; then
  code -r "$OUT_MD"
else
  echo "Wrote $OUT_MD"
fi

exit 0
