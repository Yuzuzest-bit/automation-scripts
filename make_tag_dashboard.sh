#!/usr/bin/env bash
# make_tag_dashboard.sh
#
# frontmatter の due / closed / priority だけを見て、未クローズのノートを一覧化する。
#
# タグ条件:
#   - 引数 0個                → タグ条件なし, ROOT = $PWD
#   - 引数 1個 (T1)           → タグ T1 のノートのみ対象, ROOT = $PWD
#   - 引数 2個以上:
#       T1 T2 ... TN ROOT_DIR → ROOT_DIR 配下を対象,
#                                すべてのタグ(T1..TN)を含むノートだけ対象 (AND)
#
#   - 旧形式も互換サポート:
#       make_tag_dashboard.sh "nwsp ctx-life" "ignored" ROOT_DIR
#       → "nwsp ctx-life" を空白分割したタグ AND, ROOT_DIR をルートにして動作
#
# 対象条件:
#   - 先頭 frontmatter に closed: が「無い」こと
#   - かつ、以下のどちらか
#       A) 先頭 frontmatter に due: (YYYY-MM-DD...) がある       → 期限付きタスク
#       B) frontmatter 自体が無い、または due: が無い           → 期限未設定タスク
#
# priority:
#   - frontmatter の priority: を読む（任意）
#     - 1 / high / p1    → 高 (🔴)
#     - 2 / mid / p2     → 中 (🟠)
#     - 3 / low / p3     → 低 (🟢)
#     - 未指定 or 不明   → 低 (🟢, P3) 扱い
#
# 追加仕様:
#   - frontmatter の tags: に "BrainDump"（大文字小文字無視）が含まれるノートは
#     priority を強制的に 1(高) に引き上げ、
#     ダッシュボードの最上部に「🔥 BrainDump（要整理）」として表示する。
#
# 出力:
#   - いつでも dashboards/default_dashboard.md に上書き
#   - 形式:
#       ## 🔥 BrainDump（要整理）
#       - 2025-11-20 🔴 [[ノート名]]
#       ## ⏰ 期限切れ / 📌 今日 / 📅 明日 / 📅 今週 / 📆 来週 / 📌 再来週以降
#       - 2025-11-20 🔴 [[ノート名]]
#       ## 📝 期限未設定
#       - 🟢 [[ノート名]]

set -eu

# ---------- 引数パース ----------
TAG_ARGS=()
if [ "$#" -eq 0 ]; then
  ROOT="$PWD"
elif [ "$#" -eq 1 ]; then
  ROOT="$PWD"
  TAG_ARGS+=("$1")
else
  # 2個以上: 最後の引数を ROOT, それ以外をタグとみなす
  eval "ROOT=\${$#}"
  i=1
  last=$(( $# - 1 ))
  while [ "$i" -le "$last" ]; do
    eval "arg=\${$i}"

    if [ "$i" -eq 1 ] && [ "$#" -ge 3 ] && [ "${2-}" = "ignored" ]; then
      # 旧形式互換:
      #   make_tag_dashboard.sh "nwsp ctx-life" "ignored" ROOT
      for t in $arg; do
        [ -n "$t" ] && TAG_ARGS+=("$t")
      done
      break
    fi

    [ -n "$arg" ] && TAG_ARGS+=("$arg")
    i=$(( i + 1 ))
  done
fi

# awk に渡すタグ文字列（空白区切り）
if [ "${#TAG_ARGS[@]}" -eq 0 ]; then
  TAG=""
else
  TAG="${TAG_ARGS[*]}"
fi

OUTDIR="${ROOT}/dashboards"
mkdir -p "${OUTDIR}"
OUT="${OUTDIR}/default_dashboard.md"

# 今日の日付（YYYY-MM-DD）
TODAY="$(date '+%Y-%m-%d')"

# 一時ファイル
tmp_due="$(mktemp)"
tmp_nodue="$(mktemp)"
filelist="$(mktemp)"
trap 'rm -f "$tmp_due" "$tmp_nodue" "$filelist"' EXIT

# 対象となる Markdown ファイル一覧（OUTDIR 配下などは除外）
find "${ROOT}" -type f -name '*.md' \
  ! -path "${OUTDIR}/*" \
  ! -path "${ROOT}/.foam/*" \
  ! -path "${ROOT}/.git/*" \
  ! -path "${ROOT}/.vscode/*" \
  ! -path "${ROOT}/node_modules/*" \
  > "${filelist}"

# ------------------------------
# 第1段階: frontmatter を読んで情報抽出
#   - BrainDump タグ検出
#   - due / closed / priority 読み取り
#   - 条件を満たすノートを tmp_due / tmp_nodue へ
# ------------------------------
awk -v tag="${TAG}" -v out_due="${tmp_due}" -v out_nodue="${tmp_nodue}" '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

# tag 文字列を空白区切りで分解して wantedTags[] に格納
BEGIN {
  nTag = 0
  if (tag != "") {
    nTag = split(tag, wantedTags, /[[:space:]]+/)
  }
}

NR==FNR {
  file = $0
  gsub(/\r$/, "", file)
  if (file == "") next

  # ===== 1ファイル分の状態初期化 =====
  inFM     = 0
  fmDone   = 0
  nonHead  = 0
  hasTag   = (tag == "" ? 1 : 0)
  hasDue   = 0
  isClosed = 0
  isBrainDump = 0
  dueVal   = ""
  basename = ""
  priVal   = 3              # priority デフォルト (低)

  # ベース名取得（最後の / の後ろ、.md を削る）
  n = split(file, parts, "/")
  b = parts[n]
  if (length(b) > 3 && substr(b, length(b)-2) == ".md") {
    b = substr(b, 1, length(b)-3)
  }
  basename = b

  # ===== ファイルを1行ずつ読む =====
  while ((getline line < file) > 0) {
    sub(/\r$/, "", line)

    # frontmatter 開始前の「最初の非空行」が --- 以外なら nonHead=1
    tmpLine = line
    gsub(/[ \t]/, "", tmpLine)
    if (fmDone == 0 && inFM == 0) {
      if (tmpLine != "" && line !~ /^---[ \t]*$/) {
        nonHead = 1
      }
    }

    # ---- frontmatter 境界判定 ----
    if (line ~ /^---[ \t]*$/) {
      if (inFM == 0 && fmDone == 0) {
        inFM = 1
        continue
      } else if (inFM == 1 && fmDone == 0) {
        inFM = 0
        fmDone = 1
        continue
      } else {
        # frontmatter 終了後の --- は無視（本文の区切り）
      }
    }

    # ---- frontmatter 内だけを見る ----
    if (inFM == 1) {
      low = line
      # 小文字化
      for (i = 1; i <= length(low); i++) {
        c = substr(low, i, 1)
        if (c >= "A" && c <= "Z") {
          low = substr(low, 1, i-1) "" tolower(c) "" substr(low, i+1)
        }
      }

      copy = low
      gsub(/[ \t]/, "", copy)

      # タグ AND 条件
      if (tag != "" && index(low, "tags:") > 0) {
        allOK = 1
        for (ti = 1; ti <= nTag; ti++) {
          t = wantedTags[ti]
          if (t == "") continue
          if (index(low, t) == 0) {
            allOK = 0
            break
          }
        }
        if (allOK) {
          hasTag = 1
        }
      }

      # BrainDump タグ検出（tags: 行に "braindump" を含んでいればフラグON）
      if (index(low, "tags:") > 0 && index(low, "braindump") > 0) {
        isBrainDump = 1
      }

      # due:
      if (index(copy, "due:") > 0) {
        p = index(low, ":")
        if (p > 0) {
          tmp = trim(substr(low, p+1))
          if (tmp ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) {
            dueVal = substr(tmp, 1, 10)
            hasDue = 1
          }
        }
      }

      # closed:
      if (index(copy, "closed:") > 0) {
        isClosed = 1
      }

      # priority:
      if (index(low, "priority:") > 0) {
        p = index(low, "priority:")
        if (p > 0) {
          tmp = trim(substr(low, p + 9))
          sub(/^#/, "", tmp)
          tmp = trim(tmp)

          if (tmp ~ /^1/ || tmp ~ /^high/ || tmp ~ /^p1/) {
            priVal = 1
          } else if (tmp ~ /^2/ || tmp ~ /^mid/ || tmp ~ /^medium/ || tmp ~ /^p2/) {
            priVal = 2
          } else if (tmp ~ /^3/ || tmp ~ /^low/ || tmp ~ /^p3/) {
            priVal = 3
          }
        }
      }
    }
    # 本文は何も見ない
  }
  close(file)

  # frontmatter がない or 先頭ではないファイルは対象外
  if (!fmDone || nonHead) {
    next
  }

  # BrainDump の場合は priority を強制的に高(1)へ引き上げ
  if (isBrainDump && priVal > 1) {
    priVal = 1
  }

  # hasTag: タグ条件を満たす（or タグ指定なし）
  # !isClosed: frontmatter に closed: が無い
  if (hasTag && !isClosed) {
    if (hasDue) {
      # due あり → tmp_due
      #   due<TAB>priority<TAB>isBrainDump<TAB>basename
      printf("%s\t%d\t%d\t%s\n", dueVal, priVal, isBrainDump, basename) >> out_due
    } else {
      # due なし → tmp_nodue
      #   priority<TAB>isBrainDump<TAB>basename
      printf("%d\t%d\t%s\n", priVal, isBrainDump, basename) >> out_nodue
    }
  }

  next
}
' "${filelist}"

# ------------------------------
# 第2段階: tmp_due / tmp_nodue を使って Markdown 出力
# ------------------------------

# 見出し用ラベル
if [ -z "${TAG}" ]; then
  HEADER_LABEL="All Tags"
  CONDITION_TEXT="先頭 frontmatter に closed: が無いノート（due: が無ければ期限未設定扱い）"
else
  HEADER_LABEL="Tags: ${TAG}"
  CONDITION_TEXT="先頭 frontmatter の tags に「${TAG}」のすべてを含み、closed: が無いノート（due: が無ければ期限未設定扱い）"
fi

{
  echo "# ${HEADER_LABEL} – 未クローズタスク (due昇順 + BrainDump優先)"
  echo
  echo "- 生成時刻: $(date '+%Y-%m-%d %H:%M')"
  echo "- 条件: ${CONDITION_TEXT}"
  echo "- priority: 1(高, 🔴) / 2(中, 🟠) / 3(低, 🟢), 未指定は 3(低, 🟢) 扱い"
  echo "- BrainDump タグ付きノートは 🔥 セクションに最優先で表示"
  echo

  if [ ! -s "${tmp_due}" ] && [ ! -s "${tmp_nodue}" ]; then
    echo "> 該当なし"
  else
    # ---------- 期限付き ----------
    if [ -s "${tmp_due}" ]; then
      # isBrainDump(3列目) 降順 → BrainDump が先頭、
      # その中で due 昇順, priority 昇順, basename 降順
      sort -k3,3nr -k1,1 -k2,2n -k4,4r "${tmp_due}" | awk -F '\t' -v today="${TODAY}" '
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
      function pri_icon(p) {
        if (p <= 1)      return "🔴"
        else if (p == 2) return "🟠"
        else if (p >= 3) return "🟢"
        else             return "⚪"
      }
      BEGIN {
        todayJ = ymd_to_jdn(today)
        oN = todayN = tomN = tN = nN = lN = 0
        bdN = 0
      }
      {
        due  = $1
        pri  = $2 + 0
        bd   = $3 + 0
        base = $4

        if (due !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) next

        # BrainDump は専用セクションへ
        if (bd == 1) {
          bdN++; bd_due[bdN]=due; bd_base[bdN]=base; bd_pri[bdN]=pri
          next
        }

        dJ = ymd_to_jdn(substr(due,1,10))
        diff = dJ - todayJ

        if (dJ == 0) {
          # フォーマット異常時はとりあえず「再来週以降」
          bucket = "later"
        } else if (diff < 0) {
          bucket = "over"
        } else if (diff == 0) {
          bucket = "today"
        } else if (diff == 1) {
          bucket = "tomorrow"
        } else if (diff <= 6) {
          bucket = "this"
        } else if (diff <= 13) {
          bucket = "next"
        } else {
          bucket = "later"
        }

        if (bucket=="over") {
          oN++; o_due[oN]=due;  o_base[oN]=base; o_pri[oN]=pri
        } else if (bucket=="today") {
          todayN++; td_due[todayN]=due; td_base[todayN]=base; td_pri[todayN]=pri
        } else if (bucket=="tomorrow") {
          tomN++; tm_due[tomN]=due; tm_base[tomN]=base; tm_pri[tomN]=pri
        } else if (bucket=="this") {
          tN++; t_due[tN]=due;  t_base[tN]=base; t_pri[tN]=pri
        } else if (bucket=="next") {
          nN++; n_due[nN]=due;  n_base[nN]=base; n_pri[nN]=pri
        } else {
          lN++; l_due[lN]=due;  l_base[lN]=base; l_pri[lN]=pri
        }
      }
      END {
        if (bdN>0) {
          print "## 🔥 BrainDump（要整理）"
          print ""
          for (i=1;i<=bdN;i++) print "- " bd_due[i] " " pri_icon(bd_pri[i]) " [[" bd_base[i] "]]"
          print ""
        }
        if (oN>0) {
          print "## ⏰ 期限切れ"
          print ""
          for (i=1;i<=oN;i++) print "- " o_due[i] " " pri_icon(o_pri[i]) " [[" o_base[i] "]]"
          print ""
        }
        if (todayN>0) {
          print "## 📌 今日"
          print ""
          for (i=1;i<=todayN;i++) print "- " td_due[i] " " pri_icon(td_pri[i]) " [[" td_base[i] "]]"
          print ""
        }
        if (tomN>0) {
          print "## 📅 明日"
          print ""
          for (i=1;i<=tomN;i++) print "- " tm_due[i] " " pri_icon(tm_pri[i]) " [[" tm_base[i] "]]"
          print ""
        }
        if (tN>0) {
          print "## 📅 今週（今日・明日以外）"
          print ""
          for (i=1;i<=tN;i++) print "- " t_due[i] " " pri_icon(t_pri[i]) " [[" t_base[i] "]]"
          print ""
        }
        if (nN>0) {
          print "## 📆 来週"
          print ""
          for (i=1;i<=nN;i++) print "- " n_due[i] " " pri_icon(n_pri[i]) " [[" n_base[i] "]]"
          print ""
        }
        if (lN>0) {
          print "## 📌 再来週以降"
          print ""
          for (i=1;i<=lN;i++) print "- " l_due[i] " " pri_icon(l_pri[i]) " [[" l_base[i] "]]"
          print ""
        }
      }'
    fi

    # ---------- 期限未設定 ----------
    if [ -s "${tmp_nodue}" ]; then
      echo "## 📝 期限未設定"
      echo
      # priority<TAB>isBrainDump<TAB>basename
      # BrainDump を 2列目降順で優先、その中で priority 昇順
      sort -k2,2nr -k1,1n -k3,3 "${tmp_nodue}" | while IFS=$'\t' read -r pri bd base; do
        [ -z "${base}" ] && continue
        case "${pri}" in
          1) icon="🔴" ;;
          2) icon="🟠" ;;
          3|"") icon="🟢" ;;  # 未指定も P3 扱い
          *) icon="⚪" ;;
        esac
        echo "- ${icon} [[${base}]]"
      done
      echo
    fi
  fi
} > "${OUT}"

echo "[INFO] Wrote ${OUT}"
