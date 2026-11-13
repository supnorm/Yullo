#!/usr/bin/env python3
"""Package the native helper's corresponding source and an offline build recipe."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, required=True)
parser.add_argument("--build", type=Path, required=True)
parser.add_argument("--helper", type=Path, default=Path(__file__).resolve().parents[1] / "Runtime/LocalSpeech")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
revision = "dd92e32b6e268178ff43f4fa3ca36f0b380491e0"
actual = subprocess.check_output(["git", "-C", str(args.source), "rev-parse", "HEAD"], text=True).strip()
if actual != revision:
    raise SystemExit("Refusing to package a different runtime source revision")
if subprocess.check_output(["git", "-C", str(args.source), "status", "--porcelain", "--untracked-files=all"], text=True).strip():
    raise SystemExit("Refusing to package modified runtime source")
espeak = args.build / "_deps/espeak-static/download/espeak-ng-1.52.0.tar.gz"
if hashlib.sha256(espeak.read_bytes()).hexdigest() != "bb4338102ff3b49a81423da8a1a158b420124b055b60fa76cfb4b18677130a23":
    raise SystemExit("eSpeak source archive does not match its pinned digest")
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix=".speech-sources-", dir=args.output.parent) as temporary:
    root = Path(temporary) / "Yullo-Speech-Runtime-Sources"
    vendor = root / "audio.cpp"
    vendor.mkdir(parents=True)
    tracked = subprocess.check_output(["git", "-C", str(args.source), "ls-files", "-z"]).decode().split("\0")
    excluded = {"assets", "Notebooks", "webui", ".github", "ci"}
    for name in tracked:
        # Upstream CMake unconditionally reads its small server demo files at
        # configure time, even though the server is not built or distributed.
        required_configure_asset = name.startswith("webui/native/demo_voices/")
        if not name or (Path(name).parts[0] in excluded and not required_configure_asset):
            continue
        if Path(name).parts[0] in {"tests", "examples"} and Path(name).suffix.lower() in {
            ".wav", ".mp3", ".flac", ".safetensors", ".bin", ".npz", ".npy", ".pt", ".pth", ".onnx", ".gguf"
        }:
            continue
        source = args.source / name
        if not source.is_file() or source.is_symlink():
            continue
        target = vendor / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)
    # Yullo's serve entry point and its CMake project, which links audio.cpp.
    helper = root / "yullo-speech"
    helper.mkdir()
    helper_files = sorted(path for path in args.helper.iterdir()
        if path.is_file() and (path.name == "CMakeLists.txt" or path.suffix in {".cpp", ".h"}))
    if "CMakeLists.txt" not in {path.name for path in helper_files}:
        raise SystemExit("Missing the speech helper CMake project")
    for path in helper_files:
        shutil.copyfile(path, helper / path.name)
        (helper / path.name).chmod(0o644)
    shutil.copyfile(espeak, root / espeak.name)
    shutil.copyfile(Path(__file__).with_name("runtime-source-paths.sh"), root / "runtime-source-paths.sh")
    shutil.copyfile(Path(__file__).with_name("metal-library.sh"), root / "metal-library.sh")
    script = root / "build-offline.sh"
    script.write_text('''#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET=26.0
BUILD_DIR="${1:-$PWD/build}"
mkdir -p "$BUILD_DIR/_deps/espeak-static/download"
source runtime-source-paths.sh
source metal-library.sh
yullo_runtime_source_paths "$BUILD_DIR" espeak
cp espeak-ng-1.52.0.tar.gz "$BUILD_DIR/_deps/espeak-static/download/"
cmake -S yullo-speech -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \\
  "${YULLO_RUNTIME_CMAKE_FLAGS[@]}" -DYULLO_AUDIOCPP_SOURCE="$PWD/audio.cpp" \\
  -DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE \\
  -DAUDIOCPP_MODEL_SET=custom '-DAUDIOCPP_MODELS=kokoro_tts,qwen3_tts,cosyvoice3' \\
  -DAUDIOCPP_DEPLOYMENT_BUILD=ON -DENGINE_ENABLE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=OFF \\
  -DENGINE_ENABLE_NATIVE_CPU=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod \\
  -DENGINE_ENABLE_OPENMP=OFF -DAUDIOCPP_STATIC_ESPEAK=ON \\
  -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=OFF -DAUDIOCPP_BUILD_C_API=OFF \\
  -DENGINE_BUILD_TESTS=OFF -DENGINE_BUILD_EXAMPLES=OFF
cmake --build "$BUILD_DIR" --target yullo-speech -j 4
yullo_metal_library "$PWD/audio.cpp/external/ggml" "$BUILD_DIR/bin" "$BUILD_DIR"
''')
    script.chmod(0o755)
    (root / "README.md").write_text(
        "# Yullo local speech runtime — corresponding source\n\n"
        "This is the complete source needed to rebuild the separate GPL-3.0-or-later speech helper distributed with Yullo. "
        "The audio.cpp sources retain their Apache-2.0 terms, with their bundled third-party notices; eSpeak-ng is GPL-3.0-or-later. "
        "The combined helper is distributed under GPL-3.0-or-later. Model weights and binary test fixtures are not included. "
        "A small upstream server-demo folder is retained because its unmodified CMake configuration reads those files unconditionally; "
        "the server and those voices are not built into or distributed inside Yullo. All build inputs for the helper are supplied.\n\n"
        f"audio.cpp revision: `{revision}`. eSpeak-ng: `1.52.0`, source archive SHA-256 "
        "`bb4338102ff3b49a81423da8a1a158b420124b055b60fa76cfb4b18677130a23`. "
        "The source includes audio.cpp's eSpeak integration and its documented build-time patch, "
        "and Yullo's serve entry point and CMake project in `yullo-speech/`.\n\n"
        "The supplied runtime-source-paths.sh applies Clang file/debug prefix maps, including paths with spaces, "
        "and keeps eSpeak's unused default data directory at /usr/local/share/espeak-ng-data. "
        "Yullo supplies the actual pronunciation data path explicitly at runtime.\n\n"
        "eSpeak 1.52's build-time pronunciation-data compiler has a 160-byte path buffer. "
        "Deep build directories can truncate phoneme-source filenames and fail. "
        "Use a short fresh build directory, for example `bash build-offline.sh /tmp/yullo-speech-build`; "
        "the extracted source may remain elsewhere. This build-time limit is distinct from Yullo's "
        "private runtime data extraction and explicit pronunciation-data override.\n\n"
        "On an Apple Silicon Mac with Xcode command-line tools and CMake 3.20 or newer installed, run `bash build-offline.sh` with a fresh build directory. "
        "The source archive and dependencies are supplied here, so the build needs no model download or network access. "
        "Outputs are `build/bin/yullo-speech`, `build/bin/espeak-ng-data.bin` and `build/bin/default.metallib`. Copy them together. The executable is Yullo's small serve entry point "
        "in `yullo-speech/`, linked with the unmodified audio.cpp runtime; it keeps one model loaded for sequential requests over its standard input and output. "
        "The kernel library holds the runtime's Metal shaders, compiled once by the supplied metal-library.sh; Yullo places it in its app resources, "
        "where the helper finds it, instead of compiling shader source at every launch. "
        "No Python or Homebrew is required to run them. "
        "The source-only archive has no Git database; its rebuilt version metadata reports an unknown Git commit rather than a different parent checkout.\n")
    checksums = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in root.rglob("*") if path.is_file()}
    (root / "SHA256SUMS.json").write_text(json.dumps(checksums, indent=2, sort_keys=True) + "\n")
    archive = Path(temporary) / "sources.tar.gz"
    def normalize(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
        return info
    # Stable ordering and neutral metadata let a rebuilt app and its separate
    # corresponding-source archive carry the same independently checked pin.
    with archive.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as output:
            for path in [root] + sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
                output.add(path, arcname=str(Path(root.name) / path.relative_to(root)), recursive=False, filter=normalize)
    archive.replace(args.output)
    manifest_path = args.output.parent / "speech-runtime-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["correspondingSource"] = dict(name=args.output.name, sizeBytes=args.output.stat().st_size,
        sha256=hashlib.sha256(args.output.read_bytes()).hexdigest())
    staging = manifest_path.with_suffix(".json.new")
    staging.write_text(json.dumps(manifest, indent=2) + "\n")
    staging.replace(manifest_path)
print(args.output)
