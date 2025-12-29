time bash -lc '
c=0
while IFS= read -r -d "" f; do
  head -c 1 "$f" >/dev/null 2>&1 || true
  c=$((c+1))
done < <(find "'"$ROOT"'" \( -path "*/.*" \) -prune -o -type f -name "*.md" -print0)
echo "opened=$c"
'
