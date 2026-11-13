#!/usr/bin/env python3
"""Audit the shipped app without launching it or touching user preferences."""
import argparse
import base64
import os
import re
import json
import hashlib
import plistlib
import stat
import subprocess
from pathlib import Path


def require(condition, message):
    if not condition:
        raise SystemExit(f"Release audit failed: {message}")


def speech_runtime_files(manifest):
    require(isinstance(manifest, dict), "invalid speech runtime manifest")
    require(type(manifest.get("schema")) is int and manifest["schema"] == 1,
            "unsupported speech runtime manifest schema")
    require(manifest.get("source") == "0xShug0/audio.cpp"
            and manifest.get("revision") == "dd92e32b6e268178ff43f4fa3ca36f0b380491e0"
            and manifest.get("espeakVersion") == "1.52.0", "changed pinned speech runtime")
    files = manifest.get("files")
    required = {"espeak-ng-data.bin", "default.metallib", "LICENSE-local-speech.txt"}
    require(isinstance(files, list) and len(files) == len(required)
            and all(isinstance(entry, dict) and isinstance(entry.get("name"), str) for entry in files)
            and {entry["name"] for entry in files} == required,
            "missing, duplicate or unexpected speech runtime resource records")
    for entry in files:
        digest = entry.get("sha256")
        require(type(entry.get("sizeBytes")) is int and entry["sizeBytes"] > 0
                and isinstance(digest, str) and len(digest) == 64
                and all(char in "0123456789abcdef" for char in digest),
                "invalid speech runtime resource identity")
    return files


private_build_prefixes = {
    b"/Users/",
    str(Path.home()).rstrip("/").encode() + b"/",
    str(Path(__file__).resolve().parents[1]).encode() + b"/",
} - {b"/"}


def check_build_paths(data, name):
    require(not any(prefix in data for prefix in private_build_prefixes), f"private build path in {name}")


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", nargs="?", type=Path, default=Path("build/Yullo.app"),
                    help="app bundle to audit; defaults to build/Yullo.app")
app = parser.parse_args().app
require(not app.is_symlink(), "unexpected symbolic link at bundle root")
app = app.resolve()
locales = {"en", "zh-Hans", "fr", "de", "it", "es", "zh-Hant"}
# ggml loads default.metallib from its executable's bundle: nested bundles keep
# each pinned runtime's precompiled kernels apart; speech uses the app's Resources.
metal_libraries = ("Resources/default.metallib", "Resources/ggml-tensor.metallib")
helper_bundles = {
    "Contents/Helpers/LocalRecognition.bundle": "Contents/Helpers/LocalRecognition.bundle/Contents/MacOS",
    "Contents/Helpers/LocalTranslation.bundle": "Contents/Helpers/LocalTranslation.bundle/Contents/MacOS",
}
bundle_helpers = {
    "Contents/Helpers/LocalRecognition.bundle": ("yullo-whisper", "yullo-transcribe", "yullo-live-transcribe"),
    "Contents/Helpers/LocalTranslation.bundle": ("yullo-llama",),
}
helper_paths = {name: f"{helper_bundles[bundle]}/{name}" for bundle, names in bundle_helpers.items() for name in names}
helper_paths["yullo-speech"] = "Contents/Helpers/yullo-speech"
expected_files = {
    "Contents/Info.plist",
    *(f"{bundle}/Contents/{name}" for bundle in helper_bundles
      for name in ("Info.plist", "_CodeSignature/CodeResources", *metal_libraries)),
    *(f"{helper_bundles[bundle]}/{name}" for bundle, names in bundle_helpers.items() for name in names),
    "Contents/Helpers/yullo-speech",
    "Contents/Resources/default.metallib",
    "Contents/Resources/LocalSpeech/espeak-ng-data.bin",
    "Contents/Resources/ThirdParty/LICENSE-llama.cpp.txt",
    "Contents/Resources/ThirdParty/LICENSE-Sparkle.txt",
    "Contents/Resources/ThirdParty/LICENSE-local-speech.txt",
    "Contents/Resources/ThirdParty/speech-runtime-manifest.json",
    "Contents/Resources/Audio/YulloSampleVoice.wav",
    "Contents/Resources/Audio/YulloSampleVoice.provenance.json",
    "Contents/Resources/ThirdParty/LICENSE-whisper.cpp.txt",
    "Contents/Resources/ThirdParty/LICENSE-transcribe.cpp.txt",
    "Contents/Resources/Fonts/IBMPlexMono-Regular.otf",
    "Contents/Resources/Fonts/LICENSE-IBMPlexMono.txt",
    "Contents/MacOS/Yullo",
    "Contents/Resources/Yullo.icns",
    "Contents/Resources/Assets.car",
    "Contents/_CodeSignature/CodeResources",
    *(f"Contents/Resources/{code}.lproj/Localizable.strings" for code in locales),
    *(f"Contents/Resources/{code}.lproj/InfoPlist.strings" for code in locales),
}
expected_directories = {
    "Contents", "Contents/MacOS", "Contents/Frameworks", "Contents/Frameworks/Sparkle.framework", "Contents/Resources", "Contents/_CodeSignature",
    "Contents/Helpers", "Contents/Resources/ThirdParty",
    *(f"{bundle}{suffix}" for bundle in helper_bundles
      for suffix in ("", "/Contents", "/Contents/MacOS", "/Contents/Resources", "/Contents/_CodeSignature")),
    "Contents/Resources/Fonts", "Contents/Resources/Audio", "Contents/Resources/LocalSpeech",
    *(f"Contents/Resources/{code}.lproj" for code in locales),
}
require(app.is_dir(), f"missing bundle: {app}")
# Exactly one embedded framework: the pinned official Sparkle release, whose
# tree (symbolic links included) must match it, re-signed with the app's identity.
framework = app / "Contents/Frameworks/Sparkle.framework"
pinned = Path(__file__).resolve().parents[1] / ".runtime-source/Sparkle-2.10.1/Sparkle.framework"
entries = [entry for entry in app.rglob("*") if framework not in entry.parents]

modes = {entry: entry.lstat().st_mode for entry in entries}
unsupported = sorted(str(entry.relative_to(app)) for entry, mode in modes.items()
                     if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)))
require(not unsupported, f"unsupported bundle entry type: {unsupported}")
files = {str(entry.relative_to(app)) for entry, mode in modes.items() if stat.S_ISREG(mode)}
directories = {str(entry.relative_to(app)) for entry, mode in modes.items() if stat.S_ISDIR(mode)}
require(files == expected_files, f"bundle file mismatch: extra={sorted(files - expected_files)}, missing={sorted(expected_files - files)}")
require(directories == expected_directories, f"bundle directory mismatch: extra={sorted(directories - expected_directories)}, missing={sorted(expected_directories - directories)}")
require(pinned.is_dir(), "pinned Sparkle release is missing; run scripts/fetch-sparkle.sh")



def tree(root):
    result = {}
    for entry in root.rglob("*"):
        name = str(entry.relative_to(root))
        mode = entry.lstat().st_mode
        if stat.S_ISLNK(mode):
            result[name] = ("link", os.readlink(entry))
        elif stat.S_ISDIR(mode):
            result[name] = ("dir", None)
        elif stat.S_ISREG(mode):
            # Signatures and signed executables change on re-signing.
            data = entry.read_bytes()
            signed = "_CodeSignature" in entry.parts or data[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
            result[name] = ("file", None if signed else hashlib.sha256(data).hexdigest())
        else:
            result[name] = ("other", None)
    return result


require((app / "Contents/Resources/ThirdParty/LICENSE-Sparkle.txt").read_bytes() == (pinned.parent / "LICENSE").read_bytes(),
        "missing or modified Sparkle license")
require(not framework.is_symlink() and tree(framework) == tree(pinned), "embedded Sparkle differs from the pinned release")
with (framework / "Resources/Info.plist").open("rb") as source:
    require(plistlib.load(source).get("CFBundleShortVersionString") == "2.10.1", "unexpected Sparkle version")
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
require(info.get("CFBundleIdentifier") == "me.yullo.app", "changed stable bundle identifier")
require(info.get("CFBundleExecutable") == "Yullo", "unexpected executable")
font = app / "Contents/Resources/Fonts/IBMPlexMono-Regular.otf"
font_license = app / "Contents/Resources/Fonts/LICENSE-IBMPlexMono.txt"
require(hashlib.sha256(font.read_bytes()).hexdigest() == "372fe8f8a459baef84ee346b0a478084e80c46bd299a0c27bcb0f3412f5a9d28", "changed pinned Plex Mono font")
require(hashlib.sha256(font_license.read_bytes()).hexdigest() == "7e6b2818edbd8f6a01ae80641cc8f16a51080d08fb4e532be3a0b6f74adb07da", "missing or modified Plex copyright/OFL notice")
require(bool(info.get("NSMicrophoneUsageDescription")), "missing microphone purpose")
for bundle in helper_bundles:
    subprocess.run(["codesign", "--verify", "--strict", str(app / bundle)], check=True)
    with (app / bundle / "Contents/Info.plist").open("rb") as source:
        helper_info = plistlib.load(source)
    require(helper_info.get("CFBundlePackageType") == "BNDL"
            and helper_info.get("CFBundleExecutable") in bundle_helpers[bundle], f"invalid helper bundle {bundle}")
    for library in metal_libraries:
        data = (app / bundle / "Contents" / library).read_bytes()
        require(data.startswith(b"MTLB"), f"invalid Metal library in {bundle}")
        check_build_paths(data, f"{bundle} {library}")
speech_metal = (app / "Contents/Resources/default.metallib").read_bytes()
require(speech_metal.startswith(b"MTLB"), "invalid speech Metal library")
check_build_paths(speech_metal, "speech Metal library")
for name, path in helper_paths.items():
    helper = app / path
    check_build_paths(helper.read_bytes(), name)
    subprocess.run(["codesign", "--verify", "--strict", str(helper)], check=True)
    linked = subprocess.run(["otool", "-L", str(helper)], check=True, capture_output=True, text=True).stdout.splitlines()[1:]
    require(all(line.strip().startswith(("/usr/lib/", "/System/Library/")) for line in linked), f"{name} has unbundled dependencies")
transcribe_license = (app / "Contents/Resources/ThirdParty/LICENSE-transcribe.cpp.txt").read_text()
require(all(notice in transcribe_license for notice in ("The transcribe.cpp authors", "The ggml authors", "Silero Team", "RAD Game Tools", "Mozilla Foundation", "Jeffrey Quesnelle and Bowen Peng")), "missing transcribe runtime component attribution")
speech_notice = (app / "Contents/Resources/ThirdParty/LICENSE-local-speech.txt").read_text()
require(all(notice in speech_notice for notice in ("GPL-3.0-or-later", "GNU GENERAL PUBLIC LICENSE", "corresponding source", "eSpeak-ng", "SentencePiece", "Mozilla Foundation")), "incomplete local speech helper attribution/source notice")
llama_notice = (app / "Contents/Resources/ThirdParty/LICENSE-llama.cpp.txt").read_text()
require(all(notice in llama_notice for notice in ("The ggml authors", "Mozilla Foundation", "Jeffrey Quesnelle")), "incomplete llama runtime attribution")
speech_manifest = json.loads((app / "Contents/Resources/ThirdParty/speech-runtime-manifest.json").read_text())
for entry in speech_runtime_files(speech_manifest):
    directory = {"espeak-ng-data.bin": "Contents/Resources/LocalSpeech",
                 "default.metallib": "Contents/Resources"}.get(entry["name"], "Contents/Resources/ThirdParty")
    data = (app / directory / entry["name"]).read_bytes()
    require(len(data) == entry["sizeBytes"] and hashlib.sha256(data).hexdigest() == entry["sha256"], "speech runtime resource mismatch")
sample = (app / "Contents/Resources/Audio/YulloSampleVoice.wav").read_bytes()
provenance = json.loads((app / "Contents/Resources/Audio/YulloSampleVoice.provenance.json").read_text())
require(len(sample) == 303_644 and hashlib.sha256(sample).hexdigest() == "c39dc94d352fd4e8588660f06746fcdfd53658cf39fa5e02ff03319e1f5fc476", "changed formal sample voice")
require(provenance.get("audioSHA256") == hashlib.sha256(sample).hexdigest(), "sample voice provenance mismatch")
require(re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){1,2}", info.get("CFBundleShortVersionString", ""))
        and re.fullmatch(r"[1-9][0-9]*", info.get("CFBundleVersion", "")), "invalid version/build")
require(info.get("SUFeedURL") == "https://yullo.me/appcast.xml" and len(base64.b64decode(info.get("SUPublicEDKey", ""))) == 32,
        "missing or changed update feed/public key")
require(info.get("SUEnableAutomaticChecks") is True and info.get("SUEnableSystemProfiling") is False,
        "updates must default to automatic checks without system profiling")
require(info.get("CFBundleIconName") == "Yullo", "missing native appearance-aware app icon")
require(set(info.get("CFBundleLocalizations", [])) == locales, "unexpected interface languages")
catalog = json.loads(subprocess.run(["xcrun", "assetutil", "--info", str(app / "Contents/Resources/Assets.car")], check=True, capture_output=True, text=True).stdout)
icon_stacks = {entry.get("Appearance"): entry for entry in catalog
               if entry.get("Name") == "Yullo" and entry.get("AssetType") == "IconImageStack"}
require({"NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"} <= icon_stacks.keys(), "missing native light/dark icon variants")
require(icon_stacks["NSAppearanceNameAqua"]["SHA1Digest"] != icon_stacks["NSAppearanceNameDarkAqua"]["SHA1Digest"], "light and dark icons are identical")

executable = app / "Contents/MacOS/Yullo"
binary = executable.read_bytes()
check_build_paths(binary, "Yullo")
for marker in (
    b"--test-", b"testExecutor", b"testClipboardWriter", b"testReplacementExecutor",
    b"runRuntimeChecks", b"runControlChecks", b"ReplacementFixture",
    b"HeaderHitChecks", b"NativeTextReplacementChecks", b"YULLO_TESTING",
    b"ControlChecks.swift", b"RuntimeChecks.swift", b"Generated text only",
    b"LiveServicesChecks", b"--azure-schema", b"--groq-literal",
    b"yulloTesting", b"YulloActionPresentationProbe",
    b"yulloTestingCaptureAttachedSpeechKeyRemoval",
    b"testContent", b"Generated mixed-language preview",
    b"speechActivityEnabled",
):
    require(marker not in binary, f"test code or fixture marker in executable: {marker.decode()}")
# Check exported/local symbols too, so a future optimizer cannot hide an accidental hook
# behind a changed string layout. The allowlist also catches source, scripts and fixtures.
symbols = subprocess.run(["nm", "-a", str(executable)], check=True, capture_output=True, text=True).stdout
for marker in ("testExecutor", "testClipboardWriter", "testReplacementExecutor", "runRuntimeChecks", "runControlChecks", "yulloTesting", "YulloActionPresentationProbe", "testContent", "speechActivityEnabled"):
    require(marker not in symbols, f"test hook symbol in executable: {marker}")

identity_file = Path(__file__).resolve().parents[1] / "signing-identity.txt"
identity = identity_file.read_text().strip()
require(len(identity) == 40 and all(char in "0123456789abcdefABCDEF" for char in identity), "invalid signing identity fingerprint")
requirement = f'=identifier "me.yullo.app" and certificate leaf = H"{identity}"'
subprocess.run(["codesign", "--verify", "--strict", "--test-requirement", requirement, str(app)], check=True)
subprocess.run(["codesign", "--verify", "--strict", "--deep", "--test-requirement", f'=certificate leaf = H"{identity}"', str(framework)], check=True)
size = sum(entry.stat().st_size for entry in entries if entry.is_file())
print(f"PASS: release bundle allowlist, no test entry points/hooks/fixtures, stable signature; {len(files)} files, {size:,} bytes")
for name in sorted(files):
    print(f"  {name}")
