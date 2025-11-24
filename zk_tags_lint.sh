#!/usr/bin/env bash
# zk_tags_lint.sh [ROOT_DIR]
# - ZKルート配下の .md から tags: [...] の中身を全部集める
# - tags/tags_registry.md (Markdown) から正規タグ一覧を抽出（frontmatterは無視）
# - レジストリに存在しないタグを tags/tags_lint_result.txt に出力し、最後に開く

set -euo pipefail

ROOT="${1:-$PWD}"
TAGS_DIR="${ROOT}/tags"
REG_MD="${TAGS_DIR}/tags_registry.md"
OUT_TXT="${TAGS_DIR}/tags_lint_result.txt"

if [[ ! -f "$REG_MD" ]]; then
  echo "Registry markdown not found: $REG_MD" >&2
  exit 1
fi

mkdir -p "$TAGS_DIR"

tmp_files="$(mktemp)"
tmp_tags_used="$(mktemp)"
tmp_tags_used_sorted="$(mktemp)"
tmp_tags_reg="$(mktemp)"
trap 'rm -f "$tmp_files" "$tmp_tags_used" "$tmp_tags_used_sorted" "$tmp_tags_reg"' EXIT

# 1. 対象 .md ファイル一覧（レジストリ自身は対象外）
find "$ROOT" -type f -name '*.md' \
  ! -path "$ROOT/.git/*" \
  ! -path "$ROOT/.vscode/*" \
  ! -path "$ROOT/node_modules/*" \
  ! -path "$REG_MD" \
  > "$tmp_files"

# 2. 各 .md の frontmatter tags: から実際に使っているタグを抽出
awk '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

{
  file = $0
  if (file == "") next

  inFM = 0
  fmDone = 0

  while ((getline line < file) > 0) {
    sub(/\r$/, "", line)

    # frontmatter 境界
    if (line ~ /^---[ \t]*$/) {
      if (inFM == 0 && fmDone == 0) {
        inFM = 1
        continue
      } else if (inFM == 1 && fmDone == 0) {
        inFM = 0
        fmDone = 1
        break
      }
    }

    if (inFM == 1) {
      low = line
      # 小文字化（タグは小文字運用想定）
      for (i = 1; i <= length(low); i++) {
        c = substr(low, i, 1)
        if (c >= "A" && c <= "Z") {
          low = substr(low, 1, i-1) "" tolower(c) "" substr(low, i+1)
        }
      }

      if (index(low, "tags:") > 0) {
        # "tags:" 以降を取り出し、[ ] 除去、"," で分割
        p = index(low, "tags:")
        tmp = substr(low, p+5)
        gsub(/[\[\]]/, "", tmp)
        n = split(tmp, arr, ",")
        for (i = 1; i <= n; i++) {
          t = trim(arr[i])
          if (t != "") print t
        }
      }
    }
  }
  close(file)
}
' "$tmp_files" > "$tmp_tags_used"

# 3. レジストリMarkdownから正規タグ一覧を抽出（frontmatterは無視）
awk '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

BEGIN {
  inFM = 0
  fmDone = 0
}

{
  line = $0
  sub(/\r$/, "", line)
  line = trim(line)

  # frontmatter 境界
  if (line ~ /^---[ \t]*$/) {
    if (inFM == 0 && fmDone == 0) {
      inFM = 1
      next
    } else if (inFM == 1 && fmDone == 0) {
      inFM = 0
      fmDone = 1
      next
    }
  }

  # frontmatter 内は完全に無視
  if (inFM == 1) next

  if (line == "") next

  # 見出し・コードフェンスは無視
  if (line ~ /^#/ || line ~ /^```/) next

  # "- fe-xxx" のようなリスト形式なら "- " を除去
  if (line ~ /^[-*]\s+/) sub(/^[-*]\s+/, "", line)

  # HTMLコメント以降をカット
  sub(/<!--.*$/, "", line)

  line = trim(line)
  if (line == "") next

  print line
}
' "$REG_MD" | sort -u > "$tmp_tags_reg"

# 4. ユニークな使用タグ一覧をソート
sort -u "$tmp_tags_used" > "$tmp_tags_used_sorted"

# 5. 結果を txt に書き出し
{
  echo "# zk_tags_lint result"
  echo "# ROOT: $ROOT"
  echo "# Registry: $REG_MD"
  echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo

  echo "## Used tags (sorted)"
  if [[ -s "$tmp_tags_used_sorted" ]]; then
    cat "$tmp_tags_used_sorted"
  else
    echo "(no tags found)"
  fi
  echo

  echo "## Tags NOT defined in registry"
  # used - registry
  comm -23 "$tmp_tags_used_sorted" "$tmp_tags_reg" || true
  echo
} > "$OUT_TXT"

# 6. 結果ファイルを開く
if command -v code >/dev/null 2>&1; then
  code -r "$OUT_TXT"
elif [[ "$OSTYPE" == darwin* ]]; then
  open "$OUT_TXT" || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$OUT_TXT" || true
fi
