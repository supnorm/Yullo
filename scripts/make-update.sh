#!/bin/bash
set -euo pipefail
usage() {
    cat <<'USAGE'
Usage: bash scripts/make-update.sh [--archive PATH] [--staging DIR] [--download-url-prefix URL]
Stage a Sparkle update locally: sign the archive with the Keychain's EdDSA key,
then write appcast.xml beside it. Nothing is published, pushed or uploaded.
  --archive              a .zip or .dmg of the release; default: zips build/Yullo.app
  --staging              default: ../release-staging (outside the working copy)
  --download-url-prefix  where the archive will be served; default https://yullo.me/updates/
USAGE
}
cd "$(dirname "$0")/.."
ARCHIVE="" STAGING="$PWD/../release-staging" PREFIX="https://yullo.me/updates/"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --archive) ARCHIVE="$2"; shift 2 ;;
        --staging) STAGING="$2"; shift 2 ;;
        --download-url-prefix) PREFIX="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
SPARKLE="$(bash scripts/fetch-sparkle.sh)"
mkdir -p "$STAGING"
STAGING="$(cd "$STAGING" && pwd -P)"
case "$STAGING/" in "$(pwd -P)/"*) echo "Stage updates outside the working copy." >&2; exit 2 ;; esac
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$ARCHIVE" ]; then
    APP="$PWD/build/Yullo.app"
    python3 scripts/check-release.py "$APP" >/dev/null
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    ARCHIVE="$WORK/Yullo-$VERSION.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
fi
case "$ARCHIVE" in *.zip|*.dmg) ;; *) echo "The archive must be a .zip or .dmg." >&2; exit 2 ;; esac
NAME="$(basename "$ARCHIVE")"
if [ -e "$STAGING/$NAME" ]; then
    echo "$STAGING/$NAME already exists; each release needs a new version." >&2
    exit 1
fi

# The archive's app must raise both version numbers over every staged release.
python3 -I - "$ARCHIVE" "$STAGING/appcast.xml" "$WORK/inspect" <<'PY'
import plistlib, re, subprocess, sys, xml.etree.ElementTree as ET
from pathlib import Path
archive, appcast, inspect = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
inspect.mkdir()
if archive.suffix == ".zip":
    subprocess.run(["ditto", "-x", "-k", str(archive), str(inspect)], check=True)
    root, detach = inspect, None
else:
    subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(inspect), str(archive)],
                   check=True, stdout=subprocess.DEVNULL)
    root, detach = inspect, inspect
try:
    apps = [app for app in root.glob("*.app") if not app.is_symlink()]
    if len(apps) != 1:
        raise SystemExit("The archive must contain exactly one app.")
    with (apps[0] / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
finally:
    if detach:
        subprocess.run(["hdiutil", "detach", str(detach)], check=True, stdout=subprocess.DEVNULL)
version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
def parts(text): return tuple(int(part) for part in text.split("."))
if appcast.exists():
    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    for item in ET.parse(appcast).getroot().iter("item"):
        old_build = item.findtext(f"{ns}version") or ""
        old_version = item.findtext(f"{ns}shortVersionString") or old_build
        if not (int(build) > int(old_build) and parts(version) > parts(old_version)):
            raise SystemExit(f"Version {version} ({build}) does not raise staged release {old_version} ({old_build}).")
print(f"Staging Yullo {version} ({build})")
PY

cp "$ARCHIVE" "$STAGING/$NAME"
SIGNATURE="$("$SPARKLE/bin/sign_update" -p "$STAGING/$NAME")"
"$SPARKLE/bin/generate_appcast" --download-url-prefix "$PREFIX" --link "https://yullo.me" "$STAGING"
# EdDSA signatures are deterministic: the appcast must carry sign_update's.
if ! grep -q "sparkle:edSignature=\"$SIGNATURE\"" "$STAGING/appcast.xml"; then
    echo "appcast.xml does not carry the archive's signature." >&2
    exit 1
fi
echo "Staged $STAGING/appcast.xml and $STAGING/$NAME. Nothing was published."
