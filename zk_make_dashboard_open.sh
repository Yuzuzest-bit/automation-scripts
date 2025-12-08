#!/usr/bin/env bash
set -euo pipefail
cd "${1:-$PWD}"

shift || true
./make_tag_dashboard.sh "$@"

if command -v code >/dev/null 2>&1; then
  code -r dashboards/default_dashboard.md
fi
