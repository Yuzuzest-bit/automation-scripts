#!/usr/bin/env bash
# normalize_closed_ts_v2.sh [ROOT_DIR=. ] [--dry-run] [--backup] [--include '*.md'] [--exclude-dir DIR]...
# "closed : YYYY-MM-DDTHH:MM:SS(+TZ|Z)" → "closed : YYYY-MM-DDTHH:MM"
set -euo pipefail

ROOT="."
INCLUDE="*.md"
EXCLUDES=(".git" "node_modules" ".obsidian" "dist" "build")
DRY=0
BACKUP=0

usage() {
  cat <<'USAGE'
Usage:
  normalize_closed_ts_v2.sh [ROOT_DIR] [--dry-run] [--backup]
                            [--include '<glob>'] [--exclude-dir DIR]...
Examples:
  ./normalize_closed_ts_v2.sh . --dry-run
  ./normalize_closed_ts_v2.sh ~/notes --backup --exclude-dir dashboards
  ./normalize_closed_ts_v2.sh . --include '*.markdown'
USAGE
}

# 引数処理
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1;;
    --backup)  BACKUP=1;;
    --include) INCLUDE="${2:?}"; shift;;
    --exclude-dir) EXCLUDES+=("${2:?}"); shift;;
    -h|--help) usage; exit 0;;
    *) ROOT="$1";;
  esac
  shift
done

# sed -i 互換
if sed --version >/dev/null 2>&1; then
  SED_INPLACE=(-i)        # GNU sed
else
  SED_INPLACE=(-i '')     # macOS/BSD sed
fi

# 秒とタイムゾーン(Z / +0900 / +09:00)を落とす
REGEX='s/^([[:space:]]*closed[[:space:]]*:[[:space:]]*)([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}):[0-9]{2}(Z|[+\-][0-9]{2}:?[0-9]{2})?/\1\2/'

# 括弧を使わずに -prune を連鎖させる（サブフォルダ再帰）
FIND=(find "$ROOT")
for d in "${EXCLUDES[@]}"; do
  FIND+=(-path "*/$d" -prune -o)
done
FIND+=(-type f -name "$INCLUDE" -print0)

# プレビュー（変更される行だけ before→after）
if (( DRY )); then
  while IFS= read -r -d '' f; do
    awk '
      {
        if ($0 ~ /^[[:space:]]*closed[[:space:]]*:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/) {
          before=$0; after=$0
          gsub(/^([[:space:]]*closed[[:space:]]*:[[:space:]]*)([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}):[0-9]{2}(Z|[+\-][0-9]{2}:?[0-9]{2})?/,"\\1\\2",after)
          printf(">>> %s\n  L%-5d: %s\n          -> %s\n", FILENAME, NR, before, after)
        }
      }' "$f"
  done < <("${FIND[@]}")
  exit 0
fi

# 任意バックアップ
if (( BACKUP )); then
  while IFS= read -r -d '' f; do
    cp -p "$f" "$f.bak"
  done < <("${FIND[@]}")
fi

# 実置換
while IFS= read -r -d '' f; do
  sed -E "${SED_INPLACE[@]}" "$REGEX" "$f"
done < <("${FIND[@]}")

echo "Done."
