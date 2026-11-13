#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build the pinned runtime and the bounded live PCM bridge.
TRANSCRIBE_REVISION=4d7c1ccefd39e5a9ea36cca5f8fefc6dcc14b99b
SOURCE="$PWD/.runtime-source/transcribe.cpp-$TRANSCRIBE_REVISION"
BUILD="$PWD/.runtime-build/transcribe.cpp-$TRANSCRIBE_REVISION-source-paths-v1"
OUTPUT="$PWD/build/transcribe-runtime"
source scripts/runtime-source-paths.sh
source scripts/metal-library.sh
yullo_runtime_source_paths "$BUILD"
mkdir -p "$PWD/.runtime-source" "$OUTPUT"
if [ ! -d "$SOURCE/.git" ]; then
    git init "$SOURCE"
fi
if ! git -C "$SOURCE" rev-parse --verify HEAD >/dev/null 2>&1; then
    # A first run interrupted before checkout left no remote or no HEAD; set both again.
    git -C "$SOURCE" remote add origin https://github.com/handy-computer/transcribe.cpp.git 2>/dev/null || git -C "$SOURCE" remote set-url origin https://github.com/handy-computer/transcribe.cpp.git
    git -C "$SOURCE" fetch --depth 1 origin "$TRANSCRIBE_REVISION"
    git -C "$SOURCE" checkout --detach FETCH_HEAD
fi
ACTUAL_REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
if [ "$ACTUAL_REVISION" != "$TRANSCRIBE_REVISION" ]; then
    echo "Transcribe source revision does not match the pinned version. Delete $SOURCE and run again." >&2
    exit 1
fi
if [ -n "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" ]; then
    echo "Transcribe source has local modifications; refusing a non-reproducible helper build. Delete $SOURCE and run again." >&2
    exit 1
fi
cmake -S "$SOURCE" -B "$BUILD" \
    "${YULLO_RUNTIME_CMAKE_FLAGS[@]}" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DTRANSCRIBE_BUILD_SHARED=OFF -DTRANSCRIBE_BUILD_TESTS=OFF \
    -DTRANSCRIBE_BUILD_TOOLS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=ON \
    -DTRANSCRIBE_ENABLE_VALIDATION_HOOKS=OFF -DTRANSCRIBE_INSTALL=OFF \
    -DTRANSCRIBE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=OFF \
    -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod \
    -DTRANSCRIBE_USE_OPENMP=OFF
cmake --build "$BUILD" --target transcribe-cli -j 4
# The batch helper is the unmodified upstream CLI behind an app-owned entry
# point that can load the model before the recording's path arrives. Only the
# CLI's `main` and its model-load call are renamed, with the CLI's own flags.
CLI_OBJECTS="$BUILD/yullo-transcribe-cli"
mkdir -p "$CLI_OBJECTS"
for unit in main asr diarize langid vad; do
    xcrun clang++ -std=c++17 -O3 -DNDEBUG -arch arm64 -mmacosx-version-min=26.0 \
        -fvisibility=hidden -fvisibility-inlines-hidden "${YULLO_RUNTIME_PREFIX_OPTIONS[@]}" \
        -DTRANSCRIBE_STATIC -Dmain=yullo_upstream_transcribe_main \
        -Dtranscribe_model_load_file=yullo_transcribe_model_load_file \
        -I "$SOURCE/include" -I "$SOURCE/examples/common" \
        -c "$SOURCE/examples/cli/$unit.cpp" -o "$CLI_OBJECTS/$unit.o"
done
xcrun clang++ -std=c++17 -O3 -DNDEBUG -arch arm64 -mmacosx-version-min=26.0 \
    "${YULLO_RUNTIME_PREFIX_OPTIONS[@]}" -DTRANSCRIBE_STATIC -I "$SOURCE/include" \
    "$PWD/Runtime/LocalRecognition/yullo-transcribe.cpp" "$CLI_OBJECTS"/*.o \
    "$BUILD/examples/common/libtranscribe-common-example.a" \
    "$BUILD/src/libtranscribe.a" "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-cpu.a" \
    "$BUILD/ggml/src/ggml-metal/libggml-metal.a" "$BUILD/ggml/src/libggml-base.a" \
    -lm -framework Foundation -framework Metal -framework MetalKit -framework Accelerate \
    -o "$OUTPUT/.yullo-transcribe.new"
strip -S "$OUTPUT/.yullo-transcribe.new"
mv -f "$OUTPUT/.yullo-transcribe.new" "$OUTPUT/yullo-transcribe"
# This independent bridge adds bounded live PCM transport while sharing the
# same pinned static runtime and notices as the batch helper.
xcrun clang++ -std=c++17 -O3 -arch arm64 -mmacosx-version-min=26.0 \
    "${YULLO_RUNTIME_PREFIX_OPTIONS[@]}" \
    -I "$SOURCE/include" -I "$SOURCE/examples/common" \
    "$PWD/Runtime/LiveRecognition/yullo-live-transcribe.cpp" \
    "$BUILD/src/libtranscribe.a" "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-cpu.a" \
    "$BUILD/ggml/src/ggml-metal/libggml-metal.a" "$BUILD/ggml/src/libggml-base.a" \
    -lm -framework Foundation -framework Metal -framework MetalKit -framework Accelerate \
    -o "$OUTPUT/.yullo-live-transcribe.new"
strip -S "$OUTPUT/.yullo-live-transcribe.new"
mv -f "$OUTPUT/.yullo-live-transcribe.new" "$OUTPUT/yullo-live-transcribe"
# Both helpers load these precompiled kernels from their bundle (or this directory).
yullo_metal_library "$SOURCE/ggml" "$OUTPUT" "$BUILD"
# Include the upstream notices and the individual notices in ggml's linked CPU
# kernels and compiled Metal shaders, rather than copying only the root MIT.
python3 - "$SOURCE" "$OUTPUT/LICENSE-transcribe.cpp.txt" <<'PY'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
root = (source / "LICENSE").read_text()
third_party = (source / "THIRD-PARTY-LICENSES.md").read_text()
mozilla_source = (source / "ggml/src/ggml-cpu/llamafile/sgemm.cpp").read_text()
mozilla = "\n".join(line[3:] if line.startswith("// ") else line[2:] for line in mozilla_source.split("\n\n", 1)[0].splitlines())
if "Copyright 2024 Mozilla Foundation" not in mozilla or "SOFTWARE." not in mozilla:
    raise SystemExit("Missing pinned tinyBLAS source notice")
yarn_source = (source / "ggml/src/ggml-metal/kernels/rope.metal").read_text()
yarn = next(line.removeprefix("// MIT licensed. ") for line in yarn_source.splitlines()
            if line.startswith("// MIT licensed. Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng."))
mit_terms = (source / "ggml/LICENSE").read_text().split("Permission is hereby granted", 1)[1]
destination.write_text(root + "\n" + third_party + "\n\n## tinyBLAS\n\n" + mozilla +
                      "\n\n## YaRN\n\n" + yarn + "\n\nPermission is hereby granted" + mit_terms)
PY
for helper in yullo-transcribe yullo-live-transcribe; do
    # Capture first: an otool failure stops the build, and grep -q cannot end the
    # pipeline early and hide a match under pipefail.
    linked="$(otool -L "$OUTPUT/$helper" | tail -n +2 | awk '{print $1}')"
    nonsystem="$(grep -vE '^(/usr/lib/|/System/Library/)' <<<"$linked" || true)"
    if [ -n "$nonsystem" ]; then
        echo "Transcribe helper depends on an unbundled non-system dynamic library." >&2
        exit 1
    fi
done
echo "$OUTPUT/yullo-transcribe"
echo "$OUTPUT/yullo-live-transcribe"
