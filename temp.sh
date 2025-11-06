# 1-1) 出力ディレクトリは存在しますか？
ls -ald "/c/work/dev/aaaa"

# 1-2) そこに手動で書けるか？（1行だけ書いてみる）
echo "hello" > "/c/work/dev/aaaa/debug.md"

# 1-3) 本当にできたか？
ls -al "/c/work/dev/aaaa/debug.md"
type "/c/work/dev/aaaa/debug.md" 2>/dev/null || cat "/c/work/dev/aaaa/debug.md"
