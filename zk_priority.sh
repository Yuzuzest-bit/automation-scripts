#!/usr/bin/env bash
# zk_priority.sh <file> [priority]
# frontmatter に priority: を追加 / 更新する（Python 不要版）。
#  - priority 省略時          → 3 (低)
#  - 1 / high / p1 など       → 1 (高)
#  - 2 / mid / p2 など        → 2 (中)
#  - 3 / low / p3 など        → 3 (低)
#  - その他・不明な指定       → 3 (低) とみなす
#
# frontmatter が無い場合は先頭に作成する。
# 既に priority: が存在する場合はその行を書き換える。

set -euo pipefail

FILE="${1:-}"
if [[ -z "${FILE}" ]]; then
  echo "usage: zk_priority.sh <file> [priority]" >&2
  exit 2
fi
if [[ ! -f "${FILE}" ]]; then
  echo "Not a regular file: ${FILE}" >&2
  exit 2
fi

RAW="${2:-3}"

# --- 引数 priority を 1/2/3 に正規化 ---
# Git Bash の bash なら ${var,,} で小文字化OK
RAW_LC="${RAW,,}"

case "${RAW_LC}" in
  1|p1|high|h)
    PRI="1"
    ;;
  2|p2|mid|medium|m)
    PRI="2"
    ;;
  3|p3|low|l|"")
    PRI="3"
    ;;
  *)
    PRI="3"
    ;;
esac

# 先頭行を見て frontmatter 有無を判定
first_line="$(head -n 1 "${FILE}" | tr -d '\r')"

tmp="$(mktemp)"

if [[ "${first_line}" != '---' ]]; then
  # frontmatter が無い → 先頭に priority だけ入った frontmatter を作成
  {
    printf '%s\n' '---'
    printf 'priority: %s\n' "${PRI}"
    printf '%s\n' '---'
    cat "${FILE}"
  } > "${tmp}"
else
  # frontmatter あり → priority を更新 or 挿入
  awk -v pri="${PRI}" '
  BEGIN {
    inFM = 0
    done = 0
    replaced = 0
    inserted = 0
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
      if (!replaced && !inserted) {
        # priority: がまだ無ければここで挿入
        print "priority: " pri
        inserted = 1
      }
      inFM = 0
      done = 1
      print line
      next
    }

    if (inFM) {
      # priority: 行があれば置き換え
      if (match(line, /^([ \t]*)priority[ \t]*:/, m)) {
        indent = m[1]
        print indent "priority: " pri
        replaced = 1
        next
      }
    }

    print line
  }
  ' "${FILE}" > "${tmp}"
fi

mv "${tmp}" "${FILE}"

echo "[INFO] priority: ${PRI} set on ${FILE}"
