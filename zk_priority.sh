#!/usr/bin/env bash
# zk_priority.sh <file> [priority]
# frontmatter に priority: を追加 / 更新する。
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

PRIORITY="${2:-3}"

python3 - "$FILE" "$PRIORITY" << 'PY'
import sys, re, pathlib

path = pathlib.Path(sys.argv[1])
raw = sys.argv[2] if len(sys.argv) > 2 else "3"

# 引数を 1 / 2 / 3 に正規化
s = raw.strip().lower()
if s in ("1", "p1", "high", "h"):
    pri = "1"
elif s in ("2", "p2", "mid", "medium", "m"):
    pri = "2"
elif s in ("3", "p3", "low", "l"):
    pri = "3"
else:
    # 不明な指定は低優先度 (3)
    pri = "3"

try:
    text = path.read_text(encoding="utf-8")
except FileNotFoundError:
    sys.exit(1)

lines = text.splitlines()

# 空ファイルなら frontmatter を新規作成
if not lines:
    fm = ["---", f"priority: {pri}", "---", ""]
    path.write_text("\n".join(fm), encoding="utf-8")
    sys.exit(0)

# frontmatter 検出
if lines[0].strip() != "---":
    # frontmatter が無い → 先頭に作成
    fm = ["---", f"priority: {pri}", "---", ""]
    new_text = "\n".join(fm + lines)
    # 元が改行で終わっていたら維持
    if text.endswith("\n") and not new_text.endswith("\n"):
        new_text += "\n"
    path.write_text(new_text, encoding="utf-8")
    sys.exit(0)

close_idx = None
priority_idx = None
for i in range(1, len(lines)):
    if lines[i].strip() == "---":
        close_idx = i
        break
    if priority_idx is None and lines[i].lstrip().startswith("priority:"):
        priority_idx = i

if close_idx is None:
    # 変な frontmatter 構造 → 何もしない
    sys.exit(0)

if priority_idx is None:
    # priority 行が無い → 閉じ --- の直前に挿入
    indent = ""
    # 他のキーのインデントを参考にしたければここで探してもよいが、
    # とりあえずインデント無しで書く
    new_line = f"{indent}priority: {pri}"
    lines.insert(close_idx, new_line)
else:
    line = lines[priority_idx]
    m = re.match(r'^(?P<indent>\s*)priority\s*:\s*(?P<value>.*)$', line)
    if m:
        indent = m.group("indent")
    else:
        indent = ""
    # priority 行を書き換え
    lines[priority_idx] = f"{indent}priority: {pri}"

new_text = "\n".join(lines)
# 元が改行で終わっていたら維持する
if text.endswith("\n") and not new_text.endswith("\n"):
    new_text += "\n"
path.write_text(new_text, encoding="utf-8")
PY
