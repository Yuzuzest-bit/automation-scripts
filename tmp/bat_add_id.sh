  #!/usr/bin/env bash
set -Eeuo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 使い方:
#   ./zk_add_id_parent_if_missing.sh [ROOT]
#   ROOT省略時はカレントディレクトリ
#
# オプション環境変数:
#   DRY_RUN=1   変更せずログだけ出す

ROOT="${1:-.}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf "%s\n" "$*" >&2; }

# mtime(更新日) を YYYYMMDD で取る（できるだけ移植性確保）
mtime_yyyymmdd() {
  local f="$1"
  # GNU coreutils の gstat / stat
  if command -v gstat >/dev/null 2>&1; then
    # mac + coreutils
    gstat -c %y "$f" 2>/dev/null | awk '{gsub(/-/, "", $1); print $1; exit}'
    return 0
  fi
  if stat -c %y "$f" >/dev/null 2>&1; then
    stat -c %y "$f" 2>/dev/null | awk '{gsub(/-/, "", $1); print $1; exit}'
    return 0
  fi
  # BSD stat (mac標準)
  if stat -f "%Sm" -t "%Y%m%d" "$f" >/dev/null 2>&1; then
    stat -f "%Sm" -t "%Y%m%d" "$f" 2>/dev/null | awk 'NR==1{print; exit}'
    return 0
  fi
  # 最後の手段：今日
  date +%Y%m%d
}

decide_yyyymmdd() {
  local file="$1"
  local base name_no_ext ymd

  base="$(basename "$file")"
  name_no_ext="${base%.*}"

  # 1) 先頭 YYYYMMDD
  if [[ "$name_no_ext" =~ ^([0-9]{8}) ]]; then
    printf "%s\n" "${BASH_REMATCH[1]}"
    return 0
  fi

  # 2) 先頭 YYYY-MM-DD
  if [[ "$name_no_ext" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
    printf "%s%s%s\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi

  # 3) frontmatter の created: YYYY-MM-DD を拾う（最初の1件）
  ymd="$(
    awk '
      NR==1 && $0!="---" { exit }   # frontmatter前提。無ければ抜ける
      NR==1 && $0=="---" { infm=1; next }
      infm==1 && ($0=="---" || $0=="...") { exit }
      infm==1 {
        # created: 2026-01-14 12:34 など
        if ($0 ~ /^[[:space:]]*created:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}/) {
          s=$0
          sub(/^[[:space:]]*created:[[:space:]]*/, "", s)
          # 先頭10文字が日付
          d=substr(s,1,10)
          gsub(/-/, "", d)
          print d
          exit
        }
      }
    ' "$file" 2>/dev/null || true
  )"
  if [[ -n "$ymd" ]]; then
    printf "%s\n" "$ymd"
    return 0
  fi

  # 4) mtime
  mtime_yyyymmdd "$file"
}

process_file() {
  local file="$1"
  local base name_no_ext ymd idval tmp
  base="$(basename "$file")"
  name_no_ext="${base%.*}"

  # frontmatter必須（1行目が --- じゃないならスキップ）
  local first_line
  first_line="$(head -n 1 "$file" || true)"
  if [[ "$first_line" != "---" ]]; then
    log "[SKIP] frontmatter無し: $file"
    return 0
  fi

  ymd="$(decide_yyyymmdd "$file")"
  idval="${ymd}-${name_no_ext}"

  tmp="$(mktemp)"
  awk -v idval="$idval" '
    BEGIN{
      infm=0
      done=0
      has_id=0
      has_parent=0
    }
    NR==1{
      print $0
      if ($0=="---") infm=1
      next
    }
    # frontmatter領域を走査
    infm==1 && ($0=="---" || $0=="...") {
      # 終端の直前に不足分を挿入
      if (!has_id)    print "id: " idval
      if (!has_parent) print "parent: -"
      print $0
      infm=0
      done=1
      next
    }
    infm==1 {
      if ($0 ~ /^[[:space:]]*id:[[:space:]]*/) has_id=1
      if ($0 ~ /^[[:space:]]*parent:[[:space:]]*/) has_parent=1
      print $0
      next
    }
    { print $0 }
    END{
      # 万一 frontmatter終端が無いケース（壊れたyaml）を検知したいならここで何か出せる
    }
  ' "$file" > "$tmp"

  if [[ "$DRY_RUN" == "1" ]]; then
    # 変更差分をざっくり検知（内容比較）
    if cmp -s "$file" "$tmp"; then
      log "[OK ] no change: $file"
    else
      log "[DRY] would update: $file  (id/parent missing)"
    fi
    rm -f "$tmp"
    return 0
  fi

  if cmp -s "$file" "$tmp"; then
    log "[OK ] no change: $file"
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
    log "[UPD] inserted missing id/parent: $file"
  fi
}

export -f process_file decide_yyyymmdd mtime_yyyymmdd log

# find → while の定番（スペース/記号に強くする）
log "[INFO] scanning: $ROOT"
while IFS= read -r -d '' f; do
  process_file "$f"
done < <(find "$ROOT" -type f -name "*.md" -print0)

log "[DONE]"
