#!/bin/bash

# --- テスト用のスクリプトです ---

# 1. テスト用のフォルダ名を定義
TEST_DIR_NAME="test_folder_123"

echo "1. Creating test folder: ${TEST_DIR_NAME}"
# 2. フォルダを作成
mkdir -p "${TEST_DIR_NAME}"

# 3. 絶対パスに変換
ABS_PATH=$(readlink -f "${TEST_DIR_NAME}")
echo "2. Absolute POSIX path: ${ABS_PATH}"

# 4. Windowsパスに変換
WIN_PATH=$(cygpath -w "${ABS_PATH}")
echo "3. Converted Windows path: ${WIN_PATH}"

# 5. Explorerで開く
echo "4. Opening in Explorer..."
explorer.exe "${WIN_PATH}"

echo "5. Script finished."

 * Git Bashで以下のコマンドを実行します。
   ./test_explorer.sh
