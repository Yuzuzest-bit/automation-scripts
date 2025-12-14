#!/usr/bin/env bash
# make_tag_dashboard.sh
#
# frontmatter の due / closed / priority / due_source / due_weight だけを見て、未クローズのノートを一覧化する。
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
# 追加（除外フォルダ指定）:
#   - dashboards/.dashboardignore に除外フォルダを1行ずつ書く（#コメント可）
#       例:
#         templates
#         time
#   - オプションでも指定できる:
#       make_tag_dashboard.sh --root ROOT --tags "tag1 tag2" --exclude templates --exclude time
#   - 環境変数でも指定できる（空白区切り）:
#       DASH_EXCLUDE_DIRS="templates time" make_tag_dashboard.sh ...
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
# due_source / due_weight:
#   - frontmatter の due_source: / due_weight: を読む（任意）
#     - due_source: self / other（無ければ self 扱い）
#     - due_weight: hard / soft （無ければ soft 扱い）
#   - 表示上は:
#       * self + soft → 何も表示しない（デフォルト）
#       * other      → 🤝
#       * hard       → ⚠️
#       → 組み合わせで「🤝⚠️」のように表示
#
# 追加仕様1（BrainDump）:
#   - frontmatter の tags: に "BrainDump"（大文字小文字無視）が含まれるノートは
#     priority を強制的に 1(高) に引き上げ、
#     ダッシュボードの「🔥 BrainDump（要整理）」セクションに出す。
#
# 追加仕様2（ゲート）:
#   - frontmatter の tags: に "gate-" で始まるタグ（例: gate-release, gate-final）が
#     含まれているノートは「ゲート」とみなす。
#   - ゲートは他のタスクと同じバケツに混ざるが、アイコンが「🚧🔴」のようになって目立つ。
#
# 追加仕様3（2ヶ月先まで週単位バケツ）:
#   - 期限付きタスクは、今日から 60 日先までは 1週間ごとにグルーピングする。
#     diff = due - today とすると:
#       diff < 0        → 期限切れ
#       diff = 0        → 今日
#       diff = 1        → 明日
#       2–6             → 今週（今日・明日以外）
#       7–13            → 来週
#       14–20           → 2週後
#       21–27           → 3週後
#       28–34           → 4週後
#       35–41           → 5週後
#       42–48           → 6週後
#       49–55           → 7週後
#       56–60           → 8週後
#       >60             → 2ヶ月より先
#
# 出力:
#   - いつでも dashboards/default_dashboard.md に上書き
#   - 形式:
#       ## 🔥 BrainDump（要整理）
#       - 2025-11-20 🚧🔴 🤝⚠️ [[ノート名]]
#       ## ⏰ 期限切れ / 📌 今日 / 📅 明日 / 📅 今週 / ...
#       - 2025-11-20 🔴 🤝⚠️ [[ノート名]]
#       ## 📝 期限未設定
#       - 🚧🟠 🤝⚠️ [[ノート名]]

set -euo pipefail

# ---------- 引数パース（旧形式 + 新形式） ----------
TAG_ARGS=()
EXCLUDE_DIRS=()

ROOT="$PWD"

usage() {
  cat <<'USAGE' >&2
usage:
  # 旧形式（互換）
  make_tag_dashboard.sh
  make_tag_dashboard.sh "tag1 tag2"
  make_tag_dashboard.sh tag1 tag2 ... ROOT_DIR
  make_tag_dashboard.sh "tag1 tag2" ignored ROOT_DIR

  # 新形式（推奨: 除外フォルダ指定が可能）
  make_tag_dashboard.sh --root ROOT_DIR [--tags "tag1 tag2"] [--tag tag]... [--exclude dir]... [--exclude-list "dir1,dir2"]
USAGE
}

# --- 新形式（オプション）か判定：先頭が -- なら新形式 ---
if [[ "${1-}" == --* ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)
        [[ $# -ge 2 ]] || { echo "[ERR] --root needs value" >&2; exit 2; }
        ROOT="$2"; shift 2;;
      --tags)
        [[ $# -ge 2 ]] || { echo "[ERR] --tags needs value" >&2; exit 2; }
        for t in $2; do [[ -n "$t" ]] && TAG_ARGS+=("$t"); done
        shift 2;;
      --tag)
        [[ $# -ge 2 ]] || { echo "[ERR] --tag needs value" >&2; exit 2; }
        [[ -n "${2}" ]] && TAG_ARGS+=("$2")
        shift 2;;
      --exclude|--exclude-dir|--exclude-folder)
        [[ $# -ge 2 ]] || { echo "[ERR] --exclude needs value" >&2; exit 2; }
        [[ -n "${2}" ]] && EXCLUDE_DIRS+=("$2")
        shift 2;;
      --exclude-list)
        [[ $# -ge 2 ]] || { echo "[ERR] --exclude-list needs value" >&2; exit 2; }
        IFS=',' read -r -a _tmp <<< "$2"
        for d in "${_tmp[@]}"; do
          [[ -n "$d" ]] && EXCLUDE_DIRS+=("$d")
        done
        shift 2;;
      -h|--help)
        usage; exit 0;;
      --)
        shift; break;;
      *)
        echo "[ERR] unknown option: $1" >&2
        usage
        exit 2;;
    esac
  done

else
  # ---------- 旧形式（あなたの元ロジック） ----------
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

# --- 追加：除外指定の取り込み（ダッシュボード側ファイル / 環境変数） ---
# 1) dashboards/.dashboardignore （1行=1項目, #コメント可）
IGNORE_FILE="${OUTDIR}/.dashboardignore"
if [ -f "${IGNORE_FILE}" ]; then
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$line" ] && EXCLUDE_DIRS+=("$line")
  done < "${IGNORE_FILE}"
fi

# 2) 環境変数（空白区切り）
ENV_EX="${DASH_EXCLUDE_DIRS-}"
if [ -n "${ENV_EX}" ]; then
  for d in ${ENV_EX}; do
    [ -n "$d" ] && EXCLUDE_DIRS+=("$d")
  done
fi

# 今日の日付（YYYY-MM-DD）
TODAY="$(date '+%Y-%m-%d')"

# 一時ファイル
tmp_due="$(mktemp)"
tmp_nodue="$(mktemp)"
filelist="$(mktemp)"
trap 'rm -f "$tmp_due" "$tmp_nodue" "$filelist"' EXIT

# 対象となる Markdown ファイル一覧（OUTDIR 配下などは除外）
# 速度と確実性のため「ディレクトリ prune」で除外する
PRUNE_DIRS=(
  "${OUTDIR}"
  "${ROOT}/.foam"
  "${ROOT}/.git"
  "${ROOT}/.vscode"
  "${ROOT}/node_modules"
)

# ユーザー指定の除外（ROOT相対 or 絶対）
for ex in "${EXCLUDE_DIRS[@]}"; do
  ex="${ex%/}"
  [ -z "$ex" ] && continue

  # "templates/*" のような書き方なら親ディレクトリも除外に含める
  if [[ "$ex" == */\* ]]; then
    ex="${ex%/*}"
    ex="${ex%/}"
    [ -z "$ex" ] && continue
  fi

  if [[ "$ex" == /* ]]; then
    PRUNE_DIRS+=("$ex")
  else
    ex="${ex#./}"
    PRUNE_DIRS+=("${ROOT}/${ex}")
  fi
done

# find 組み立て（-prune で除外）
FIND_CMD=(find "${ROOT}")

FIND_CMD+=("(" -type d "(")
first=1
for p in "${PRUNE_DIRS[@]}"; do
  if [ $first -eq 1 ]; then
    FIND_CMD+=(-path "$p")
    first=0
  else
    FIND_CMD+=(-o -path "$p")
  fi
done
FIND_CMD+=(")" -prune ")")

FIND_CMD+=(-o "(" -type f -name '*.md' -print ")")

"${FIND_CMD[@]}" > "${filelist}"

# ------------------------------
# 第1段階: frontmatter を読んで情報抽出
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
  isGate   = 0
  dueVal   = ""
  basename = ""
  priVal   = 3          # priority デフォルト (低)

  # due_source / due_weight のデフォルト
  srcVal   = "self"
  wgtVal   = "soft"

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

      # BrainDump タグ検出
      if (index(low, "tags:") > 0 && index(low, "braindump") > 0) {
        isBrainDump = 1
      }

      # gate- タグ検出
      if (index(low, "tags:") > 0 && index(low, "gate-") > 0) {
        isGate = 1
      }

      # due:
      if (index(copy, "due:") > 0) {
        p = index(low, "due:")
        if (p > 0) {
          tmp = trim(substr(low, p+4))
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

      # due_source:
      if (index(low, "due_source:") > 0) {
        p = index(low, "due_source:")
        if (p > 0) {
          tmp = trim(substr(low, p + length("due_source:")))
          if (tmp ~ /^other/) {
            srcVal = "other"
          } else if (tmp ~ /^self/) {
            srcVal = "self"
          } else {
            srcVal = "self"
          }
        }
      }

      # due_weight:
      if (index(low, "due_weight:") > 0) {
        p = index(low, "due_weight:")
        if (p > 0) {
          tmp = trim(substr(low, p + length("due_weight:")))
          if (tmp ~ /^hard/) {
            wgtVal = "hard"
          } else if (tmp ~ /^soft/) {
            wgtVal = "soft"
          } else {
            wgtVal = "soft"
          }
        }
      }
    }
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

  if (hasTag && !isClosed) {
    if (hasDue) {
      # due あり: due, pri, bd, gate, src, wgt, basename
      printf("%s\t%d\t%d\t%d\t%s\t%s\t%s\n", dueVal, priVal, isBrainDump, isGate, srcVal, wgtVal, basename) >> out_due
    } else {
      # due なし: pri, bd, gate, src, wgt, basename
      printf("%d\t%d\t%d\t%s\t%s\t%s\n", priVal, isBrainDump, isGate, srcVal, wgtVal, basename) >> out_nodue
    }
  }

  next
}
' "${filelist}"

# ------------------------------
# 第2段階: tmp_due / tmp_nodue を使って Markdown 出力
# ------------------------------

if [ -z "${TAG}" ]; then
  HEADER_LABEL="All Tags"
  CONDITION_TEXT="先頭 frontmatter に closed: が無いノート（due: が無ければ期限未設定扱い）"
else
  HEADER_LABEL="Tags: ${TAG}"
  CONDITION_TEXT="先頭 frontmatter の tags に「${TAG}」のすべてを含み、closed: が無いノート（due: が無ければ期限未設定扱い）"
fi

{
  echo "# ${HEADER_LABEL} – 未クローズタスク (2ヶ月先まで週単位 + BrainDump優先 + gateアイコン + due_source/due_weight)"
  echo
  echo "- 生成時刻: $(date '+%Y-%m-%d %H:%M')"
  echo "- 条件: ${CONDITION_TEXT}"
  echo "- priority: 1(高, 🔴) / 2(中, 🟠) / 3(低, 🟢), 未指定は 3(低, 🟢) 扱い"
  echo "- BrainDump タグ付きノートは 🔥 セクションに表示"
  echo "- gate-* タグ付きノートは 🚧🔴 のようにアイコンで目立つ"
  echo "- due_source / due_weight: other → 🤝, hard → ⚠️（self+soft は表示なし）"
  echo

  if [ ! -s "${tmp_due}" ] && [ ! -s "${tmp_nodue}" ]; then
    echo "> 該当なし"
  else
    # ---------- 期限付き ----------
    if [ -s "${tmp_due}" ]; then
      sort -k3,3nr -k1,1 -k2,2n -k7,7r "${tmp_due}" | awk -F '\t' -v today="${TODAY}" '
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
      function combo_icon(p, gateFlag,    base) {
        base = pri_icon(p)
        if (gateFlag > 0) return "🚧" base
        else              return base
      }
      # due_source / due_weight を絵文字に変換
      function meta_icon(src, wgt,    s) {
        s = ""
        if (src == "other") {
          s = s "🤝"
        } else if (src != "" && src != "self") {
          s = s "📎"
        }
        if (wgt == "hard") {
          s = s "⚠️"
        } else if (wgt != "" && wgt != "soft") {
          s = s "❓"
        }
        return s
      }
      BEGIN {
        todayJ = ymd_to_jdn(today)

        oN = todayN = tomN = 0
        for (i = 0; i <= 8; i++) {
          wN[i] = 0
        }
        laterN = 0
        bdN    = 0
      }
      {
        due   = $1
        pri   = $2 + 0
        bd    = $3 + 0
        gate  = $4 + 0
        src   = $5
        wgt   = $6
        base  = $7

        if (due !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) next

        if (bd == 1) {
          bdN++
          bd_due[bdN]  = due
          bd_base[bdN] = base
          bd_pri[bdN]  = pri
          bd_gate[bdN] = gate
          bd_src[bdN]  = src
          bd_wgt[bdN]  = wgt
          next
        }

        dJ = ymd_to_jdn(substr(due,1,10))
        diff = dJ - todayJ

        if (dJ == 0) {
          bucket = "later"
        } else if (diff < 0) {
          bucket = "over"
        } else if (diff == 0) {
          bucket = "today"
        } else if (diff == 1) {
          bucket = "tomorrow"
        } else if (diff <= 6) {
          bucket = "w0"
        } else if (diff <= 13) {
          bucket = "w1"
        } else if (diff <= 20) {
          bucket = "w2"
        } else if (diff <= 27) {
          bucket = "w3"
        } else if (diff <= 34) {
          bucket = "w4"
        } else if (diff <= 41) {
          bucket = "w5"
        } else if (diff <= 48) {
          bucket = "w6"
        } else if (diff <= 55) {
          bucket = "w7"
        } else if (diff <= 60) {
          bucket = "w8"
        } else {
          bucket = "later"
        }

        if (bucket=="over") {
          oN++
          o_due[oN]   = due
          o_base[oN]  = base
          o_pri[oN]   = pri
          o_gate[oN]  = gate
          o_src[oN]   = src
          o_wgt[oN]   = wgt
        } else if (bucket=="today") {
          todayN++
          td_due[todayN]   = due
          td_base[todayN]  = base
          td_pri[todayN]   = pri
          td_gate[todayN]  = gate
          td_src[todayN]   = src
          td_wgt[todayN]   = wgt
        } else if (bucket=="tomorrow") {
          tomN++
          tm_due[tomN]   = due
          tm_base[tomN]  = base
          tm_pri[tomN]   = pri
          tm_gate[tomN]  = gate
          tm_src[tomN]   = src
          tm_wgt[tomN]   = wgt
        } else if (bucket~ /^w[0-8]$/) {
          idx = substr(bucket, 2) + 0
          wN[idx]++
          w_due[idx, wN[idx]]   = due
          w_base[idx, wN[idx]]  = base
          w_pri[idx, wN[idx]]   = pri
          w_gate[idx, wN[idx]]  = gate
          w_src[idx, wN[idx]]   = src
          w_wgt[idx, wN[idx]]   = wgt
        } else {
          laterN++
          l_due[laterN]   = due
          l_base[laterN]  = base
          l_pri[laterN]   = pri
          l_gate[laterN]  = gate
          l_src[laterN]   = src
          l_wgt[laterN]   = wgt
        }
      }
      END {
        # BrainDump
        if (bdN > 0) {
          print "## 🔥 BrainDump（要整理）"
          print ""
          for (i = 1; i <= bdN; i++) {
            mi = meta_icon(bd_src[i], bd_wgt[i])
            if (mi != "") {
              print "- " bd_due[i] " " combo_icon(bd_pri[i], bd_gate[i]) " " mi " [[" bd_base[i] "]]"
            } else {
              print "- " bd_due[i] " " combo_icon(bd_pri[i], bd_gate[i]) " [[" bd_base[i] "]]"
            }
          }
          print ""
        }

        # 期限切れ
        if (oN > 0) {
          print "## ⏰ 期限切れ"
          print ""
          for (i = 1; i <= oN; i++) {
            mi = meta_icon(o_src[i], o_wgt[i])
            if (mi != "") {
              print "- " o_due[i] " " combo_icon(o_pri[i], o_gate[i]) " " mi " [[" o_base[i] "]]"
            } else {
              print "- " o_due[i] " " combo_icon(o_pri[i], o_gate[i]) " [[" o_base[i] "]]"
            }
          }
          print ""
        }

        # 今日
        if (todayN > 0) {
          print "## 📌 今日"
          print ""
          for (i = 1; i <= todayN; i++) {
            mi = meta_icon(td_src[i], td_wgt[i])
            if (mi != "") {
              print "- " td_due[i] " " combo_icon(td_pri[i], td_gate[i]) " " mi " [[" td_base[i] "]]"
            } else {
              print "- " td_due[i] " " combo_icon(td_pri[i], td_gate[i]) " [[" td_base[i] "]]"
            }
          }
          print ""
        }

        # 明日
        if (tomN > 0) {
          print "## 📅 明日"
          print ""
          for (i = 1; i <= tomN; i++) {
            mi = meta_icon(tm_src[i], tm_wgt[i])
            if (mi != "") {
              print "- " tm_due[i] " " combo_icon(tm_pri[i], tm_gate[i]) " " mi " [[" tm_base[i] "]]"
            } else {
              print "- " tm_due[i] " " combo_icon(tm_pri[i], tm_gate[i]) " [[" tm_base[i] "]]"
            }
          }
          print ""
        }

        # 週ラベル
        labels[0] = "📅 今週（今日・明日以外）"
        labels[1] = "📆 来週"
        labels[2] = "📆 2週後"
        labels[3] = "📆 3週後"
        labels[4] = "📆 4週後"
        labels[5] = "📆 5週後"
        labels[6] = "📆 6週後"
        labels[7] = "📆 7週後"
        labels[8] = "📆 8週後"

        for (idx = 0; idx <= 8; idx++) {
          if (wN[idx] > 0) {
            print "## " labels[idx]
            print ""
            for (j = 1; j <= wN[idx]; j++) {
              mi = meta_icon(w_src[idx, j], w_wgt[idx, j])
              if (mi != "") {
                print "- " w_due[idx, j] " " combo_icon(w_pri[idx, j], w_gate[idx, j]) " " mi " [[" w_base[idx, j] "]]"
              } else {
                print "- " w_due[idx, j] " " combo_icon(w_pri[idx, j], w_gate[idx, j]) " [[" w_base[idx, j] "]]"
              }
            }
            print ""
          }
        }

        # 2ヶ月より先
        if (laterN > 0) {
          print "## 📌 2ヶ月より先"
          print ""
          for (i = 1; i <= laterN; i++) {
            mi = meta_icon(l_src[i], l_wgt[i])
            if (mi != "") {
              print "- " l_due[i] " " combo_icon(l_pri[i], l_gate[i]) " " mi " [[" l_base[i] "]]"
            } else {
              print "- " l_due[i] " " combo_icon(l_pri[i], l_gate[i]) " [[" l_base[i] "]]"
            }
          }
          print ""
        }
      }'
    fi

    # ---------- 期限未設定 ----------
    if [ -s "${tmp_nodue}" ]; then
      echo "## 📝 期限未設定"
      echo
      sort -k2,2nr -k1,1n -k6,6 "${tmp_nodue}" | awk -F '\t' '
        function pri_icon(p) {
          if (p <= 1)      return "🔴"
          else if (p == 2) return "🟠"
          else if (p >= 3) return "🟢"
          else             return "⚪"
        }
        function meta_icon(src, wgt,    s) {
          s = ""
          if (src == "other") {
            s = s "🤝"
          } else if (src != "" && src != "self") {
            s = s "📎"
          }
          if (wgt == "hard") {
            s = s "⚠️"
          } else if (wgt != "" && wgt != "soft") {
            s = s "❓"
          }
          return s
        }
        {
          pri  = $1 + 0
          bd   = $2 + 0   # いまのところ未使用
          gate = $3 + 0
          src  = $4
          wgt  = $5
          base = $6

          if (base == "") next

          icon = pri_icon(pri)
          if (gate > 0) {
            icon = "🚧" icon
          }

          mi = meta_icon(src, wgt)
          if (mi != "") {
            print "- " icon " " mi " [[" base "]]"
          } else {
            print "- " icon " [[" base "]]"
          }
        }
      '
      echo
    fi
  fi
} > "${OUT}"

echo "[INFO] Wrote ${OUT}"
