#!/usr/bin/env bash
# md_normalize_format_and_collapse_bold.sh
# バックアップは作らない版 (macOS/BSD 想定)

set -euo pipefail

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

# ------------------------------------------------------------
# Prettier をできるだけ実行する
# 失敗しても続行する
# ------------------------------------------------------------
set +e
if command -v prettier >/dev/null 2>&1; then
  echo "[INFO] Run: prettier --write \"${TARGET}\""
  prettier --write "${TARGET}"
elif command -v npx >/dev/null 2>&1; then
  echo "[INFO] Run: npx --yes prettier --write \"${TARGET}\""
  npx --yes prettier --write "${TARGET}"
elif [ -x /opt/homebrew/bin/prettier ]; then
  echo "[INFO] Run: /opt/homebrew/bin/prettier --write \"${TARGET}\""
  /opt/homebrew/bin/prettier --write "${TARGET}"
else
  echo "[WARN] Prettier not found. Skipped." >&2
fi
set -e

# ------------------------------------------------------------
# 1) 行末の空白を削除（tmp→mvでBSDでもOK）
# ------------------------------------------------------------
TMP="$(mktemp "${TARGET}.XXXXXX")"
sed -E 's/[[:space:]]+$//' "${TARGET}" > "${TMP}"
mv "${TMP}" "${TARGET}"

# ------------------------------------------------------------
# 2) 空白行整理
#    - 「---」直前の空行だけは残す
#    - それ以外の空白行は削る
# ------------------------------------------------------------
TMP="$(mktemp "${TARGET}.XXXXXX")"
awk '
  {
    line = $0
  }

  # 直前が空行で、今の行が --- なら直前の空行を出力
  NR > 1 && prev ~ /^[[:space:]]*$/ && line ~ /^---[[:space:]]*$/ {
    print prev
  }

  # 空行でないなら出力
  line !~ /^[[:space:]]*$/ {
    print line
  }

  {
    prev = line
  }
' "${TARGET}" > "${TMP}"
mv "${TMP}" "${TARGET}"

# ------------------------------------------------------------
# 3) '**' をすべて '*' に潰す
# ------------------------------------------------------------
while grep -q '\*\*' "${TARGET}"; do
  TMP="$(mktemp "${TARGET}.XXXXXX")"
  sed 's/\*\*/\*/g' "${TARGET}" > "${TMP}"
  mv "${TMP}" "${TARGET}"
done

echo "[DONE] Updated: ${TARGET}"
