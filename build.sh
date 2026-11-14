#!/bin/bash
set -euo pipefail
if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
        cat <<'USAGE'
Usage: bash build.sh
Build, sign and audit build/Yullo.app without installing it.
YULLO_VERSION (default 1.0.1) and YULLO_BUILD (default 2) set a release's
CFBundleShortVersionString and CFBundleVersion; each release raises both.
USAGE
        exit 0
    fi
    printf '%s\n' 'This entry accepts no operands. Use --help for usage.' >&2
    exit 2
fi
cd "$(dirname "$0")"
# Reject missing/unavailable local identity before downloading or compiling.
python3 scripts/setup-signing.py --check
YULLO_VERSION="${YULLO_VERSION:-1.0.1}"
YULLO_BUILD="${YULLO_BUILD:-2}"
if ! [[ "$YULLO_VERSION" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){1,2}$ && "$YULLO_BUILD" =~ ^[1-9][0-9]*$ ]]; then
    echo "YULLO_VERSION must look like 1.1 or 1.0.1 and YULLO_BUILD must be a positive whole number." >&2
    exit 2
fi
SPARKLE="$(bash scripts/fetch-sparkle.sh)"
mkdir -p "$PWD/build"
TASK_STAGE="$(mktemp -d "$PWD/build/.yullo-release.XXXXXX")"
trap 'rm -rf "$TASK_STAGE"' EXIT
APP="$TASK_STAGE/Yullo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdParty" "$APP/Contents/Resources/Fonts"
source scripts/native-sources.sh
# Compile a private snapshot so parallel development cannot change a source file
# while the Swift frontend is reading it. None of these sources enters the app.
yullo_snapshot_sources "$TASK_STAGE/Source" "${YULLO_SOURCES[@]}" "${YULLO_APP_ONLY_SOURCES[@]}" App/main.swift
SNAPSHOT_SOURCES=("${YULLO_SOURCES[@]/#/$TASK_STAGE/Source/}" "${YULLO_APP_ONLY_SOURCES[@]/#/$TASK_STAGE/Source/}")
YULLO_KEYCHAIN_FLAGS=(-import-objc-header "$TASK_STAGE/Source/App/Services/KeychainInteraction.h")
# ggml loads precompiled Metal kernels (default.metallib) from the helper
# executable's bundle. Each pinned ggml revision needs its own kernels, so
# recognition and translation helpers live in nested bundles with their own
# Resources. The speech helper stays in Helpers and uses the app's Resources.
helper_bundle() {
    mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
    cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>$3</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
}
RECOGNITION="$APP/Contents/Helpers/LocalRecognition.bundle"
TRANSLATION="$APP/Contents/Helpers/LocalTranslation.bundle"
helper_bundle "$RECOGNITION" local.yullo.transcribe yullo-transcribe
helper_bundle "$TRANSLATION" local.yullo.llama yullo-llama
bash scripts/build-whisper-runtime.sh
cp build/whisper-runtime/yullo-whisper "$RECOGNITION/Contents/MacOS/yullo-whisper"
cp build/whisper-runtime/LICENSE-whisper.cpp.txt "$APP/Contents/Resources/ThirdParty/LICENSE-whisper.cpp.txt"
bash scripts/build-transcribe-runtime.sh
cp build/transcribe-runtime/yullo-transcribe "$RECOGNITION/Contents/MacOS/yullo-transcribe"
cp build/transcribe-runtime/yullo-live-transcribe "$RECOGNITION/Contents/MacOS/yullo-live-transcribe"
cp build/transcribe-runtime/LICENSE-transcribe.cpp.txt "$APP/Contents/Resources/ThirdParty/LICENSE-transcribe.cpp.txt"
# The pinned whisper.cpp and transcribe.cpp revisions carry identical ggml
# kernels; one copy serves all three recognition helpers.
for library in default.metallib ggml-tensor.metallib; do
    if ! cmp -s "build/whisper-runtime/$library" "build/transcribe-runtime/$library"; then
        echo "Whisper and transcribe Metal kernels differ; give each runtime its own helper bundle." >&2
        exit 1
    fi
    cp "build/transcribe-runtime/$library" "$RECOGNITION/Contents/Resources/$library"
done
bash scripts/build-llama-runtime.sh
cp build/llama-runtime/yullo-llama "$TRANSLATION/Contents/MacOS/yullo-llama"
cp build/llama-runtime/default.metallib build/llama-runtime/ggml-tensor.metallib "$TRANSLATION/Contents/Resources/"
cp build/llama-runtime/LICENSE-llama.cpp.txt "$APP/Contents/Resources/ThirdParty/LICENSE-llama.cpp.txt"
bash scripts/build-speech-runtime.sh
cp build/speech-runtime/yullo-speech "$APP/Contents/Helpers/yullo-speech"
cp build/speech-runtime/default.metallib "$APP/Contents/Resources/default.metallib"
mkdir -p "$APP/Contents/Resources/LocalSpeech"
cp build/speech-runtime/espeak-ng-data.bin "$APP/Contents/Resources/LocalSpeech/espeak-ng-data.bin"
cp build/speech-runtime/LICENSE-local-speech.txt "$APP/Contents/Resources/ThirdParty/LICENSE-local-speech.txt"
cp build/speech-runtime/speech-runtime-manifest.json "$APP/Contents/Resources/ThirdParty/"
mkdir -p "$APP/Contents/Resources/Audio"
cp Assets/Audio/YulloSampleVoice.wav Assets/Audio/YulloSampleVoice.provenance.json "$APP/Contents/Resources/Audio/"
cp Assets/Fonts/IBMPlexMono-Regular.otf "$APP/Contents/Resources/Fonts/IBMPlexMono-Regular.otf"
cp Assets/Fonts/LICENSE-IBMPlexMono.txt "$APP/Contents/Resources/Fonts/LICENSE-IBMPlexMono.txt"
xcrun swiftc "${YULLO_KEYCHAIN_FLAGS[@]}" -target arm64-apple-macosx26.0 -module-cache-path "$TASK_STAGE/ModuleCache" -swift-version 5 -warnings-as-errors -O -whole-module-optimization -Xlinker -dead_strip -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks "${YULLO_FRAMEWORKS[@]}" "${SNAPSHOT_SOURCES[@]}" "$TASK_STAGE/Source/App/main.swift" -o "$APP/Contents/MacOS/Yullo"
strip -S "$APP/Contents/MacOS/Yullo"
# The pinned official Sparkle framework, unchanged apart from its signature.
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/ThirdParty/LICENSE-Sparkle.txt"
xcrun actool --compile "$APP/Contents/Resources" --output-partial-info-plist "$TASK_STAGE/IconInfo.plist" --app-icon Yullo --platform macosx --minimum-deployment-target 26.0 --target-device mac --output-format human-readable-text --warnings --errors Assets/Yullo.icon
for language in en zh-Hans fr de it es zh-Hant; do
    mkdir -p "$APP/Contents/Resources/$language.lproj"
    cp "Localizations/$language.lproj/Localizable.strings" "$APP/Contents/Resources/$language.lproj/Localizable.strings"
    cp "Localizations/$language.lproj/InfoPlist.strings" "$APP/Contents/Resources/$language.lproj/InfoPlist.strings"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Yullo</string>
<key>CFBundleIdentifier</key><string>me.yullo.app</string>
<key>CFBundleName</key><string>Yullo</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>fr</string><string>de</string><string>it</string><string>es</string><string>zh-Hant</string></array>
<key>CFBundleVersion</key><string>$YULLO_BUILD</string>
<key>CFBundleIconFile</key><string>Yullo</string>
<key>CFBundleIconName</key><string>Yullo</string>
<key>CFBundleShortVersionString</key><string>$YULLO_VERSION</string>
<key>NSHumanReadableCopyright</key><string>© 2026 The Yullo authors · yullo.me</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>SUFeedURL</key><string>https://yullo.me/appcast.xml</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUEnableSystemProfiling</key><false/>
<key>SUPublicEDKey</key><string>kuzn2Z9HovgduO7XAO1BaJSSLtOFQwSdedkzNClLuTU=</string>
<key>NSMicrophoneUsageDescription</key><string>Yullo uses your microphone for local dictation and voice translation. Audio is processed on this Mac.</string>
</dict></plist>
PLIST
# Keep this identity stable: Keychain grants follow the designated requirement.
# Never silently fall back to ad-hoc signing if the identity is unavailable.
SIGNING_IDENTITY="$(cat signing-identity.txt)"
# Sign nested code inside out: extra executables, then each helper bundle,
# which seals its Metal kernels and signs its main executable.
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --identifier "local.yullo.whisper" "$RECOGNITION/Contents/MacOS/yullo-whisper"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --identifier "local.yullo.live-transcribe" "$RECOGNITION/Contents/MacOS/yullo-live-transcribe"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$RECOGNITION"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$TRANSLATION"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --identifier "local.yullo.speech" "$APP/Contents/Helpers/yullo-speech"
# Sparkle's nested code, inside out, then the framework itself.
SPARKLE_CODE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for code in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --preserve-metadata=identifier,entitlements "$SPARKLE_CODE/$code"
done
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --requirements "=designated => identifier \"me.yullo.app\" and certificate leaf = H\"$SIGNING_IDENTITY\"" "$APP"
python3 scripts/check-release.py "$APP"
# Publish only a fully verified, freshly assembled bundle. Never overlay an old
# build: otherwise removed resources or accidental fixtures could remain inside.
python3 - "$APP" "$PWD/build/Yullo.app" "$TASK_STAGE/previous.app" <<'PY'
from pathlib import Path
import shutil
import sys
staged, destination, previous = map(Path, sys.argv[1:])
if destination.exists():
    destination.rename(previous)
try:
    staged.rename(destination)
except BaseException:
    if previous.exists():
        previous.rename(destination)
    raise
if previous.exists():
    shutil.rmtree(previous)
PY
echo "$PWD/build/Yullo.app"
