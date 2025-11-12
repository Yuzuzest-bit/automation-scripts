#!/usr/bin/env bash
# normalize_closed_ts.sh [ROOT_DIR=. ] [--dry-run] [--backup] [--include '*.md'] [--exclude-dir DIR]...
# - "closed : YYYY-MM-DDTHH:MM:SS(+TZ|Z)" → "closed : YYYY-MM-DDTHH:MM"
# - サブフォルダを含めて再帰的に処理
# - macOS(BSD sed) / GNU sed 両対応
set -euo pipefail

ROOT="."
INCLUDE="*.md"
EXCLUDES=(".git" "node_modules" ".obsidian" "dist" "build")
DRY=0
BACKUP=0

usage() {
  cat <<'USAGE'
Usage:
  normalize_closed_ts.sh [ROOT_DIR] [--dry-run] [--backup]
                         [--include '<glob>'] [--exclude-dir DIR]...

Examples:
  ./normalize_closed_ts.sh . --dry-run
  ./normalize_closed_ts.sh ~/notes --backup --exclude-dir dashboards
  ./normalize_closed_ts.sh . --include '*.markdown'
USAGE
}

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

# sed -i の互換（GNU/BSD）
if sed --version >/dev/null 2>&1; then
  SED_INPLACE=(-i)        # GNU sed
else
  SED_INPLACE=(-i '')     # macOS/BSD sed
fi

# 秒とタイムゾーン(Z / +0900 / +09:00)を落とす
REGEX='s/^([[:space:]]*closed[[:space:]]*:[[:space:]]*)([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}):[0-9]{2}(Z|[+\-][0-9]{2}:?[0-9]{2})?/\1\2/'

# find コマンド（サブフォルダを含めて再帰）
build_find() {
  local -a CMD=("find" "$ROOT" -type d \( )
  local first=1
  for d in "${EXCLUDES[@]}"; do
    if [[ $first -eq 0 ]]; then CMD+=(-o); fi
    CMD+=( -path "*/$d" )
    first=0
  done
  CMD+=( \) -prune -o -type f -name "$INCLUDE" -print0 )
  printf '%q ' "${CMD[@]}"
}

FIND_CMD=()
# shellcheck disable=SC2207
FIND_CMD=($(build_find))

if (( DRY )); then
  # プレビュー表示（変更される行だけを before→after で）
  while IFS= read -r -d '' f; do
    if grep -qE '^[[:space:]]*closed[[:space:]]*:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' "$f"; then
      echo ">>> $f"
      awk '
        {
          if ($0 ~ /^[[:space:]]*closed[[:space:]]*:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/) {
            before=$0
            after=before
            gsub(/^([[:space:]]*closed[[:space:]]*:[[:space:]]*)([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}):[0-9]{2}(Z|[+\-][0-9]{2}:?[0-9]{2})?/,"\\1\\2",after)
            printf("  L%-5d: %s\n          -> %s\n", NR, before, after)
          }
        }' "$f"
    fi
  done < <("${FIND_CMD[@]}")
  exit 0
fi

# 任意：バックアップ作成
if (( BACKUP )); then
  while IFS= read -r -d '' f; do
    cp -p "$f" "$f.bak"
  done < <("${FIND_CMD[@]}")
fi

# 置換の実行
while IFS= read -r -d '' f; do
  sed -E "${SED_INPLACE[@]}" "$REGEX" "$f"
done < <("${FIND_CMD[@]}")

echo "Done."
