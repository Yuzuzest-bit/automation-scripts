#!/usr/bin/env bash
# zk_set_decision_status.sh
#
# Decisionノートの frontmatter を更新:
# - decision: proposed|accepted|rejected|superseded|dropped
# - proposed なら closed: を削除
# - それ以外なら closed: を付与/更新（デフォルト: now）
# - オプション: rejected_reason, superseded_by, review
#
# usage:
#   zk_set_decision_status.sh <decision.md> <status> [--reason "text"] [--superseded-by "NoteBase"] [--review "NoteBase"] [--closed "YYYY-MM-DDTHH:MM:SS"]
#
set -euo pipefail
export LANG=en_US.UTF-8

FILE="${1:-}"
STATUS="${2:-}"
shift $(( $#>0 ? 2 : 0 )) || true

if [[ -z "${FILE}" || -z "${STATUS}" ]]; then
  echo "usage: $0 <decision.md> <status> [--reason \"text\"] [--superseded-by \"NoteBase\"] [--review \"NoteBase\"] [--closed \"YYYY-MM-DDTHH:MM:SS\"]" >&2
  exit 2
fi

if [[ ! -f "$FILE" ]]; then
  echo "[ERR] not found: $FILE" >&2
  exit 2
fi

STATUS_LC="$(printf '%s' "$STATUS" | tr 'A-Z' 'a-z')"
case "$STATUS_LC" in
  proposed|accepted|rejected|superseded|dropped) ;;
  *)
    echo "[ERR] invalid status: $STATUS (use proposed|accepted|rejected|superseded|dropped)" >&2
    exit 2
    ;;
esac

REASON=""
SUPERSEDED_BY=""
REVIEW=""
CLOSED_AT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason)         REASON="${2:-}"; shift 2 ;;
    --superseded-by)  SUPERSEDED_BY="${2:-}"; shift 2 ;;
    --review)         REVIEW="${2:-}"; shift 2 ;;
    --closed)         CLOSED_AT="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: $0 <decision.md> <status> [--reason \"text\"] [--superseded-by \"NoteBase\"] [--review \"NoteBase\"] [--closed \"YYYY-MM-DDTHH:MM:SS\"]" >&2
      exit 2
      ;;
    *)
      echo "[ERR] unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CLOSED_AT" ]]; then
  CLOSED_AT="$(date '+%Y-%m-%dT%H:%M:%S')"
fi

yaml_quote() {
  # YAML用にダブルクオートで囲んで最低限エスケープ
  # " -> \"  , CRは除去
  local s="${1//$'\r'/}"
  s="${s//\"/\\\"}"
  printf "\"%s\"" "$s"
}

TMP="$(mktemp)"

awk -v st="$STATUS_LC" \
    -v closed_at="$CLOSED_AT" \
    -v reason="$REASON" \
    -v superseded_by="$SUPERSEDED_BY" \
    -v review="$REVIEW" '
function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function yamlq(s,  t){
  t=s
  gsub(/\r/, "", t)
  gsub(/"/, "\\\"", t)
  return "\"" t "\""
}
BEGIN{
  started=0; inFM=0; fmDone=0;
  seen_decision=0; seen_closed=0;
  seen_reason=0; seen_sup=0; seen_review=0;
}
{
  line=$0
  sub(/\r$/, "", line)
  t=line
  gsub(/^[ \t]+|[ \t]+$/, "", t)

  if(started==0){
    if(t==""){ print $0; next }
    started=1
    if(t=="---"){ inFM=1; print $0; next }
    # frontmatter無しは非対応（あなたのノート前提では基本ある）
    print "[ERR] frontmatter not found at top of file" > "/dev/stderr"
    exit 3
  }

  if(inFM==1){
    # 終端
    if(t=="---"){
      # decision
      if(seen_decision==0){
        print "decision: " st
      }
      # closed
      if(st=="proposed"){
        # proposed は closed を付けない
      } else {
        if(seen_closed==0){
          print "closed: " closed_at
        }
      }
      # optional keys
      if(reason!="" && (st=="rejected" || st=="dropped")){
        if(seen_reason==0){
          print "rejected_reason: " yamlq(reason)
        }
      }
      if(superseded_by!="" && st=="superseded"){
        if(seen_sup==0){
          print "superseded_by: " yamlq("[[" superseded_by "]]")
        }
      }
      if(review!=""){
        if(seen_review==0){
          print "review: " yamlq("[[" review "]]")
        }
      }

      inFM=0; fmDone=1
      print $0
      next
    }

    # decision:
    if(t ~ /^decision:[ \t]*/){
      print "decision: " st
      seen_decision=1
      next
    }

    # closed:
    if(t ~ /^closed:[ \t]*/){
      if(st=="proposed"){
        # proposed -> closed行は削除
        seen_closed=1
        next
      } else {
        print "closed: " closed_at
        seen_closed=1
        next
      }
    }

    # rejected_reason:
    if(t ~ /^rejected_reason:[ \t]*/){
      if(reason!="" && (st=="rejected" || st=="dropped")){
        print "rejected_reason: " yamlq(reason)
      } else {
        # reason指定が無い/対象外ならそのまま残す
        print $0
      }
      seen_reason=1
      next
    }

    # superseded_by:
    if(t ~ /^superseded_by:[ \t]*/){
      if(superseded_by!="" && st=="superseded"){
        print "superseded_by: " yamlq("[[" superseded_by "]]")
      } else {
        print $0
      }
      seen_sup=1
      next
    }

    # review:
    if(t ~ /^review:[ \t]*/){
      if(review!=""){
        print "review: " yamlq("[[" review "]]")
      } else {
        print $0
      }
      seen_review=1
      next
    }

    # その他frontmatterはそのまま
    print $0
    next
  }

  # 本文はそのまま
  print $0
}
' "$FILE" > "$TMP" || {
  rc=$?
  rm -f "$TMP"
  exit "$rc"
}

mv "$TMP" "$FILE"
echo "[OK] updated decision status: $STATUS_LC -> $FILE"
