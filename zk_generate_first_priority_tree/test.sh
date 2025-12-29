ROOT="/path/to/your/vault"
time find "$ROOT" \( -path "*/.*" \) -prune -o -type f -name "*.md" -print | wc -l
