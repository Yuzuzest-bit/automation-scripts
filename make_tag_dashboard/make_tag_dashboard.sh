#!/usr/bin/env bash
# make_tag_dashboard.sh
#
# frontmatter の due / closed / priority / due_source / due_weight だけを見て、未クローズのノートを一覧化する。
#
# 追加仕様4（Focus/Awaiting マーカー）:
#   - ノート本文（frontmatter含む）に "@focus" がある → 🎯 を付ける
#   - "@awaiting 誰々さん" がある → ⏳（+相手名）を付ける
#   - 両方ある場合は 🎯 を優先（⏳は出さない）
#   - ダッシュボード出力には "@focus" や "@awaiting" の文字列は出さず、絵文字だけ出す
#
# それ以外の仕様は元のまま（BrainDump / gate / due_source / due_weight / 週バケツ等）
#
# ★修正点（今回）:
#   - 週バケツを「日曜始まり（日〜土）」の暦週で判定
#   - 今日が日曜なら、その週は “今週” ではなく “来週” 扱い（週バケツを +1 シフト）

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
  # ---------- 旧形式（互換ロジック） ----------
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
# 第1段階: frontmatter を読んで情報抽出（本文も読み @focus / @awaiting を検出）
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

  # Focus/Awaiting
  isFocus  = 0
  isAwait  = 0
  awaitWho = ""

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

    # ---- Focus/Awaiting 検出（本文/フロントマター問わず）----
    lowline = tolower(line)

    # @focus があれば Focus
    if (isFocus == 0 && index(lowline, "@focus") > 0) {
      isFocus = 1
    }

    # @awaiting があれば Awaiting（相手名は行の残りを拾う）
    # 例: "@awaiting 誰々さん" / "@awaiting  Aさん" / "@awaiting" でもフラグは立てる
    if (isAwait == 0 && match(lowline, /@awaiting[[:space:]]+/, m)) {
      who = substr(line, RSTART + RLENGTH)
      who = trim(who)
      gsub(/\t/, " ", who)     # TSV安全
      isAwait = 1
      awaitWho = who
    } else if (isAwait == 0 && index(lowline, "@awaiting") > 0) {
      # "@awaiting" だけのケース
      isAwait = 1
      awaitWho = ""
    }

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
      }
    }

    # ---- frontmatter 内だけを見る ----
    if (inFM == 1) {
      low = line
      # 小文字化（既存ロジック維持）
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
      # due, pri, bd, gate, focus, await, awaitWho, src, wgt, basename
      printf("%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n",
             dueVal, priVal, isBrainDump, isGate, isFocus, isAwait, awaitWho, srcVal, wgtVal, basename) >> out_due
    } else {
      # pri, bd, gate, focus, await, awaitWho, src, wgt, basename
      printf("%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n",
             priVal, isBrainDump, isGate, isFocus, isAwait, awaitWho, srcVal, wgtVal, basename) >> out_nodue
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
  echo "# ${HEADER_LABEL} – 未クローズタスク (2ヶ月先まで週単位 + BrainDump優先 + gateアイコン + due_source/due_weight + 🎯/⏳)"
  echo
  echo "- 生成時刻: $(date '+%Y-%m-%d %H:%M')"
  echo "- 条件: ${CONDITION_TEXT}"
  echo "- priority: 1(高, 🔴) / 2(中, 🟠) / 3(低, 🟢), 未指定は 3(低, 🟢) 扱い"
  echo "- BrainDump タグ付きノートは 🔥 セクションに表示"
  echo "- gate-* タグ付きノートは 🚧🔴 のようにアイコンで目立つ"
  echo "- due_source / due_weight: other → 🤝, hard → ⚠️（self+soft は表示なし）"
  echo "- 🎯: ノート本文に @focus（文字列は出力しない）"
  echo "- ⏳: ノート本文に @awaiting（文字列は出力しない。相手名があれば併記）"
  echo "- 🎯 と ⏳ が両方ある場合は 🎯 を優先"
  echo

  if [ ! -s "${tmp_due}" ] && [ ! -s "${tmp_nodue}" ]; then
    echo "> 該当なし"
  else
    # ---------- 期限付き ----------
    if [ -s "${tmp_due}" ]; then
      # basename が 10列目になったのでソートキーも更新
      sort -k3,3nr -k1,1 -k2,2n -k10,10r "${tmp_due}" | awk -F '\t' -v today="${TODAY}" '
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

      # ---- 追加：週（日曜始まり）の開始日(JDN)を返す ----
      function week_start(j,    dow) {
        # dow: Sunday=0 .. Saturday=6
        dow = (j + 1) % 7
        return j - dow
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
      # 🎯優先、無ければ⏳
      function mark_icon(focus, await, who,    s) {
        if (focus > 0) return "🎯"
        if (await > 0) {
          s = "⏳"
          if (who != "") s = s " " who
          return s
        }
        return ""
      }

      BEGIN {
        todayJ = ymd_to_jdn(today)

        # 今日の曜日（Sunday=0）
        todayDow = (todayJ + 1) % 7

        # 今日が日曜なら、週バケツを1つ先送り（今週→来週）
        sundayShift = (todayDow == 0 ? 1 : 0)

        # 「今日が属する週」の開始（日曜）
        todayWeekStart = week_start(todayJ)

        oN = todayN = tomN = 0
        for (i = 0; i <= 8; i++) wN[i] = 0
        laterN = 0
        bdN    = 0
      }
      {
        due   = $1
        pri   = $2 + 0
        bd    = $3 + 0
        gate  = $4 + 0
        foc   = $5 + 0
        aw    = $6 + 0
        who   = $7
        src   = $8
        wgt   = $9
        base  = $10

        if (due !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) next

        if (bd == 1) {
          bdN++
          bd_due[bdN]  = due
          bd_base[bdN] = base
          bd_pri[bdN]  = pri
          bd_gate[bdN] = gate
          bd_foc[bdN]  = foc
          bd_aw[bdN]   = aw
          bd_who[bdN]  = who
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
        } else {
          # ---- 主変更：日曜始まりの「暦週」で判定 ----
          ws = week_start(dJ)
          weekDiff = int((ws - todayWeekStart) / 7)   # 0=今週,1=来週,...

          idx = weekDiff + sundayShift                # 今日が日曜なら +1
          if (idx < 0) idx = 0

          # 2ヶ月(60日)より先 or 8週より先は "later" 扱い（元仕様踏襲）
          if (diff > 60 || idx > 8) bucket = "later"
          else bucket = "w" idx
        }

        if (bucket=="over") {
          oN++
          o_due[oN]=due; o_base[oN]=base; o_pri[oN]=pri; o_gate[oN]=gate; o_foc[oN]=foc; o_aw[oN]=aw; o_who[oN]=who; o_src[oN]=src; o_wgt[oN]=wgt
        } else if (bucket=="today") {
          todayN++
          td_due[todayN]=due; td_base[todayN]=base; td_pri[todayN]=pri; td_gate[todayN]=gate; td_foc[todayN]=foc; td_aw[todayN]=aw; td_who[todayN]=who; td_src[todayN]=src; td_wgt[todayN]=wgt
        } else if (bucket=="tomorrow") {
          tomN++
          tm_due[tomN]=due; tm_base[tomN]=base; tm_pri[tomN]=pri; tm_gate[tomN]=gate; tm_foc[tomN]=foc; tm_aw[tomN]=aw; tm_who[tomN]=who; tm_src[tomN]=src; tm_wgt[tomN]=wgt
        } else if (bucket~ /^w[0-8]$/) {
          idx = substr(bucket, 2) + 0
          wN[idx]++
          w_due[idx,wN[idx]]=due; w_base[idx,wN[idx]]=base; w_pri[idx,wN[idx]]=pri; w_gate[idx,wN[idx]]=gate; w_foc[idx,wN[idx]]=foc; w_aw[idx,wN[idx]]=aw; w_who[idx,wN[idx]]=who; w_src[idx,wN[idx]]=src; w_wgt[idx,wN[idx]]=wgt
        } else {
          laterN++
          l_due[laterN]=due; l_base[laterN]=base; l_pri[laterN]=pri; l_gate[laterN]=gate; l_foc[laterN]=foc; l_aw[laterN]=aw; l_who[laterN]=who; l_src[laterN]=src; l_wgt[laterN]=wgt
        }
      }
      END {
        # BrainDump
        if (bdN > 0) {
          print "## 🔥 BrainDump（要整理）"
          print ""
          for (i = 1; i <= bdN; i++) {
            mi = meta_icon(bd_src[i], bd_wgt[i])
            mk = mark_icon(bd_foc[i], bd_aw[i], bd_who[i])
            extra = ""
            if (mk != "") extra = extra " " mk
            if (mi != "") extra = extra " " mi
            print "- " bd_due[i] " " combo_icon(bd_pri[i], bd_gate[i]) extra " [[" bd_base[i] "]]"
          }
          print ""
        }

        # 期限切れ
        if (oN > 0) {
          print "## ⏰ 期限切れ"
          print ""
          for (i = 1; i <= oN; i++) {
            mi = meta_icon(o_src[i], o_wgt[i])
            mk = mark_icon(o_foc[i], o_aw[i], o_who[i])
            extra = ""
            if (mk != "") extra = extra " " mk
            if (mi != "") extra = extra " " mi
            print "- " o_due[i] " " combo_icon(o_pri[i], o_gate[i]) extra " [[" o_base[i] "]]"
          }
          print ""
        }

        # 今日
        if (todayN > 0) {
          print "## 📌 今日"
          print ""
          for (i = 1; i <= todayN; i++) {
            mi = meta_icon(td_src[i], td_wgt[i])
            mk = mark_icon(td_foc[i], td_aw[i], td_who[i])
            extra = ""
            if (mk != "") extra = extra " " mk
            if (mi != "") extra = extra " " mi
            print "- " td_due[i] " " combo_icon(td_pri[i], td_gate[i]) extra " [[" td_base[i] "]]"
          }
          print ""
        }

        # 明日
        if (tomN > 0) {
          print "## 📅 明日"
          print ""
          for (i = 1; i <= tomN; i++) {
            mi = meta_icon(tm_src[i], tm_wgt[i])
            mk = mark_icon(tm_foc[i], tm_aw[i], tm_who[i])
            extra = ""
            if (mk != "") extra = extra " " mk
            if (mi != "") extra = extra " " mi
            print "- " tm_due[i] " " combo_icon(tm_pri[i], tm_gate[i]) extra " [[" tm_base[i] "]]"
          }
          print ""
        }

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
              mk = mark_icon(w_foc[idx, j], w_aw[idx, j], w_who[idx, j])
              extra = ""
              if (mk != "") extra = extra " " mk
              if (mi != "") extra = extra " " mi
              print "- " w_due[idx, j] " " combo_icon(w_pri[idx, j], w_gate[idx, j]) extra " [[" w_base[idx, j] "]]"
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
            mk = mark_icon(l_foc[i], l_aw[i], l_who[i])
            extra = ""
            if (mk != "") extra = extra " " mk
            if (mi != "") extra = extra " " mi
            print "- " l_due[i] " " combo_icon(l_pri[i], l_gate[i]) extra " [[" l_base[i] "]]"
          }
          print ""
        }
      }'
    fi

    # ---------- 期限未設定 ----------
    if [ -s "${tmp_nodue}" ]; then
      echo "## 📝 期限未設定"
      echo
      # basename が 9列目になったのでソートキー更新
      sort -k2,2nr -k1,1n -k9,9 "${tmp_nodue}" | awk -F '\t' '
        function pri_icon(p) {
          if (p <= 1)      return "🔴"
          else if (p == 2) return "🟠"
          else if (p >= 3) return "🟢"
          else             return "⚪"
        }
        function meta_icon(src, wgt,    s) {
          s = ""
          if (src == "other") s = s "🤝"
          else if (src != "" && src != "self") s = s "📎"
          if (wgt == "hard") s = s "⚠️"
          else if (wgt != "" && wgt != "soft") s = s "❓"
          return s
        }
        function mark_icon(focus, await, who,    s) {
          if (focus > 0) return "🎯"
          if (await > 0) {
            s = "⏳"
            if (who != "") s = s " " who
            return s
          }
          return ""
        }
        {
          pri  = $1 + 0
          bd   = $2 + 0
          gate = $3 + 0
          foc  = $4 + 0
          aw   = $5 + 0
          who  = $6
          src  = $7
          wgt  = $8
          base = $9

          if (base == "") next

          icon = pri_icon(pri)
          if (gate > 0) icon = "🚧" icon

          mk = mark_icon(foc, aw, who)
          mi = meta_icon(src, wgt)

          extra = ""
          if (mk != "") extra = extra " " mk
          if (mi != "") extra = extra " " mi

          print "- " icon extra " [[" base "]]"
        }
      '
      echo
    fi
  fi
} > "${OUT}"

echo "[INFO] Wrote ${OUT}"
