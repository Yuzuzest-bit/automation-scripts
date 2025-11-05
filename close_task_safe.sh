#!/usr/bin/env bash
# close_task_safe.sh <file> [--force]
set -euo pipefail

# --- Bash 4+ を確保 ---
if [ -n "${BASH_VERSINFO-}" ] && [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for CAND in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$CAND" ]; then exec "$CAND" "$0" "$@"; fi
  done
  echo "ERROR: Bash 4+ required. Install Homebrew bash." >&2
  exit 2
fi

# --- 引数 ---
FILE_IN=""; FORCE=0
for a in "$@"; do
  if [ "$a" = "--force" ]; then FORCE=1
  elif [ -z "$FILE_IN" ]; then FILE_IN="$a"
  else echo "usage: $0 <markdown-file> [--force]"; exit 2; fi
done
[ -n "$FILE_IN" ] || { echo "usage: $0 <markdown-file> [--force]"; exit 2; }

# --- Windows パス → POSIX ---
FILE="$FILE_IN"
if command -v cygpath >/dev/null 2>&1; then
  case "$FILE" in [A-Za-z]:\\*) FILE="$(cygpath -u "$FILE")" ;; esac
fi
[ -f "$FILE" ] || { echo "No such file: $FILE_IN (resolved: $FILE)"; exit 2; }

# --- 位置情報と子スクリプト ---
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
if command -v cygpath >/dev/null 2>&1; then
  case "$HERE" in [A-Za-z]:\\*) HERE="$(cygpath -u "$HERE")" ;; esac
fi
ROLL_NOTE="$HERE/note_rollup.sh"
ROLL_CHILD="$HERE/zk_children_rollup.sh"
CHK="$HERE/zk_can_close.sh"
CLOSE="$HERE/close_task.sh"

# --- 実行ユーティリティ ---
run() {
  local script="$1"; shift
  if [ ! -f "$script" ]; then echo "Missing script: $script" >&2; exit 2; fi
  if [ -x "$script" ]; then "$script" "$@"; else "${BASH:-bash}" "$script" "$@"; fi
}

# --- 環境情報 ---
echo "[DBG] HERE=$HERE"
echo "[DBG] FILE=$FILE"
printf "[DBG] exist? ROLL_NOTE=%s  ROLL_CHILD=%s  CHK=%s  CLOSE=%s\n" \
  "$( [ -f "$ROLL_NOTE" ] && echo ok || echo NG )" \
  "$( [ -f "$ROLL_CHILD" ] && echo ok || echo NG )" \
  "$( [ -f "$CHK" ] && echo ok || echo NG )" \
  "$( [ -f "$CLOSE" ] && echo ok || echo NG )"

# --- WORKSPACE_ROOT 推定 ---
if [ -n "${WORKSPACE_ROOT:-}" ] && [ -d "$WORKSPACE_ROOT" ]; then
  ROOT="$WORKSPACE_ROOT"
elif command -v git >/dev/null 2>&1 && git -C "$(dirname "$FILE")" rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel)"
else
  ROOT="$(cd "$(dirname "$FILE")" && pwd -P)"
fi
export WORKSPACE_ROOT="$ROOT"
echo "[DBG] WORKSPACE_ROOT=$WORKSPACE_ROOT"

# --- 1) 最新化（set -e に殺されないよう保護して rc を拾う） ---
echo "[DBG] run ROLL_NOTE"
set +e; run "$ROLL_NOTE" "$FILE"; rc=$?; set -e
echo "[DBG] rc(ROLL_NOTE)=$rc"

echo "[DBG] run ROLL_CHILD"
set +e; run "$ROLL_CHILD" "$FILE"; rc=$?; set -e
echo "[DBG] rc(ROLL_CHILD)=$rc"

# --- 2) 判定（--force 無しならブロック。非ゼロでも落ちないよう保護） ---
if [ "$FORCE" -ne 1 ]; then
  echo "[DBG] run CHK (VERBOSE=1)"
  set +e; VERBOSE=1 run "$CHK" "$FILE"; rc=$?; set -e
  echo "[DBG] rc(CHK)=$rc"
  if [ $rc -ne 0 ]; then
    echo "[ABORT] Open tasks/children remain. Use --force to override."
    exit 1
  fi
else
  echo "[DBG] FORCE=1 (skip CHK)"
fi

# --- 3) クローズ（念のため rc を表示） ---
echo "[DBG] run CLOSE"
set +e; run "$CLOSE" "$FILE"; rc=$?; set -e
echo "[DBG] rc(CLOSE)=$rc"
echo "[DBG] DONE"
