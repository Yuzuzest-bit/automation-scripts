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

set -euo pipefail

CUR="${1:-}"
QUERY="${2:-}"
ROOT="${3:-${PWD}}"

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

# ROOT 正規化
if [[ ! -d "$ROOT" ]]; then
  echo "ROOT dir not found: $ROOT" >&2
  exit 1
fi

DASH_DIR="${ROOT}/dashboards"
OUT_MD="${DASH_DIR}/children_text_search.md"
mkdir -p "$DASH_DIR"

tmp_links="$(mktemp)"
tmp_targets="$(mktemp)"
trap 'rm -f "$tmp_links" "$tmp_targets"' EXIT

# 1) 現在ノートから wikilink を抽出
#    - [[path/to/file|alias]] 形式を考慮し、| より左だけ使う
#    - 末尾/先頭の空白は軽くトリム
grep -oE '\[\[[^]]+\]\]' "$CUR" \
  | sed -E 's/^\[\[//; s/\]\]$//' \
  | sed -E 's/\|.*$//' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | awk 'NF' \
  | sort -u > "$tmp_links"

# 2) link 名から実ファイルパス候補を作る
#    - 拡張子が無ければ .md を付ける
#    - フォルダ指定があってもそのまま扱う
#    - ROOT 配下で解決する想定（Foam/ZK 的運用）
while IFS= read -r t; do
  # 何も無ければ skip
  [[ -z "$t" ]] && continue

  # すでに拡張子があるか？
  if [[ "$t" == *.* ]]; then
    echo "$ROOT/$t"
  else
    echo "$ROOT/$t.md"
  fi
done < "$tmp_links" | sort -u > "$tmp_targets"

# 3) 検索してヒットした子ノートだけ収集
matches=()
snippets=()

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ -f "$f" ]]; then
    # -n: 行番号
    # -F: 固定文字列
    # -m 1: 最初の1件だけ抜粋用
    if grep -nF -- "$QUERY" "$f" >/dev/null 2>&1; then
      matches+=("$f")
      # 最初のヒット行を軽く抜粋（表示用）
      first_line="$(grep -nF -m 1 -- "$QUERY" "$f" || true)"
      snippets+=("$first_line")
    fi
  fi
done < "$tmp_targets"

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
  else
    echo "## Matches (${#matches[@]})"
    echo ""
    for i in "${!matches[@]}"; do
      f="${matches[$i]}"
      rel="${f#"$ROOT"/}"

      # Markdown の見やすさ優先で wikilink 表示
      # （Foam の解決に任せる）
      base="${rel%.md}"
      echo "- [[${base}]]"

      # 抜粋がある場合はインデント表示
      if [[ -n "${snippets[$i]}" ]]; then
        # "123:line" 形式を "L123: line" に見せる
        s="${snippets[$i]}"
        ln="${s%%:*}"
        tx="${s#*:}"
        # 余白整形
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
