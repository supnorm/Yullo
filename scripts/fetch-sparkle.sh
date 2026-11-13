#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Download the pinned official Sparkle release once, verify it and keep it
# outside the repository with the other runtime sources. Prints its folder.
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
SOURCE="$PWD/.runtime-source/Sparkle-$SPARKLE_VERSION"
if [ ! -f "$SOURCE/.verified" ]; then
    mkdir -p "$PWD/.runtime-source"
    STAGE="$(mktemp -d "$PWD/.runtime-source/.sparkle.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    curl -fsSL -o "$STAGE/Sparkle.tar.xz" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    if [ "$(shasum -a 256 "$STAGE/Sparkle.tar.xz" | cut -d ' ' -f 1)" != "$SPARKLE_SHA256" ]; then
        echo "Sparkle download does not match the pinned checksum." >&2
        exit 1
    fi
    mkdir "$STAGE/Sparkle"
    tar -xJf "$STAGE/Sparkle.tar.xz" -C "$STAGE/Sparkle"
    touch "$STAGE/Sparkle/.verified"
    rm -rf "$SOURCE"
    mv "$STAGE/Sparkle" "$SOURCE"
fi
echo "$SOURCE"
