#!/usr/bin/env bash
# new_excalidraw_here.sh — Create an excalidraw SVG next to the active note
# macOS / Linux / Windows(Git Bash)
set -euo pipefail

IN="${1:-}"
if [[ -z "$IN" ]]; then
  echo "usage: $0 <active-file-or-dir>" >&2
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

IN="$(to_posix "$IN")"

# 基準ディレクトリ決定（ファイルならその親、ディレクトリならそのまま）
if [[ -d "$IN" ]]; then
  BASE_DIR="$IN"
else
  BASE_DIR="$(cd "$(dirname "$IN")" && pwd -P)"
fi

SUBDIR="excalidraw"                     # 好みで変更可
DEST_DIR="$BASE_DIR/$SUBDIR"
mkdir -p "$DEST_DIR"

timestamp="$(date +%Y%m%d%H%M%S)"
filename="$DEST_DIR/$timestamp.excalidraw.svg"
: > "$filename"                         # 空ファイルを作成

# ノートに貼る用のマークダウン（相対パス）
cliptext="![]($SUBDIR/$timestamp.excalidraw.svg)"

# VS Code で開く
if command -v code >/dev/null 2>&1; then
  code -- "$filename"
fi

# クリップボードへ
if [[ "$OSTYPE" == "darwin"* ]]; then
  printf "%s" "$cliptext" | pbcopy
elif command -v clip >/dev/null 2>&1; then
  printf "%s" "$cliptext" | clip
elif command -v xclip >/dev/null 2>&1; then
  printf "%s" "$cliptext" | xclip -selection clipboard
elif command -v xsel >/dev/null 2>&1; then
  printf "%s" "$cliptext" | xsel --clipboard --input
else
  echo "[WARN] Clipboard command not found. Text below:"
  echo "$cliptext"
fi

echo "[OK] Created: $filename"
echo "[OK] Copied:  $cliptext"
