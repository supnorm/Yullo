#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build the app-owned private-hint entry point around the pinned upstream CLI.
WHISPER_REVISION=d1be6fde11ac6e0407606b4e42fe72d34add8037
WHISPER_TAG=v1.9.5
SOURCE="$PWD/.runtime-source/whisper.cpp-$WHISPER_TAG"
BUILD="$PWD/.runtime-build/yullo-whisper-$WHISPER_TAG-private-hints-v1"
OUTPUT="$PWD/build/whisper-runtime"
source scripts/runtime-source-paths.sh
source scripts/metal-library.sh
yullo_runtime_source_paths "$BUILD"
mkdir -p "$PWD/.runtime-source" "$OUTPUT"
if [ ! -d "$SOURCE/.git" ]; then
    git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git "$SOURCE"
fi
ACTUAL_REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
if [ "$ACTUAL_REVISION" != "$WHISPER_REVISION" ]; then
    echo "Whisper source revision does not match the pinned release." >&2
    exit 1
fi
if [ -n "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" ]; then
    echo "Whisper source has local modifications; refusing a non-reproducible helper build." >&2
    exit 1
fi
cmake -S "$PWD/Runtime/LocalRecognition" -B "$BUILD" \
    "${YULLO_RUNTIME_CMAKE_FLAGS[@]}" \
    -DYULLO_WHISPER_SOURCE="$SOURCE" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_COREML=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=OFF \
    -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod \
    -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple
cmake --build "$BUILD" --target yullo-whisper -j 4
cp "$BUILD/yullo-whisper" "$OUTPUT/.yullo-whisper.new"
strip -S "$OUTPUT/.yullo-whisper.new"
mv -f "$OUTPUT/.yullo-whisper.new" "$OUTPUT/yullo-whisper"
yullo_metal_library "$SOURCE/ggml" "$OUTPUT" "$BUILD"
cp "$SOURCE/LICENSE" "$OUTPUT/LICENSE-whisper.cpp.txt"
# Capture first: an otool failure stops the build, and grep -q cannot end the
# pipeline early and hide a match under pipefail.
linked="$(otool -L "$OUTPUT/yullo-whisper" | tail -n +2 | awk '{print $1}')"
nonsystem="$(grep -vE '^(/usr/lib/|/System/Library/)' <<<"$linked" || true)"
if [ -n "$nonsystem" ]; then
    echo "Whisper helper depends on an unbundled non-system dynamic library." >&2
    exit 1
fi
echo "$OUTPUT/yullo-whisper"
