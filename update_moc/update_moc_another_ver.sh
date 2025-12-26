#!/usr/bin/env bash
# update_in_place.sh

export LC_ALL=C.UTF-8
set -euo pipefail

TARGET_FILE="${1:-}"

# --- 設定 ---
VAULT_ROOT="$(pwd -P)"

# アイコン定義
ICON_CLOSED="✅ "
ICON_OPEN="📖 "
ICON_ERROR="⚠️ "
ICON_FOCUS="🎯"
ICON_AWAIT="⏳"
ICON_BLOCK="🧱"

if [[ -z "$TARGET_FILE" ]]; then
  echo "usage: $0 <target.md>" >&2
  exit 2
fi

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "Error: File not found: $TARGET_FILE" >&2
  exit 1
fi

PARENT_DIR="$(cd "$(dirname "$TARGET_FILE")" && pwd -P)"
TEMP_FILE="$(mktemp)"

# フォルダを跨いでファイルを探す (macOS/Windows両対応)
resolve_file_path() {
  local target_name="$1"
  if [[ -f "$PARENT_DIR/$target_name" ]]; then
    echo "$PARENT_DIR/$target_name"
    return
  fi
  # findで見つける（1つ見つかったら終了）
  find "$VAULT_ROOT" -maxdepth 4 -name "$target_name" -not -path "*/.*" -print -quit 2>/dev/null
}

# 装飾（アイコンとテキスト）を剥がす関数
# 行の「リンクの前」と「リンクの後」を別々に掃除します
clean_prefix() {
  local s="$1"
  for icon in "$ICON_CLOSED" "$ICON_OPEN" "$ICON_ERROR"; do
    s="${s//$icon/}"
  done
  printf '%s' "$s"
}

clean_suffix() {
  local s="$1"
  # リンク直後の優先度アイコンとカッコ付きテキストを削除
  # 🎯(テキスト), 🧱(テキスト), ⏳(テキスト) を正規表現で除去
  echo "$s" | sed -E 's/^[[:space:]]*(🎯|🧱|⏳)\([^)]*\)//'
}

# リンク先の状態を取得
get_link_info() {
  local f_path="$1"
  [[ ! -f "$f_path" ]] && { echo "$ICON_ERROR||"; return; }

  local status="$ICON_OPEN"
  local prio=""
  local text=""

  # Closed判定
  if head -n 30 "$f_path" | tr -d '\r' | grep -qE '^closed:[[:space:]]*.+'; then
    status="$ICON_CLOSED"
  fi

  # 優先度とテキスト (macOS互換)
  local match
  match=$(grep -Ei -m1 '@focus|@blocked|@awaiting' "$f_path" | tr -d '\r' || true)
  if [[ -n "$match" ]]; then
    if [[ "$match" =~ @focus ]]; then prio="$ICON_FOCUS"; text=$(echo "$match" | sed -E 's/.*@focus[[:space:]]*//I'); fi
    if [[ "$match" =~ @blocked ]]; then prio="$ICON_BLOCK"; text=$(echo "$match" | sed -E 's/.*@blocked[[:space:]]*//I'); fi
    if [[ "$match" =~ @awaiting ]]; then prio="$ICON_AWAIT"; text=$(echo "$match" | sed -E 's/.*@awaiting[[:space:]]*//I'); fi
  fi
  printf "%s|%s|%s" "$status" "$prio" "$text"
}

# 処理メイン
while IFS= read -r line || [[ -n "$line" ]]; do
  # [[リンク]] を含む行だけ処理
  if [[ "$line" =~ (.*)\[\[([^]|]+)(\|[^]]+)?\]\](.*) ]]; then
    # BASH_REMATCHから各パーツを取得 (macOS Bash 3.2対応)
    prefix="${BASH_REMATCH[1]}"
    link_target="${BASH_REMATCH[2]}"
    link_alias="${BASH_REMATCH[3]}" # |エイリアス 部分（あれば）
    suffix="${BASH_REMATCH[4]}"

    # ファイル特定
    [[ "$link_target" != *.md ]] && filename="${link_target}.md" || filename="$link_target"
    resolved_path="$(resolve_file_path "$filename")"

    # 情報取得
    info="$(get_link_info "$resolved_path")"
    st_icon=$(echo "$info" | cut -d'|' -f1)
    pr_icon=$(echo "$info" | cut -d'|' -f2)
    extra_txt=$(echo "$info" | cut -d'|' -f3)

    # 掃除
    new_prefix="$(clean_prefix "$prefix")"
    new_suffix="$(clean_suffix "$suffix")"

    # 組み立て: 📖 [[リンク]] 🎯(テキスト) 残りの文字
    prio_part=""
    [[ -n "$pr_icon" ]] && prio_part="${pr_icon}(${extra_txt})"

    echo "${new_prefix}${st_icon}[[${link_target}${link_alias}]]${prio_part}${new_suffix}" >> "$TEMP_FILE"
  else
    echo "$line" >> "$TEMP_FILE"
  fi
done < "$TARGET_FILE"

mv "$TEMP_FILE" "$TARGET_FILE"
echo "Updated: $TARGET_FILE"
