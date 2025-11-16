#!/usr/bin/env bash
# zk_tags.sh <file> [+tag1] [+tag2] [-tag3] ...
# 現在の Markdown の frontmatter(tags: [...]) にタグを追加/削除する
#  - +tag 形式: そのタグを追加（なければ追加、あれば何もしない）
#  - -tag 形式: そのタグを削除
# frontmatter が無い場合は先頭に作成する
set -euo pipefail

FILE="${1:-}"
if [[ -z "${FILE}" ]]; then
  echo "usage: zk_tags.sh <file> [+tag] [-tag] ..." >&2
  exit 2
fi
if [[ ! -f "${FILE}" ]]; then
  echo "Not a regular file: ${FILE}" >&2
  exit 2
fi

shift 1
if [[ $# -eq 0 ]]; then
  echo "No tag operations given. Use +tag to add or -tag to remove." >&2
  exit 0
fi

python3 - "$FILE" "$@" << 'PY'
import sys, re, pathlib

path = pathlib.Path(sys.argv[1])
ops = sys.argv[2:]

# split + / - ops
add = []
rem = []
for op in ops:
    if op.startswith("+") and len(op) > 1:
        add.append(op[1:])
    elif op.startswith("-") and len(op) > 1:
        rem.append(op[1:])
    else:
        # プレフィックス無しは「追加」とみなす
        add.append(op)

if not add and not rem:
    sys.exit(0)

text = path.read_text(encoding="utf-8")
lines = text.splitlines()
if not lines:
    # 空ファイルなら frontmatter を新規作成
    fm = ["---", f"tags: [{', '.join(add)}]", "---", ""]
    path.write_text("\n".join(fm), encoding="utf-8")
    sys.exit(0)

# frontmatter 検出
if lines[0].strip() != "---":
    # frontmatter が無い → 先頭に作成
    fm = ["---", f"tags: [{', '.join(add)}]", "---", ""]
    new_text = "\n".join(fm + lines)
    path.write_text(new_text, encoding="utf-8")
    sys.exit(0)

close_idx = None
tags_idx = None
for i in range(1, len(lines)):
    if lines[i].strip() == "---":
        close_idx = i
        break
    if tags_idx is None and lines[i].lstrip().startswith("tags:"):
        tags_idx = i

if close_idx is None:
    # 変な frontmatter 構造 → 何もしない
    sys.exit(0)

if tags_idx is None:
    # tags 行が無い → 閉じ --- の直前に挿入
    indent = ""
    new_line = f"{indent}tags: [{', '.join(add)}]"
    lines.insert(close_idx, new_line)
else:
    line = lines[tags_idx]
    m = re.match(r'^(?P<indent>\s*)tags:\s*\[(?P<content>.*)\]\s*$', line)
    if m:
        indent = m.group("indent")
        content = m.group("content").strip()
        tags = [t.strip() for t in content.split(",") if t.strip()]
    else:
        indent = ""
        tags = []

    # 削除
    if rem:
        tags = [t for t in tags if t not in rem]
    # 追加
    for t in add:
        if t not in tags:
            tags.append(t)

    lines[tags_idx] = f"{indent}tags: [{', '.join(tags)}]"

new_text = "\n".join(lines)
# 元が改行で終わっていたら維持する
if text.endswith("\n") and not new_text.endswith("\n"):
    new_text += "\n"
path.write_text(new_text, encoding="utf-8")
PY
