#!/usr/bin/env bash
# zk_due_meta.sh <file> [source] [weight]
#
# frontmatter に
#   - due_source: self | other
#   - due_weight: hard | soft
# を追加 / 更新する。
#
# ・frontmatter が無い場合は先頭に作成する。
# ・既にキーが存在する場合はその行を書き換える。
#
# 省略時のデフォルト：
#   source → self
#   weight → soft
#
# 例:
#   zk_due_meta.sh note.md
#       => due_source: self, due_weight: soft
#   zk_due_meta.sh note.md other hard
#       => due_source: other, due_weight: hard に設定/更新

set -euo pipefail

FILE="${1:-}"
if [[ -z "${FILE}" ]]; then
  echo "usage: zk_due_meta.sh <file> [source] [weight]" >&2
  exit 2
fi
if [[ ! -f "${FILE}" ]]; then
  echo "Not a regular file: ${FILE}" >&2
  exit 2
fi

RAW_SRC="${2:-self}"
RAW_WGT="${3:-soft}"

# 小文字化（Git Bash でも OK なはず）
RAW_SRC_LC="${RAW_SRC,,}"
RAW_WGT_LC="${RAW_WGT,,}"

# --- source を正規化（self / other） ---
case "${RAW_SRC_LC}" in
  self|s|me|mine|internal)
    SRC="self"
    ;;
  other|o|ext|external)
    SRC="other"
    ;;
  *)
    SRC="self"
    ;;
esac

# --- weight を正規化（hard / soft） ---
case "${RAW_WGT_LC}" in
  hard|h|must|strict)
    WGT="hard"
    ;;
  soft|s|nice|maybe)
    WGT="soft"
    ;;
  *)
    WGT="soft"
    ;;
esac

# 先頭行を見て frontmatter 有無を判定
first_line="$(head -n 1 "${FILE}" | tr -d '\r')"

tmp="$(mktemp)"

if [[ "${first_line}" != '---' ]]; then
  # frontmatter が無い → 先頭に due_source / due_weight だけ入った frontmatter を作成
  {
    printf '%s\n' '---'
    printf 'due_source: %s\n' "${SRC}"
    printf 'due_weight: %s\n' "${WGT}"
    printf '%s\n' '---'
    cat "${FILE}"
  } > "${tmp}"
else
  # frontmatter あり → due_source / due_weight を更新 or 挿入
  awk -v src="${SRC}" -v wgt="${WGT}" '
  BEGIN {
    inFM = 0
    have_src = 0
    have_wgt = 0
  }

  # 1行目の --- で frontmatter 開始
  NR == 1 && $0 ~ /^---[ \t]*$/ {
    inFM = 1
    print
    next
  }

  {
    line = $0

    # frontmatter 内で閉じ --- に到達
    if (inFM && line ~ /^---[ \t]*$/) {
      # まだ due_source / due_weight が無い場合はここで挿入
      if (!have_src) {
        print "due_source: " src
      }
      if (!have_wgt) {
        print "due_weight: " wgt
      }
      inFM = 0
      print line
      next
    }

    if (inFM) {
      # due_source: 行の置き換え
      if (match(line, /^([ \t]*)due_source[ \t]*:/, m)) {
        indent = m[1]
        print indent "due_source: " src
        have_src = 1
        next
      }
      # due_weight: 行の置き換え
      if (match(line, /^([ \t]*)due_weight[ \t]*:/, m)) {
        indent = m[1]
        print indent "due_weight: " wgt
        have_wgt = 1
        next
      }
    }

    print line
  }
  ' "${FILE}" > "${tmp}"
fi

mv "${tmp}" "${FILE}"

echo "[INFO] due_source: ${SRC}, due_weight: ${WGT} set on ${FILE}"
