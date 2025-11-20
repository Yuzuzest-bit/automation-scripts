#!/usr/bin/env bash
# zk_tags.sh <file> [+tag1] [+tag2] [-tag3] ...
# 現在の Markdown の frontmatter(tags: [...]) にタグを追加/削除する
#  - +tag 形式: そのタグを追加（なければ追加、あれば何もしない）
#  - -tag 形式: そのタグを削除
#  - プレフィックス無し: 追加とみなす
# frontmatter が無い場合は先頭に作成する
# Windows Git Bash / macOS / Linux 共通

set -euo pipefail

# ---- Windows パス→POSIX 変換（Git Bash のときのみ有効） ----
to_posix() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    # C:\..., \path\to のようなパスだけ変換
    if [[ "$p" =~ ^[A-Za-z]:[\\/]|\\ ]]; then
      cygpath -u "$p"
      return
    fi
  fi
  printf '%s\n' "$p"
}

FILE="${1:-}"
if [[ -z "${FILE}" ]]; then
  echo "usage: zk_tags.sh <file> [+tag] [-tag] ..." >&2
  exit 2
fi

FILE="$(to_posix "$FILE")"

if [[ ! -f "${FILE}" ]]; then
  echo "Not a regular file: ${FILE}" >&2
  exit 2
fi

shift 1
if [[ $# -eq 0 ]]; then
  echo "No tag operations given. Use +tag to add or -tag to remove." >&2
  exit 0
fi

# ---- 追加/削除タグを整理（スペース区切りで持つ） ----
ADD=""
REM=""
for op in "$@"; do
  case "$op" in
    +*)
      tag="${op#+}"
      [[ -n "$tag" ]] && ADD="${ADD:+$ADD }$tag"
      ;;
    -*)
      tag="${op#-}"
      [[ -n "$tag" ]] && REM="${REM:+$REM }$tag"
      ;;
    *)
      [[ -n "$op" ]] && ADD="${ADD:+$ADD }$op"
      ;;
  esac
done

if [[ -z "$ADD" && -z "$REM" ]]; then
  echo "No valid tag operations (empty +tag/-tag)." >&2
  exit 0
fi

# ---- 空ファイルの場合: frontmatter を新規作成 ----
if [[ ! -s "$FILE" ]]; then
  if [[ -z "$ADD" ]]; then
    exit 0
  fi
  tmp="${FILE}.tmp.$$"
  {
    printf '---\n'
    printf 'tags: ['
    first=1
    for t in $ADD; do
      if [[ $first -eq 0 ]]; then printf ', '; fi
      printf '%s' "$t"
      first=0
    done
    # ★ ここで最後にもカンマを付ける ★
    if [[ $first -eq 0 ]]; then
      printf ', '
    fi
    printf ']\n'
    printf '---\n'
  } >"$tmp"
  mv "$tmp" "$FILE"
  exit 0
fi

# ---- 先頭が frontmatter でない場合: 先頭に frontmatter を追加 ----
first_line="$(head -n 1 "$FILE")"
if [[ "$first_line" != "---" ]]; then
  if [[ -z "$ADD" ]]; then
    exit 0
  fi
  tmp="${FILE}.tmp.$$"
  {
    printf '---\n'
    printf 'tags: ['
    first=1
    for t in $ADD; do
      if [[ $first -eq 0 ]]; then printf ', '; fi
      printf '%s' "$t"
      first=0
    done
    # ★ 最後にもカンマを付ける ★
    if [[ $first -eq 0 ]]; then
      printf ', '
    fi
    printf ']\n'
    printf '---\n'
    cat "$FILE"
  } >"$tmp"
  mv "$tmp" "$FILE"
  exit 0
fi

# ---- 閉じ側の --- の行番号を探す ----
close_idx="$(awk 'NR>1 && $0=="---" {print NR; exit}' "$FILE" || true)"
if [[ -z "$close_idx" ]]; then
  exit 0
fi

tmp="${FILE}.tmp.$$"
awk -v add="$ADD" -v rem="$REM" -v close_idx="$close_idx" '
BEGIN {
  n_add = split(add, add_arr, " ");
  n_rem = split(rem, rem_arr, " ");
  tags_handled = 0;
  saw_tags = 0;
}

function in_list(x, arr, n,    i) {
  for (i = 1; i <= n; i++) if (arr[i] == x) return 1;
  return 0;
}

{
  if (NR == 1) {
    print;
    next;
  }

  if (NR < close_idx) {
    if (!tags_handled && match($0, /^([[:space:]]*)tags:[[:space:]]*\\[(.*)\\][[:space:]]*$/, m)) {
      saw_tags = 1;
      indent = m[1];
      content = m[2];

      delete tags;
      tags_n = 0;
      if (length(content) > 0) {
        n0 = split(content, raw, ",");
        for (i = 1; i <= n0; i++) {
          gsub(/^[[:space:]]+/, "", raw[i]);
          gsub(/[[:space:]]+$/, "", raw[i]);
          if (raw[i] != "") {
            tags[++tags_n] = raw[i];
          }
        }
      }

      # 削除 (-tag)
      if (n_rem > 0 && tags_n > 0) {
        delete new_tags;
        new_n = 0;
        for (i = 1; i <= tags_n; i++) {
          if (!in_list(tags[i], rem_arr, n_rem)) {
            new_tags[++new_n] = tags[i];
          }
        }
        delete tags;
        tags_n = new_n;
        for (i = 1; i <= new_n; i++) tags[i] = new_tags[i];
        delete new_tags;
      }

      # 追加 (+tag / プレフィックス無し)
      for (i = 1; i <= n_add; i++) {
        t = add_arr[i];
        if (t == "") continue;
        if (!in_list(t, tags, tags_n)) {
          tags[++tags_n] = t;
        }
      }

      # ★ tags 行を再構築（最後にカンマを残す & 1行のみ）★
      out = indent "tags: [";
      for (i = 1; i <= tags_n; i++) {
        if (i > 1) out = out ", ";
        out = out tags[i];
      }
      if (tags_n > 0) {
        out = out ", ";
      }
      out = out "]";
      print out;

      tags_handled = 1;
      next;
    }

    print;
    next;
  }

  if (NR == close_idx) {
    # frontmatter 内に tags: がなく、追加タグがある場合はここで挿入
    if (!saw_tags && n_add > 0) {
      out = "tags: [";
      added = 0;
      for (i = 1; i <= n_add; i++) {
        t = add_arr[i];
        if (t == "") continue;
        if (added) out = out ", ";
        out = out t;
        added = 1;
      }
      if (added) {
        out = out ", ";
      }
      out = out "]";
      print out;
    }
    print;
    next;
  }

  print;
}
' "$FILE" >"$tmp"

mv "$tmp" "$FILE"
