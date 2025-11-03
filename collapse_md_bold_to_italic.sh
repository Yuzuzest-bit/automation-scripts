#!/usr/bin/env bash
# md_normalize_and_collapse_bold.sh (macOS/BSD 対応)
set -u
set -o pipefail

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  echo "No file provided. Run from VS Code with \${file}." >&2
  exit 2
fi
if [[ ! -f "${TARGET}" ]]; then
  echo "Not a regular file: ${TARGET}" >&2
  exit 3
fi

echo "[INFO] TARGET=${TARGET}"

# バックアップ
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="${TARGET}.bak.${TS}"
cp -p "$TARGET" "$BACKUP"
echo "[INFO] Backup: ${BACKUP}"

# Prettier（あれば。失敗しても続行）
set +e
if command -v prettier >/dev/null 2>&1; then
  prettier --write "$TARGET"
elif command -v npx >/dev/null 2>&1; then
  npx --yes prettier --write "$TARGET"
fi
set -e

# 行末空白除去（-i 使わず tmp→mv）
TMP="$(mktemp "${TARGET}.XXXXXX")"
sed -E 's/[[:space:]]+$//' "$TARGET" > "$TMP"
mv "$TMP" "$TARGET"

# 空白行整理（--- の直前の空行は残す）
TMP="$(mktemp "${TARGET}.XXXXXX")"
awk '
  {
    line = $0
    if (NR > 1 && prev ~ /^[[:space:]]*$/ && line ~ /^---[[:space:]]*$/) {
      print prev
    }
    if (line !~ /^[[:space:]]*$/) {
      print line
    }
    prev = line
  }
' "$TARGET" > "$TMP"
mv "$TMP" "$TARGET"

# '**' を '*' に収束（繰り返し）
while grep -q '\*\*' "$TARGET"; do
  TMP="$(mktemp "${TARGET}.XXXXXX")"
  sed 's/\*\*/\*/g' "$TARGET" > "$TMP"
  mv "$TMP" "$TARGET"
done

echo "[DONE] Updated: $TARGET"
echo "[NOTE] Restore if needed: cp -f \"$BACKUP\" \"$TARGET\""
