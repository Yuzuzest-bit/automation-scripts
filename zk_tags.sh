#!/usr/bin/env bash
# zk_tags.sh <file> [+tag1] [+tag2] [-tag3] ...
# 現在の Markdown の tags: [...] 行にタグを追加/削除する
#  - +tag 形式: そのタグを追加（なければ追加、あれば何もしない）
#  - -tag 形式: そのタグを削除
#  - プレフィックス無し: 追加とみなす
# frontmatter が無い場合は先頭に作成する
# Windows Git Bash / macOS / Linux 共通

set -euo pipefail

# ---- Windows パス→POSIX 変換（Git Bash のときのみ） ----
to_posix() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    # C:\... や \path\to... だけ変換
    if [[ "$p" =~ ^[A-Za-z]:[\\/]|\\ ]]; then
      cygpath -u "$p"
      return
    fi
  fi
  printf '%s\n' "$p"
}

FILE="${1:-}"
if [[ -z "$FILE" ]]; then
  echo "usage: zk_tags.sh <file> [+tag] [-tag] ..." >&2
  exit 2
fi

FILE="$(to_posix "$FILE")"

if [[ ! -f "$FILE" ]]; then
  echo "Not a regular file: $FILE" >&2
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

# ---- 空ファイルなら frontmatter を新規作成 ----
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
    if [[ $first -eq 0 ]]; then
      printf ', '
    fi
    printf ']\n'
    printf '---\n'
  } >"$tmp"
  mv "$tmp" "$FILE"
  exit 0
fi

tmp="${FILE}.tmp.$$"

awk -v add="$ADD" -v rem="$REM" '
BEGIN {
  n_add = split(add, add_arr, " ");
  n_rem = split(rem, rem_arr, " ");
  N = 0;
}

# 配列に全行ためる
{
  N++;
  lines[N] = $0;
}

function in_list(x, arr, n,    i) {
  for (i = 1; i <= n; i++) if (arr[i] == x) return 1;
  return 0;
}

# 文字列 str をカンマ区切りで tags[] に入れる。戻り値はタグ数
function split_tags(str, tags,    raw, n0, i, n) {
  n0 = split(str, raw, ",");
  n = 0;
  for (i = 1; i <= n0; i++) {
    gsub(/^[[:space:]]+/, "", raw[i]);
    gsub(/[[:space:]]+$/, "", raw[i]);
    if (raw[i] != "") {
      n++;
      tags[n] = raw[i];
    }
  }
  return n;
}

END {
  has_fm = (N >= 1 && lines[1] == "---") ? 1 : 0;

  # 1) 既存の tags 行を探す（ファイル先頭から最初の1個だけ）
  tags_line = 0;
  for (i = 1; i <= N; i++) {
    # 「tags:」と「[」が両方含まれている行を候補にする
    if (index(lines[i], "tags:") > 0 && index(lines[i], "[") > 0) {
      tags_line = i;
      break;
    }
  }

  # 2) 既存タグの解析
  indent = "";
  delete tags;
  tags_n = 0;

  if (tags_line > 0) {
    line = lines[tags_line];

    # インデント取得（行頭の空白～tags: まで）
    if (match(line, /^([[:space:]]*)tags:/, m)) {
      indent = m[1];
    } else {
      indent = "";
    }

    # 「最初の [ 以降」を content として取り出す
    start = index(line, "[");
    if (start > 0) {
      content = substr(line, start + 1);  # "[" の次の文字から行末まで

      # 末尾の空白を削る
      gsub(/[[:space:]]+$/, "", content);

      # 末尾の ] や 空白 を削っていく
      while (length(content) > 0) {
        c = substr(content, length(content), 1);
        if (c == "]" || c == " " || c == "\t") {
          content = substr(content, 1, length(content) - 1);
        } else {
          break;
        }
      }

      # カンマ区切りのタグ群を配列 tags[] に
      tags_n = split_tags(content, tags);
    }
  }

  # 3) 削除 (-tag)
  if (n_rem > 0 && tags_n > 0) {
    delete new_tags;
    new_n = 0;
    for (i = 1; i <= tags_n; i++) {
      if (!in_list(tags[i], rem_arr, n_rem)) {
        new_n++;
        new_tags[new_n] = tags[i];
      }
    }
    delete tags;
    tags_n = new_n;
    for (i = 1; i <= new_n; i++) tags[i] = new_tags[i];
    delete new_tags;
  }

  # 4) 追加 (+tag / プレフィックス無し)
  for (i = 1; i <= n_add; i++) {
    t = add_arr[i];
    if (t == "") continue;
    if (!in_list(t, tags, tags_n)) {
      tags[++tags_n] = t;
    }
  }

  # 5) 最終的な tags 行の文字列を組み立てる（必ず1行・末尾カンマ付き）
  if (tags_n > 0) {
    tags_line_str = indent "tags: [";
    for (i = 1; i <= tags_n; i++) {
      if (i > 1) tags_line_str = tags_line_str ", ";
      tags_line_str = tags_line_str tags[i];
    }
    tags_line_str = tags_line_str ", ]";
  } else {
    # すべて削除されてタグが空になった場合
    tags_line_str = indent "tags: []";
  }

  # 6) tags 行の挿入/置き換え
  if (tags_line > 0) {
    # 既存の tags 行を書き換え
    lines[tags_line] = tags_line_str;
  } else {
    # tags 行が無い
    if (has_fm) {
      # frontmatter がある場合: 1行目の "---" の次の行に挿入
      for (i = N; i >= 2; i--) {
        lines[i + 1] = lines[i];
      }
      lines[2] = tags_line_str;
      N++;
    } else {
      # frontmatter が無い場合: 先頭に frontmatter を新規作成
      for (i = N; i >= 1; i--) {
        lines[i + 3] = lines[i];
      }
      lines[1] = "---";
      lines[2] = tags_line_str;
      lines[3] = "---";
      N += 3;
    }
  }

  # 7) 全行出力
  for (i = 1; i <= N; i++) {
    print lines[i];
  }
}
' "$FILE" >"$tmp"

mv "$tmp" "$FILE"
