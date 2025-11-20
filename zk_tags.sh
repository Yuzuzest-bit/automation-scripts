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
    # 追加タグがないなら何もしない（削除だけ指定されても意味がない）
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
    # 追加タグが無ければ frontmatter を作る意味が無いので何もしない
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
    printf ']\n'
    printf '---\n'
    cat "$FILE"
  } >"$tmp"
  mv "$tmp" "$FILE"
  exit 0
fi

# ---- 閉じ側の --- の行番号を探す（変な frontmatter のときは何もしない）----
close_idx="$(awk 'NR>1 && $0=="---" {print NR; exit}' "$FILE" || true)"
if [[ -z "$close_idx" ]]; then
  # 2つ目の --- が無い → おかしな frontmatter なので何もしない
  exit 0
fi

tmp="${FILE}.tmp.$$"
awk -v add="$ADD" -v rem="$REM" -v close_idx="$close_idx" '
BEGIN {
  n_add = split(add, add_arr, " ");
  n_rem = split(rem, rem_arr, " ");
  tags_handled = 0;   # 既存 tags 行を処理したか
  saw_tags = 0;       # frontmatter 内に tags: があったか
}

function in_list(x, arr, n,    i) {
  for (i = 1; i <= n; i++) if (arr[i] == x) return 1;
  return 0;
}

{
  # 1行目（---）はそのまま出力
  if (NR == 1) {
    print;
    next;
  }

  # frontmatter 内（1 < NR < close_idx）
  if (NR < close_idx) {
    # まだ tags 行を処理しておらず、かつ tags: [...] 行なら書き換える
    if (!tags_handled && match($0, /^([[:space:]]*)tags:[[:space:]]*\\[(.*)\\][[:space:]]*$/, m)) {
      saw_tags = 1;
      indent = m[1];
      content = m[2];

      # 既存タグをパース
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

      # tags 行を再構築
      out = indent "tags: [";
      for (i = 1; i <= tags_n; i++) {
        if (i > 1) out = out ", ";
        out = out tags[i];
      }
      out = out "]";
      print out;
      tags_handled = 1;
      next;
    }

    # それ以外の行はそのまま
    print;
    next;
  }

  # 閉じ側 --- の行
  if (NR == close_idx) {
    # frontmatter 内に tags: が無く、追加タグがあるときは、ここで tags 行を挿入
    if (!saw_tags && n_add > 0) {
      out = "tags: [";
      first = 1;
      for (i = 1; i <= n_add; i++) {
        t = add_arr[i];
        if (t == "") continue;
        if (!first) out = out ", ";
        out = out t;
        first = 0;
      }
      out = out "]";
      print out;
    }
    print;
    next;
  }

  # frontmatter 以降はそのまま
  print;
}
' "$FILE" >"$tmp"

mv "$tmp" "$FILE"
