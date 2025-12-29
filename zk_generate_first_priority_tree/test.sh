ROOT="/path/to/your/vault"
time bash -lc '
c=0
while IFS= read -r -d "" f; do
  name="$(basename "${f%.md}")"   # ←重い疑い
  c=$((c+1))
done < <(find "'"$ROOT"'" \( -path "*/.*" \) -prune -o -type f -name "*.md" -print0)
echo "count=$c"
'
