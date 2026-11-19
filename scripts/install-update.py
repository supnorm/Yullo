#!/usr/bin/env python3
"""Install a fresh verified bundle; never merge files into an existing app."""
import ctypes
import argparse
import os
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def exchange(first, second):
    """Darwin's RENAME_SWAP exchanges both directory entries atomically."""
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(first), os.fsencode(second), 0x00000002) != 0:
        failure = ctypes.get_errno()
        raise OSError(failure, os.strerror(failure), str(first), None, str(second))


def installed_executable(bundle):
    with (bundle / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    executable = info.get("CFBundleExecutable")
    if executable != "Yullo":
        raise RuntimeError(f"Unexpected executable in {bundle}")
    return bundle / "Contents/MacOS" / executable


def stop_exact_executable(executable):
    """Identify processes by the kernel's executable path, never argv or a regex."""
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.proc_listallpids.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    # Compare canonical paths even when the installation's parent is a link.
    expected = os.fsencode(Path(executable).resolve())

    def path(pid):
        buffer = ctypes.create_string_buffer(4096)
        return buffer.value if library.proc_pidpath(pid, buffer, len(buffer)) > 0 else None

    capacity = library.proc_listallpids(None, 0) + 64
    if capacity <= 64:
        raise RuntimeError("Could not enumerate running applications")
    pids = (ctypes.c_int * capacity)()
    count = library.proc_listallpids(pids, ctypes.sizeof(pids))
    if count < 0:
        raise RuntimeError("Could not enumerate running applications")
    matches = [pid for pid in pids[:min(count, capacity)] if pid > 0 and path(pid) == expected]
    for pid in matches:
        if path(pid) == expected:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 5
    while any(path(pid) == expected for pid in matches):
        if time.monotonic() >= deadline:
            raise RuntimeError("Yullo has not quit; its existing app bundle was kept intact")
        time.sleep(0.05)


def publish(source, destination, verify_release, verify_owned, stop,
            backup_parent=Path("/tmp")):
    """Stage on the destination volume, then publish or restore the original."""
    source, destination = Path(source), Path(destination)
    if source.is_symlink() or destination.is_symlink():
        raise RuntimeError("App bundle paths must not be symbolic links")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(prefix=".yullo-update-", dir=destination.parent))
    staged = stage_root / destination.name
    preserve_stage = False
    had_previous = destination.exists()
    try:
        shutil.copytree(source, staged, symlinks=True)  # Keeps Sparkle.framework's version links.
        verify_release(staged)  # Finish all preparation before stopping the app.
        if had_previous:
            verify_owned(destination)
            stop(installed_executable(destination))

        def identity(path):
            try:
                info = path.stat()
            except FileNotFoundError:
                return None
            return info.st_dev, info.st_ino

        staged_identity, destination_identity = identity(staged), identity(destination)

        def unchanged():
            try:
                return identity(staged) == staged_identity and identity(destination) == destination_identity
            except OSError:
                return False

        published = False
        try:
            # A publication call can mutate directories before raising or being
            # interrupted. Retain their owner until the result is confirmed.
            preserve_stage = True
            if had_previous:
                exchange(staged, destination)
            else:
                staged.rename(destination)
            published = True
            verify_release(destination)
        except BaseException as publication_error:
            if published:
                try:
                    if had_previous:
                        exchange(staged, destination)
                    else:
                        destination.rename(staged)
                except BaseException as rollback_error:
                    raise RuntimeError(
                        f"Could not restore the previous app. Recovery files were kept at {stage_root}"
                    ) from rollback_error
            if unchanged():
                preserve_stage = False
                raise
            raise RuntimeError(
                f"Could not confirm app publication at {destination}. Recovery files were kept at {stage_root}"
            ) from publication_error
        if had_previous:
            # Keep the old, identity-checked app recoverable after the new one passes.
            try:
                backup = Path(tempfile.mkdtemp(prefix="yullo-previous-", dir=backup_parent)) / staged.name
                shutil.move(str(staged), str(backup))
            except BaseException:
                raise RuntimeError(
                    f"Updated app is verified. Previous app could not be archived; retained at {staged}"
                )
            # Only the latest previous app is kept; each install would
            # otherwise leave another full copy behind until a restart.
            for older in Path(backup_parent).glob("yullo-previous-*"):
                if (older != backup.parent and older.is_dir() and not older.is_symlink()
                        and older.stat().st_uid == os.getuid()):
                    shutil.rmtree(older, ignore_errors=True)
            preserve_stage = False
            return backup
        preserve_stage = False
        return None
    finally:
        if not preserve_stage:
            shutil.rmtree(stage_root)


def register_application(destination):
    """Refresh only the installed app's Launch Services metadata; never launch it."""
    subprocess.run([
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f", str(destination),
    ], check=True, timeout=30)


def installation_destination(requested=None, *, home=None, system=None):
    """Keep a conventional existing installation in place; never select by argv."""
    if requested is not None:
        destination = Path(requested).expanduser()
        if not destination.is_absolute() or destination.name != "Yullo.app":
            raise ValueError("Choose an absolute path ending in Yullo.app")
        return destination
    system = Path("/Applications/Yullo.app") if system is None else Path(system)
    if os.path.lexists(system):
        # Publication still verifies identity before stopping or replacing it.
        # An unrelated or damaged entry is an error, not a reason to install a
        # second copy silently in another Applications directory.
        return system
    return (Path.home() if home is None else Path(home)) / "Applications/Yullo.app"


def signing_identity(project):
    path = project / "signing-identity.txt"
    if not path.is_file():
        raise InstallStop("Signing isn't set up in this folder yet. Run: python3 scripts/setup-signing.py --create, then bash build.sh")
    return path.read_text().strip()


def built_app(project):
    path = project / "build/Yullo.app"
    if not path.is_dir():
        raise InstallStop("There's no build to install yet. Run: bash build.sh")
    return path


class InstallStop(RuntimeError):
    """A plain message for the person installing; no traceback."""


RETURN_TO_RELEASE = "curl -fsSL https://yullo.me/install.sh | sh"


def other_build_message(destination, command):
    return "\n".join([
        f"{destination} is signed by a different certificate, most likely the release from yullo.me.",
        "Installing your own build replaces it. After that:",
        "  - macOS asks again for Microphone, Accessibility and Yullo's other permissions.",
        "    If Yullo already shows as allowed but doesn't work, reset its entries and allow them again:",
        "    tccutil reset All me.yullo.app",
        "  - API keys you saved stay in your keychain; macOS asks once before your build can use them.",
        "  - Update checks inside Yullo offer the release from yullo.me, not your build.",
        "    To update your build, run git pull and bash build.sh, then install again.",
        f"  - To go back to the release at any time: {RETURN_TO_RELEASE}",
        "To replace it with your build, run:",
        f"  {command}",
    ])


def signer(bundle):
    """The leaf certificate's SHA-1 of a signed bundle, or None."""
    result = subprocess.run(["codesign", "-d", "-r-", str(bundle)], capture_output=True, text=True)
    found = re.search(r'certificate leaf = H"([0-9a-fA-F]{40})"', result.stdout + result.stderr)
    return found.group(1).upper() if found else None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", metavar="APP_PATH", help="absolute Yullo.app path; defaults to the existing Applications installation")
    parser.add_argument("--previous-identity", metavar="SHA1",
                        help="also replace an installation signed by this earlier identity (a certificate change)")
    parser.add_argument("--replace-other-build", action="store_true",
                        help="replace a Yullo signed by another certificate, such as the release from yullo.me")
    arguments = parser.parse_args(argv)
    try:
        return install(arguments, argv)
    except InstallStop as stop:
        print(stop, file=sys.stderr)
        return 1


def install(arguments, argv):
    project = Path(__file__).resolve().parents[1]
    identity = signing_identity(project)
    if len(identity) != 40 or any(char not in "0123456789abcdefABCDEF" for char in identity):
        raise RuntimeError("Invalid signing identity fingerprint")
    source = built_app(project)
    # Yullo moved from local.yullo.app to me.yullo.app; an installed copy
    # under either identifier, signed by this identity, may be replaced.
    owned_identifiers = ("me.yullo.app", "local.yullo.app")
    accepted = [identity]
    if arguments.previous_identity:
        previous = arguments.previous_identity.strip()
        if len(previous) != 40 or any(char not in "0123456789abcdefABCDEF" for char in previous):
            raise RuntimeError("Invalid previous signing identity fingerprint")
        accepted.append(previous)
    replaced_other = []

    def verify_owned(bundle):
        with (bundle / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        identifier = info.get("CFBundleIdentifier")
        if identifier not in owned_identifiers:
            raise InstallStop(f"{bundle} isn't Yullo, so it was left as it is. Choose another --destination.")
        leaves = " or ".join(f'certificate leaf = H"{value}"' for value in accepted)
        requirement = f'=identifier "{identifier}" and ({leaves})'
        ours = subprocess.run(["codesign", "--verify", "--strict", "--test-requirement", requirement, str(bundle)],
                              capture_output=True, text=True)
        if ours.returncode == 0:
            return
        # Signed as Yullo, but by another certificate: the release, or a build made
        # with another identity. Replace it only when asked, after saying what changes.
        intact = subprocess.run(["codesign", "--verify", "--strict", "--test-requirement",
                                 f'=identifier "{identifier}"', str(bundle)], capture_output=True, text=True)
        if intact.returncode != 0:
            raise InstallStop(f"{bundle} is damaged or not properly signed, so it was left as it is. "
                              "Move it to the Trash, then install again.")
        if not arguments.replace_other_build:
            given = list(sys.argv[1:] if argv is None else argv)
            command = " ".join(["python3", "scripts/install-update.py"] + [shlex.quote(item) for item in given]
                               + ["--replace-other-build"])
            raise InstallStop(other_build_message(bundle, command))
        if not replaced_other:
            replaced_other.append(signer(bundle))

    def verify_release(bundle):
        subprocess.run([sys.executable, str(project / "scripts/check-release.py"), str(bundle)], check=True)

    try:
        destination = installation_destination(arguments.destination)
    except ValueError as error:
        raise InstallStop(f"{error}, for example /Applications/Yullo.app.") from None
    parent = destination.parent
    while not parent.exists() and parent != parent.parent:
        parent = parent.parent
    if not os.access(parent, os.W_OK) or (destination.exists() and not os.access(destination.parent, os.W_OK)):
        raise InstallStop(f"You can't write to {destination.parent}. Sign in as an administrator, "
                          "or install into your own Applications folder: "
                          "python3 scripts/install-update.py --destination ~/Applications/Yullo.app")
    if destination.exists() and not destination.is_symlink():
        verify_owned(destination)  # Explain a replacement before copying or auditing anything.
    backup = publish(source, destination, verify_release, verify_owned, stop_exact_executable)
    try:
        register_application(destination)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Yullo installed but registration could not be confirmed: {destination}", file=sys.stderr)
        print(f"Registration error: {error}", file=sys.stderr)
        if backup is not None:
            print(f"Previous app retained for recovery: {backup}", file=sys.stderr)
        return 1
    print(f"Installed Yullo: {destination}")
    if backup is not None:
        print(f"Previous app retained for recovery: {backup}")
    if replaced_other:
        print("Open Yullo and allow its permissions again when asked. If one stays off: tccutil reset All me.yullo.app")
        print(f"To go back to the release: {RETURN_TO_RELEASE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
