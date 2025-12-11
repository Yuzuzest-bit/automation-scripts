#!/usr/bin/env bash
# search_children_text.sh <current_file> <query> [ROOT_DIR]
#
# 今開いている Markdown の本文に含まれる wikilink を「子ノート」とみなし、
# その子ノート群の本文から <query> を検索して、
# ヒットした子ノートのリンクをダッシュボードに出力する。
#
# - 孫ノートは辿らない
# - 検索は固定文字列 (grep -F)
# - macOS / Linux / Windows(Git Bash) 想定
#
# DEBUG=1 を付けて実行すると解決ログを出す

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

DASH_DIR="${ROOT}/dashboards"
OUT_MD="${DASH_DIR}/children_text_search.md"
mkdir -p "$DASH_DIR"

tmp_links="$(mktemp)"
trap 'rm -f "$tmp_links"' EXIT

log() {
  [[ "$DEBUG" == "1" ]] && echo "[DEBUG] $*" >&2
}

# 1) wikilink 抽出
grep -oE '\[\[[^]]+\]\]' "$CUR" \
  | sed -E 's/^\[\[//; s/\]\]$//' \
  | sed -E 's/\|.*$//' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | awk 'NF' \
  | sort -u > "$tmp_links"

# 2) link文字列から実ファイルを解決する
#    - パスを含む場合は ROOT 相対の直指定を優先
#    - 無い場合は find で名前一致探索
resolve_link_to_file() {
  local t="$1"
  local candidate=""

  # すでに拡張子が入っているか判定
  local has_ext=0
  [[ "$t" == *.* ]] && has_ext=1

  # パス指定っぽい場合（/ を含む）
  if [[ "$t" == */* ]]; then
    if [[ "$has_ext" == "1" ]]; then
      candidate="$ROOT/$t"
      [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
    else
      candidate="$ROOT/$t.md"
      [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
    fi
  fi

  # パス無し → ROOT 配下から名前探索
  # 除外ディレクトリはあなたの運用でノイズになりやすいところを避ける
  local name1="$t"
  local name2="$t.md"

  # find は環境差があるので -o で両方探す
  # まず拡張子ありを優先探索する
  if [[ "$has_ext" == "1" ]]; then
    candidate="$(find "$ROOT" \
      -type f \
      -not -path "*/.git/*" \
      -not -path "*/.foam/*" \
      -not -path "*/dashboards/*" \
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
      -not -path "*/tags/*" \
      \( -name "$name2" -o -name "$name1" \) \
      2>/dev/null | sort | head -n 1 || true)"
    [[ -n "$candidate" ]] && { echo "$candidate"; return 0; }
  fi

  return 1
}

# 3) 検索
matches=()
snippets=()
match_rels=()

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

  if grep -nF -- "$QUERY" "$f" >/dev/null 2>&1; then
    matches+=("$t")          # 表示は link 名ベース
    match_rels+=("$rel")     # デバッグ/将来拡張用
    first_line="$(grep -nF -m 1 -- "$QUERY" "$f" || true)"
    snippets+=("$first_line")
  fi
done < "$tmp_links"

# 4) ダッシュボード出力
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

  if [[ "${#matches[@]}" -eq 0 ]]; then
    echo "## Result"
    echo ""
    echo "No matches found in direct children."
    echo ""
    echo "### Notes"
    echo "- If you want debug logs, run with: \`DEBUG=1\`"
  else
    echo "## Matches (${#matches[@]})"
    echo ""
    for i in "${!matches[@]}"; do
      t="${matches[$i]}"

      # 元の wikilink 文字列をそのまま出す
      # （Foam の解決に任せる）
      echo "- [[${t}]]"

      if [[ -n "${snippets[$i]}" ]]; then
        s="${snippets[$i]}"
        ln="${s%%:*}"
        tx="${s#*:}"
        tx="$(echo "$tx" | sed -E 's/^[[:space:]]+//')"
        echo "  - L${ln}: ${tx}"
      fi
    done
  fi
} > "$OUT_MD"

# 5) VS Code で開く
if command -v code >/dev/null 2>&1; then
  code -r "$OUT_MD"
else
  echo "Wrote $OUT_MD"
fi
