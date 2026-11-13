#!/bin/bash
set -euo pipefail
if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
        cat <<'USAGE'
Usage: bash scripts/install-update.sh
Build and install Yullo at its default destination.
For a custom destination, build first, then use:
  python3 scripts/install-update.py --destination /absolute/path/Yullo.app
USAGE
        exit 0
    fi
    printf '%s\n' 'This entry accepts no operands. Use --help for usage.' >&2
    exit 2
fi
cd "$(dirname "$0")/.."
bash build.sh
python3 scripts/install-update.py
