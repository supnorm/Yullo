#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=26.0
SPEECH_REVISION=dd92e32b6e268178ff43f4fa3ca36f0b380491e0
SOURCE="$PWD/.runtime-source/audio.cpp-$SPEECH_REVISION"
# eSpeak's data compiler also has a 160-byte path buffer; keep this cache short.
BUILD="$PWD/.runtime-build/audio-${SPEECH_REVISION:0:12}-serve-v1"
OUTPUT="$PWD/build/speech-runtime"
source scripts/runtime-source-paths.sh
source scripts/metal-library.sh
yullo_runtime_source_paths "$BUILD" espeak
mkdir -p "$PWD/.runtime-source" "$OUTPUT"
if [ ! -d "$SOURCE/.git" ]; then
    git init "$SOURCE"
fi
if ! git -C "$SOURCE" rev-parse --verify HEAD >/dev/null 2>&1; then
    # A first run interrupted before checkout left no remote or no HEAD; set both again.
    git -C "$SOURCE" remote add origin https://github.com/0xShug0/audio.cpp.git 2>/dev/null || git -C "$SOURCE" remote set-url origin https://github.com/0xShug0/audio.cpp.git
    git -C "$SOURCE" fetch --depth 1 origin "$SPEECH_REVISION"
    git -C "$SOURCE" checkout --detach FETCH_HEAD
fi
if [ "$(git -C "$SOURCE" rev-parse HEAD)" != "$SPEECH_REVISION" ] ||
   [ -n "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" ]; then
    echo "Speech runtime source does not match the unmodified pinned revision. Delete $SOURCE and run again." >&2
    exit 1
fi
# Reuse only the already pinned dependency archive; never copy an old CMake cache.
for ESPEAK_ARCHIVE in "$PWD/.runtime-build/audio.cpp-$SPEECH_REVISION" "$PWD/.runtime-build/audio-${SPEECH_REVISION:0:12}-paths-v1"; do
    ESPEAK_ARCHIVE="$ESPEAK_ARCHIVE/_deps/espeak-static/download/espeak-ng-1.52.0.tar.gz"
    if [ -f "$ESPEAK_ARCHIVE" ] && [ ! -f "$BUILD/_deps/espeak-static/download/espeak-ng-1.52.0.tar.gz" ]; then
        mkdir -p "$BUILD/_deps/espeak-static/download"
        cp "$ESPEAK_ARCHIVE" "$BUILD/_deps/espeak-static/download/espeak-ng-1.52.0.tar.gz"
    fi
done
# Yullo's small serve entry point links the unmodified pinned runtime.
cmake -S Runtime/LocalSpeech -B "$BUILD" \
    "${YULLO_RUNTIME_CMAKE_FLAGS[@]}" -DYULLO_AUDIOCPP_SOURCE="$SOURCE" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DAUDIOCPP_MODEL_SET=custom '-DAUDIOCPP_MODELS=kokoro_tts,qwen3_tts,cosyvoice3' \
    -DAUDIOCPP_DEPLOYMENT_BUILD=ON -DENGINE_ENABLE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=OFF \
    -DENGINE_ENABLE_NATIVE_CPU=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod \
    -DENGINE_ENABLE_OPENMP=OFF -DAUDIOCPP_STATIC_ESPEAK=ON \
    -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=OFF -DAUDIOCPP_BUILD_C_API=OFF \
    -DENGINE_BUILD_TESTS=OFF -DENGINE_BUILD_EXAMPLES=OFF
cmake --build "$BUILD" --target yullo-speech -j 4
cp "$BUILD/bin/yullo-speech" "$OUTPUT/.yullo-speech.new"
strip -S "$OUTPUT/.yullo-speech.new"
mv -f "$OUTPUT/.yullo-speech.new" "$OUTPUT/yullo-speech"
yullo_metal_library "$SOURCE/external/ggml" "$OUTPUT" "$BUILD"
cp "$BUILD/bin/espeak-ng-data.bin" "$OUTPUT/espeak-ng-data.bin"
python3 - "$SOURCE" "$BUILD" "$OUTPUT" <<'PY'
from pathlib import Path
import hashlib, json, sys
source, build, output = map(Path, sys.argv[1:])
notices = [
    ("audio.cpp — Apache-2.0", source / "LICENSE"),
    ("ggml — MIT", source / "external/ggml/LICENSE"),
    ("SentencePiece — Apache-2.0", source / "external/sentencepiece/LICENSE"),
    ("Protocol Buffers Lite", source / "external/sentencepiece/third_party/protobuf-lite/LICENSE"),
    ("Abseil", source / "external/sentencepiece/third_party/absl/LICENSE"),
    ("esaxx", source / "external/sentencepiece/third_party/esaxx/LICENSE"),
    ("darts-clone", source / "external/sentencepiece/third_party/darts_clone/LICENSE"),
    ("cJSON — MIT", source / "external/cJSON/LICENSE"),
    ("libyaml — MIT", source / "external/libyaml/LICENSE"),
    ("utf8proc and Unicode data", source / "external/utf8proc/LICENSE.md"),
    ("eSpeak-ng — GPL-3.0-or-later", build / "_deps/espeak-static/source/COPYING"),
]
text = ("Yullo local speech helper\n\nThe independently built helper links eSpeak-ng and is distributed under GPL-3.0-or-later. "
        "The complete corresponding source and build instructions are supplied separately with this distribution. "
        "Yullo communicates with it through an isolated child process. Model weights are downloaded separately and retain their publishers' licenses.\n\n")
for title, path in notices:
    text += "\n\n" + title + "\n" + "=" * len(title) + "\n\n" + path.read_text()
sgemm = (source / "external/ggml/src/ggml-cpu/llamafile/sgemm.cpp").read_text().split("\n\n", 1)[0]
text += "\n\n" + "\n".join(line[3:] if line.startswith("// ") else line[2:] for line in sgemm.splitlines())
text += "\n\nYaRN: Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng.\n\nPermission is hereby granted" + (source / "external/ggml/LICENSE").read_text().split("Permission is hereby granted", 1)[1]
(output / "LICENSE-local-speech.txt").write_text(text)
files = []
for name in ["espeak-ng-data.bin", "default.metallib", "LICENSE-local-speech.txt"]:
    data = (output / name).read_bytes()
    files.append(dict(name=name, sizeBytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
(output / "speech-runtime-manifest.json").write_text(json.dumps(dict(schema=1, source="0xShug0/audio.cpp", revision="dd92e32b6e268178ff43f4fa3ca36f0b380491e0", espeakVersion="1.52.0", files=files), indent=2) + "\n")
PY
# Capture first: an otool failure stops the build, and grep -q cannot end the
# pipeline early and hide a match under pipefail.
linked="$(otool -L "$OUTPUT/yullo-speech" | tail -n +2 | awk '{print $1}')"
nonsystem="$(grep -vE '^(/usr/lib/|/System/Library/)' <<<"$linked" || true)"
if [ -n "$nonsystem" ]; then
    echo "Speech helper has an unbundled non-system library dependency." >&2
    exit 1
fi
python3 scripts/package-speech-runtime-sources.py --source "$SOURCE" --build "$BUILD" --output "$OUTPUT/Yullo-Speech-Runtime-Sources.tar.gz"
echo "$OUTPUT/yullo-speech"
