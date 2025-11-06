cat > /c/work/dev/aaa/smoke_collect.sh <<'EOF'
#!/usr/bin/env bash
set -eu
ROOT="/c/work/dev/aaa/使用検討/設計検討メモ"
OUT="/c/work/dev/aaa/debug.md"
mkdir -p "$(dirname "$OUT")"
echo "# Smoke Test" > "$OUT"
echo "- PWD: $(pwd)" >> "$OUT"
echo "- ROOT: $ROOT" >> "$OUT"
echo "- NOW: $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUT"
COUNT=$(find "$ROOT" -type f -name "*.md" | wc -l | tr -d '[:space:]')
echo "- MD files under ROOT: $COUNT" >> "$OUT"
echo "[SMOKE OK] wrote -> $OUT"
EOF
bash /c/work/dev/aaa/smoke_collect.sh
