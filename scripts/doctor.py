#!/usr/bin/env python3
"""Check this Mac for building Yullo from source. Prints one line per problem, with the fix."""

import argparse
import glob
import importlib.util
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
XCODE = "/Applications/Xcode.app"
SELECT_XCODE = f"sudo xcode-select --switch {XCODE}"
# A first build keeps about 1 GB of pinned sources, 1 GB of intermediate files and the app.
NEEDED_GB = 5
# eSpeak's data compiler keeps its folder path in a 160-byte buffer, and that folder
# sits this many characters below the checkout (see scripts/build-speech-runtime.sh).
SPEECH_DATA_DEPTH = len("/.runtime-build/audio-dd92e32b6e26-serve-v1/_deps/espeak-static/build/espeak-ng-data")
LONGEST_FOLDER = 159 - SPEECH_DATA_DEPTH
PINNED_SOURCES = ("Sparkle-", "whisper.cpp-", "transcribe.cpp-", "llama.cpp-", "audio.cpp-")


def run(command, **options):
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=options.pop("timeout", 60), **options)
    except (OSError, subprocess.TimeoutExpired) as error:
        return subprocess.CompletedProcess(command, 127, "", str(error))


def major(version):
    match = re.match(r"\s*(\d+)", version or "")
    return int(match.group(1)) if match else 0


def version_tuple(text):
    return tuple(int(part) for part in re.findall(r"\d+", text)[:3])


class Report:
    def __init__(self):
        self.lines = []

    def ok(self, text):
        self.lines.append(("ok", text))

    def problem(self, text, fix=None):
        self.lines.append(("fix", text + (f" Fix: {fix}" if fix else "")))

    def note(self, text):
        self.lines.append(("note", text))

    @property
    def problems(self):
        return [text for kind, text in self.lines if kind == "fix"]


def check_mac(report, machine=None, version=None):
    machine = machine or run(["sysctl", "-n", "hw.optional.arm64"]).stdout.strip()
    version = version or run(["sw_vers", "-productVersion"]).stdout.strip() or platform.mac_ver()[0]
    apple_silicon = machine in ("1", "arm64")
    if not apple_silicon:
        report.problem("Yullo needs a Mac with Apple silicon; this one has an Intel processor.")
    if major(version) < 26:
        report.problem(f"Yullo needs macOS 26 or later; this Mac has macOS {version}.",
                       "update macOS in System Settings › General › Software Update.")
    if apple_silicon and major(version) >= 26:
        report.ok(f"Apple silicon, macOS {version}")


def check_xcode(report, environment=None):
    environment = dict(os.environ if environment is None else environment)
    selected = run(["xcode-select", "-p"], env=environment)
    developer = selected.stdout.strip()
    if selected.returncode != 0 or not developer:
        report.problem("Xcode isn't set up.", f"install Xcode 26 from the App Store, then run: {SELECT_XCODE}")
        return False
    if not os.path.isdir(developer):
        report.problem(f"The selected Xcode folder {developer} doesn't exist.",
                       f"install Xcode 26 from the App Store, then run: {SELECT_XCODE}")
        return False
    if "CommandLineTools" in developer or not developer.endswith("/Contents/Developer"):
        installed = sorted(glob.glob("/Applications/Xcode*.app"))
        if installed:
            report.problem("The Command Line Tools are selected instead of Xcode.",
                           f"sudo xcode-select --switch {installed[-1] if XCODE not in installed else XCODE}")
        else:
            report.problem("Only the Command Line Tools are installed; the build needs the full Xcode.",
                           f"install Xcode 26 from the App Store, then run: {SELECT_XCODE}")
        return False
    license_state = run(["xcodebuild", "-license", "check"], env=environment)
    if license_state.returncode != 0:
        report.problem("The Xcode license hasn't been accepted.", "sudo xcodebuild -license accept")
        return False
    described = run(["xcodebuild", "-version"], env=environment)
    found = re.search(r"Xcode (\d+(?:\.\d+)*)", described.stdout)
    if not found or major(found.group(1)) < 26:
        have = f"Xcode {found.group(1)}" if found else "this Xcode"
        report.problem(f"The build needs Xcode 26 or later; {have} is selected.",
                       f"update Xcode from the App Store, then run: {SELECT_XCODE}")
        return False
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], env=environment).stdout.strip()
    if major(sdk) < 26:
        report.problem(f"The macOS 26 SDK is missing (found {sdk or 'none'}).",
                       f"update Xcode from the App Store, then run: {SELECT_XCODE}")
        return False
    if run(["xcrun", "-sdk", "macosx", "metal", "--version"], env=environment, timeout=300).returncode != 0:
        report.problem("Xcode's Metal toolchain isn't installed.", "xcodebuild -downloadComponent MetalToolchain")
        return False
    report.ok(f"Xcode {found.group(1)} at {developer[: -len('/Contents/Developer')]}")
    return True


def check_tools(report, which=shutil.which):
    if which("git") is None:
        report.problem("git is missing.", "install Xcode 26 (it includes git).")
    cmake = which("cmake")
    if cmake is None:
        if which("brew"):
            fix = "brew install cmake"
        elif os.path.isdir("/Applications/CMake.app"):
            fix = 'add it to your PATH: export PATH="/Applications/CMake.app/Contents/bin:$PATH"'
        else:
            fix = "install it from https://cmake.org/download (or, with Homebrew: brew install cmake)."
        report.problem("cmake is missing.", fix)
    else:
        found = run([cmake, "--version"]).stdout
        version = version_tuple(found.splitlines()[0] if found else "")
        if version and version < (3, 20):
            report.problem(f"cmake {'.'.join(map(str, version))} is too old; the build needs 3.20 or later.",
                           "brew upgrade cmake" if which("brew") else "install a newer one from https://cmake.org/download")
        elif version:
            report.ok(f"cmake {'.'.join(map(str, version))}")
    if sys.version_info < (3, 9):
        report.problem(f"python3 {platform.python_version()} is too old; the build needs 3.9 or later.",
                       "install Xcode 26, which includes it.")


def check_folder(report, root=ROOT):
    physical = os.path.realpath(root)
    longest = max(len(physical), len(os.path.abspath(root)))
    if longest > LONGEST_FOLDER:
        report.problem(f"This folder's path is too long for the speech runtime ({longest} characters, "
                       f"at most {LONGEST_FOLDER}).", f"move it somewhere shorter: mv {quote(root)} ~/Yullo")
    if os.geteuid() == 0:
        report.problem("This is running with sudo, but the signing key is in your own keychain.",
                       "run it again without sudo.")
    else:
        blocked = [name for name in ("build", ".runtime-source", ".runtime-build")
                   if (root / name).exists() and not os.access(root / name, os.W_OK)]
        if blocked:
            report.problem(f"{blocked[0]} in this folder belongs to another user, probably from an earlier sudo run.",
                           f'sudo chown -R "$(whoami)" {quote(root)}')
    try:
        free = shutil.disk_usage(root).free / 1e9
    except OSError:
        free = None
    if free is not None and free < NEEDED_GB:
        report.problem(f"Only {free:.1f} GB of disk space is free; the first build needs about {NEEDED_GB} GB.",
                       "free up space, then build again.")


def quote(path):
    text = str(path)
    home = str(Path.home())
    if text.startswith(home + "/") and re.fullmatch(r"[A-Za-z0-9_./-]+", text[len(home):]):
        return "~" + text[len(home):]
    return "'" + text.replace("'", "'\\''") + "'" if re.search(r"[^A-Za-z0-9_./-]", text) else text


def check_network(report, root=ROOT):
    sources = root / ".runtime-source"

    def fetched(entry):
        # An interrupted first download leaves an empty repository behind.
        return entry.is_dir() and any(child.name != ".git" for child in entry.iterdir())

    present = {prefix for prefix in PINNED_SOURCES
               for entry in (sources.iterdir() if sources.is_dir() else [])
               if entry.name.startswith(prefix) and fetched(entry)}
    if present == set(PINNED_SOURCES):
        return
    reached = run(["curl", "-fsS", "-o", "/dev/null", "-m", "10", "https://github.com"])
    if reached.returncode != 0:
        report.problem("Can't reach github.com. The first build downloads the pinned runtime sources from it.",
                       "connect to the internet, then build again.")


def signing_module(root=ROOT):
    spec = importlib.util.spec_from_file_location("yullo_signing_setup", root / "scripts/setup-signing.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_signing(report, root=ROOT, signing=None):
    signing = signing or signing_module(root)
    try:
        identity = signing.check_identity(root)
    except ValueError as error:
        message = str(error)
        # Keep "Problem. Fix: command" in one line, like every other check.
        parts = re.split(r"(?<=\.) (?:Run|Unlock it|Otherwise start again): ", message, maxsplit=1)
        if len(parts) == 2:
            report.problem(parts[0], parts[1])
        else:
            report.problem(message)
        return None
    except (OSError, subprocess.CalledProcessError):
        report.problem("Couldn't read the certificates in your keychain.", "python3 scripts/setup-signing.py --check")
        return None
    report.ok(f"Signing identity {identity[:8]}…")
    return identity


def check_installed(report, identity, installed=Path("/Applications/Yullo.app")):
    if identity is None or not installed.exists():
        return
    requirement = f'=identifier "me.yullo.app" and certificate leaf = H"{identity}"'
    same = run(["codesign", "--verify", "--test-requirement", requirement, str(installed)])
    if same.returncode != 0:
        report.note(f"{installed} is signed by another certificate, such as the release from yullo.me. "
                    "Installing your build replaces it; scripts/install-update.py explains what changes.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true", help="print only problems")
    options = parser.parse_args(argv)
    report = Report()
    check_mac(report)
    check_xcode(report)
    check_tools(report)
    check_folder(report)
    check_network(report)
    identity = check_signing(report)
    if not options.quiet:
        check_installed(report, identity)
    if not options.quiet:
        print("Checking this Mac for building Yullo:")
    for kind, text in report.lines:
        if kind == "fix":
            print(f"  ✗ {text}", file=sys.stderr if options.quiet else sys.stdout)
        elif not options.quiet:
            print(f"  {'✓' if kind == 'ok' else '•'} {text}")
    count = len(report.problems)
    if count:
        summary = "1 thing needs fixing" if count == 1 else f"{count} things need fixing"
        print(f"{summary} before building. Then run: bash build.sh",
              file=sys.stderr if options.quiet else sys.stdout)
        return 1
    if not options.quiet:
        print("Ready to build: bash build.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
