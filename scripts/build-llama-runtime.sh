#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

LLAMA_REVISION=620d2225cc436ab0b001e3200e590e3b286ef9ab
LLAMA_SOURCE="$PWD/.runtime-source/llama.cpp-$LLAMA_REVISION"
LLAMA_BUILD="$PWD/.runtime-build/llama.cpp-$LLAMA_REVISION-source-paths-v1"
LLAMA_OUTPUT="$PWD/build/llama-runtime"
source scripts/runtime-source-paths.sh
source scripts/metal-library.sh
yullo_runtime_source_paths "$LLAMA_BUILD"
mkdir -p "$PWD/.runtime-source" "$LLAMA_OUTPUT"
if [ ! -d "$LLAMA_SOURCE/.git" ]; then
    git init "$LLAMA_SOURCE"
fi
if ! git -C "$LLAMA_SOURCE" rev-parse --verify HEAD >/dev/null 2>&1; then
    # A first run interrupted before checkout left no remote or no HEAD; set both again.
    git -C "$LLAMA_SOURCE" remote add origin https://github.com/ggml-org/llama.cpp.git 2>/dev/null || git -C "$LLAMA_SOURCE" remote set-url origin https://github.com/ggml-org/llama.cpp.git
    git -C "$LLAMA_SOURCE" fetch --depth 1 origin "$LLAMA_REVISION"
    git -C "$LLAMA_SOURCE" checkout --detach FETCH_HEAD
fi
if [ "$(git -C "$LLAMA_SOURCE" rev-parse HEAD)" != "$LLAMA_REVISION" ] ||
   [ -n "$(git -C "$LLAMA_SOURCE" status --porcelain --untracked-files=all)" ]; then
    echo "llama.cpp source must match the unmodified pinned revision. Delete $LLAMA_SOURCE and run again." >&2
    exit 1
fi
cmake -S Runtime/LocalTranslation -B "$LLAMA_BUILD" \
    "${YULLO_RUNTIME_CMAKE_FLAGS[@]}" \
    -DYULLO_LLAMA_SOURCE="$LLAMA_SOURCE" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DYULLO_BUILD_TRANSLATION_TESTS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=OFF -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod -DGGML_OPENMP=OFF
cmake --build "$LLAMA_BUILD" --target yullo-llama -j 4
cp "$LLAMA_BUILD/yullo-llama" "$LLAMA_OUTPUT/.yullo-llama.new"
strip -S "$LLAMA_OUTPUT/.yullo-llama.new"
mv -f "$LLAMA_OUTPUT/.yullo-llama.new" "$LLAMA_OUTPUT/yullo-llama"
yullo_metal_library "$LLAMA_SOURCE/ggml" "$LLAMA_OUTPUT" "$LLAMA_BUILD"
python3 - "$LLAMA_SOURCE" "$LLAMA_OUTPUT/LICENSE-llama.cpp.txt" <<'PY'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
notices = [source / 'LICENSE', source / 'ggml/LICENSE'] + sorted((source / 'licenses').glob('*'))
parts = []
for notice in notices:
    if notice.is_file():
        parts.append('## ' + str(notice.relative_to(source)) + '\n\n' + notice.read_text())
mozilla_source = (source / 'ggml/src/ggml-cpu/llamafile/sgemm.cpp').read_text()
mozilla = '\n'.join(line[3:] if line.startswith('// ') else line[2:]
                    for line in mozilla_source.split('\n\n', 1)[0].splitlines())
if 'Copyright 2024 Mozilla Foundation' not in mozilla or 'SOFTWARE.' not in mozilla:
    raise SystemExit('Missing pinned tinyBLAS source notice')
yarn_source = (source / 'ggml/src/ggml-metal/kernels/rope.metal').read_text()
yarn = next(line.removeprefix('// MIT licensed. ') for line in yarn_source.splitlines()
            if line.startswith('// MIT licensed. Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng.'))
mit_terms = (source / 'LICENSE').read_text().split('Permission is hereby granted', 1)[1]
parts += ['## tinyBLAS\n\n' + mozilla, '## YaRN\n\n' + yarn + '\n\nPermission is hereby granted' + mit_terms]
destination.write_text('\n\n'.join(parts))
PY
# Capture first: an otool failure stops the build, and grep -q cannot end the
# pipeline early and hide a match under pipefail.
linked="$(otool -L "$LLAMA_OUTPUT/yullo-llama" | tail -n +2 | awk '{print $1}')"
nonsystem="$(grep -vE '^(/usr/lib/|/System/Library/)' <<<"$linked" || true)"
if [ -n "$nonsystem" ]; then
    echo "Local translation helper depends on an unbundled non-system library." >&2
    exit 1
fi
echo "$LLAMA_OUTPUT/yullo-llama"
