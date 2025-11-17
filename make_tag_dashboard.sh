#!/usr/bin/env bash
# make_tag_dashboard.sh
#
# frontmatter の due / closed だけを見て、未クローズのノートを due 昇順で一覧化する。
#
# - 第1引数 TAG が空   → タグ条件なし（全ノート対象）
# - 第1引数 TAG が非空 → tags: に TAG を含むノートのみ対象
# - 第2引数: 互換用ダミー（現在は未使用。VS Code側の既存設定のために残しているだけ）
# - 第3引数 ROOT: ルートディレクトリ（省略時はカレント）
#
# 対象条件:
#   - 「先頭の frontmatter ブロック」に due: (YYYY-MM-DD...) がある
#   - 「先頭の frontmatter ブロック」に closed: が「無い」
#   - （オプション）frontmatter の tags: に TAG が含まれている
#
# 出力:
#   - いつでも dashboards/default_dashboard.md に上書き
#   - 形式:
#       ## ⏰ 期限切れ
#       - 2025-11-20 [[2025-11-16_URJの休眠口座をどうにかする]]
#     のように、「日付 + wikilink」だけを1行で出力（本文の説明は出さない）

set -eu

# ---------- 引数 ----------
RAW_TAG="${1-}"          # 空文字もそのまま受け取る
NEEDED_STATUS="${2-}"    # 互換用ダミー（現在未使用）
ROOT="${3:-$PWD}"

OUTDIR="${ROOT}/dashboards"
mkdir -p "${OUTDIR}"

# 出力は常に同じファイル
OUT="${OUTDIR}/default_dashboard.md"

# 今日の日付（YYYY-MM-DD）
TODAY="$(date '+%Y-%m-%d')"

tmpfile="$(mktemp)"
filelist="$(mktemp)"
trap 'rm -f "$tmpfile" "$filelist"' EXIT

# TAG（awk に渡すフィルタ用）
if [ -z "${RAW_TAG}" ]; then
  TAG=""
else
  TAG="${RAW_TAG}"
fi

# 対象となる Markdown ファイル一覧をファイルに保存
# （OUTDIR 配下は除外）
find "${ROOT}" -type f -name '*.md' ! -path "${OUTDIR}/*" > "${filelist}"

# ------------------------------
# 第1段階: 各ファイルの「先頭 frontmatter だけ」を読み、
#          「dueあり && closedなし」のノートを tmpfile に
#          "due<TAB>basename" 形式で出力する
# ------------------------------
awk -v tag="${TAG}" '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

# filelist を1行ずつ読むフェーズ（NR==FNR）
NR==FNR {
  file = $0
  gsub(/\r$/, "", file)   # 念のため CR 除去（Windows 由来対策）
  if (file == "") next

  # ===== 1ファイル分の状態初期化 =====
  inFM     = 0
  fmDone   = 0            # 一度 frontmatter を閉じたら 1 になる
  hasTag   = (tag == "" ? 1 : 0)   # タグ指定なしなら最初から通す
  hasDue   = 0
  isClosed = 0
  dueVal   = ""
  basename = ""

  # ベース名取得（最後の / の後ろ、.md を削る）
  n = split(file, parts, "/")
  b = parts[n]
  if (length(b) > 3 && substr(b, length(b)-2) == ".md") {
    b = substr(b, 1, length(b)-3)
  }
  basename = b

  # ===== ここから、そのファイルの中身を1行ずつ読む =====
  while ((getline line < file) > 0) {
    # 行末 CR を除去（CRLF 対策）
    sub(/\r$/, "", line)

    # ---- frontmatter 境界判定 ----
    if (line ~ /^---[ \t]*$/) {
      if (inFM == 0 && fmDone == 0) {
        # 1個目の --- : frontmatter 開始
        inFM = 1
        continue
      } else if (inFM == 1 && fmDone == 0) {
        # 2個目の --- : frontmatter 終了
        inFM = 0
        fmDone = 1
        continue
      } else {
        # fmDone==1 以降の --- は本文中の横罫線として扱う
        # 何もしないで本文として処理を続行
      }
    }

    # ---- frontmatter 内だけを見る ----
    if (inFM == 1) {
      # FM 内の処理: tags / due / closed を拾う
      low = line
      # 小文字化（tolower がない awk 向けに手動）
      for (i = 1; i <= length(low); i++) {
        c = substr(low, i, 1)
        if (c >= "A" && c <= "Z") {
          low = substr(low, 1, i-1) "" tolower(c) "" substr(low, i+1)
        }
      }

      # 空白を削ったバージョン（"closed :" にも対応）
      copy = low
      gsub(/[ \t]/, "", copy)

      # タグ指定ありなら tags: 行からマッチ判定
      if (tag != "" && index(low, "tags:") > 0 && index(low, tag) > 0) {
        hasTag = 1
      }

      # due: 行を取得（前後空白ありでもOK）
      if (index(copy, "due:") > 0) {
        p = index(low, ":")
        if (p > 0) {
          tmp = trim(substr(low, p+1))
          # YYYY-MM-DD 形式で始まるものだけ採用し、
          # 先頭10文字（YYYY-MM-DD）だけを due として使う
          if (tmp ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) {
            dueVal = substr(tmp, 1, 10)
            hasDue = 1
          }
        }
      }

      # closed: が1回でも出てきたらクローズ扱い
      if (index(copy, "closed:") > 0) {
        isClosed = 1
      }
    }

    # inFM==0（本文）は完全に無視する
  }
  close(file)

  # ===== そのファイルの判定 & 出力 =====
  # 条件:
  #   - hasTag      : タグ条件を満たしている（またはタグ無条件）
  #   - hasDue      : frontmatter に due: があり、かつ YYYY-MM-DD 形式
  #   - !isClosed   : frontmatter に closed: が無い
  if (hasTag && hasDue && !isClosed) {
    # due \t basename を tmpfile に書き出す
    printf("%s\t%s\n", dueVal, basename)
  }

  next
}
' "${filelist}" > "${tmpfile}"

# ------------------------------
# 第2段階: tmpfile を due 昇順にソートし、
#          「期限切れ / 今週 / 来週 / 再来週以降」に振り分けて Markdown 出力
# ------------------------------

# 見出し用ラベル
if [ -z "${TAG}" ]; then
  HEADER_LABEL="All Tags"
  CONDITION_TEXT="先頭 frontmatter に due: (YYYY-MM-DD) があり、closed: が無いノート（タグ条件なし）"
else
  HEADER_LABEL="Tag: ${TAG}"
  CONDITION_TEXT="先頭 frontmatter の tags に「${TAG}」を含み、due: (YYYY-MM-DD) があり、closed: が無いノート"
fi

{
  echo "# ${HEADER_LABEL} – 未クローズタスク (due昇順)"
  echo
  echo "- 生成時刻: $(date '+%Y-%m-%d %H:%M')"
  echo "- 条件: ${CONDITION_TEXT}"
  echo

  if [ ! -s "${tmpfile}" ]; then
    echo "> 該当なし"
  else
    sort "${tmpfile}" | awk -F '\t' -v today="${TODAY}" '
    function ymd_to_jdn(s,    Y,M,D,a,y,m) {
      if (s == "" || length(s) < 10) return 0
      Y = substr(s,1,4) + 0
      M = substr(s,6,2) + 0
      D = substr(s,9,2) + 0
      a = int((14 - M)/12)
      y = Y + 4800 - a
      m = M + 12*a - 3
      return D + int((153*m + 2)/5) + 365*y + int(y/4) - int(y/100) + int(y/400) - 32045
    }
    BEGIN {
      todayJ = ymd_to_jdn(today)
      oN=tN=nN=lN=0
    }
    {
      due  = $1
      base = $2

      if (due !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) next

      dJ = ymd_to_jdn(substr(due,1,10))
      diff = dJ - todayJ

      if (dJ == 0) {
        bucket = "later"   # フォーマット異常時はとりあえず「再来週以降」へ
      } else if (diff < 0) {
        bucket = "over"
      } else if (diff <= 6) {
        bucket = "this"
      } else if (diff <= 13) {
        bucket = "next"
      } else {
        bucket = "later"
      }

      if (bucket=="over")      {oN++; o_due[oN]=due;  o_base[oN]=base}
      else if (bucket=="this"){tN++; t_due[tN]=due;  t_base[tN]=base}
      else if (bucket=="next"){nN++; n_due[nN]=due;  n_base[nN]=base}
      else                    {lN++; l_due[lN]=due;  l_base[lN]=base}
    }
    END {
      if (oN>0) {
        print "## ⏰ 期限切れ"
        print ""
        for (i=1;i<=oN;i++) print "- " o_due[i] " [[" o_base[i] "]]"
        print ""
      }
      if (tN>0) {
        print "## 📅 今週"
        print ""
        for (i=1;i<=tN;i++) print "- " t_due[i] " [[" t_base[i] "]]"
        print ""
      }
      if (nN>0) {
        print "## 📆 来週"
        print ""
        for (i=1;i<=nN;i++) print "- " n_due[i] " [[" n_base[i] "]]"
        print ""
      }
      if (lN>0) {
        print "## 📌 再来週以降"
        print ""
        for (i=1;i<=lN;i++) print "- " l_due[i] " [[" l_base[i] "]]"
        print ""
      }
    }'
  fi
} > "${OUT}"

echo "[INFO] Wrote ${OUT}"
