#!/usr/bin/env python3
"""Package and verify a signed Yullo app without changing its installation."""
import argparse
import hashlib
import ctypes
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run(*arguments, capture=False):
    return subprocess.run([str(argument) for argument in arguments], check=True,
                          stdout=subprocess.PIPE if capture else None)


def exchange(first, second):
    """Swap two directories on the same macOS volume in one operation."""
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(first), os.fsencode(second), 0x00000002) != 0:
        failure = ctypes.get_errno()
        raise OSError(failure, os.strerror(failure), str(first), None, str(second))


def publish_installer(staged, destination, swap=exchange):
    """Publish the image and checksum together, retaining the previous pair."""
    if staged.is_symlink() or destination.is_symlink():
        raise RuntimeError("Installer directories must not be symbolic links")
    if not staged.is_dir() or (destination.exists() and not destination.is_dir()):
        raise RuntimeError("Invalid installer directory")
    if destination.exists():
        swap(staged, destination)  # The previous pair remains at staged until cleanup.
    else:
        staged.replace(destination)


def require_bundle_root(app):
    if app.is_symlink() or not app.is_dir():
        raise RuntimeError(f"App bundle must be a regular directory: {app}")


def device_nodes(entities):
    if not isinstance(entities, list):
        raise RuntimeError("Image device information is unavailable")
    nodes = {entry.get("dev-entry") for entry in entities if isinstance(entry, dict)
             and isinstance(entry.get("dev-entry"), str)
             and re.fullmatch(r"/dev/disk[0-9]+(?:s[0-9]+)*", entry["dev-entry"])}
    if not nodes:
        raise RuntimeError("Image device information is unavailable")
    roots = {node for node in nodes if re.fullmatch(r"/dev/disk[0-9]+", node)}
    return roots or nodes


class ImageAttachment:
    """Only detach devices currently owned by this exact temporary image."""
    def __init__(self, image, mount, runner=run, is_mounted=lambda path: path.is_mount()):
        self.image, self.mount = image, mount
        self.runner, self.is_mounted = runner, is_mounted
        self.pending = False
        self.attached_devices = set()

    def attach(self):
        self.pending = True  # A failed command may still have allocated a device.
        result = self.runner("hdiutil", "attach", "-plist", "-readonly", "-nobrowse",
                             "-noautoopen", "-noautoopenro", "-mountpoint", self.mount,
                             self.image, capture=True)
        data = plistlib.loads(result.stdout)
        entities = data.get("system-entities") if isinstance(data, dict) else None
        self.attached_devices = device_nodes(entities)
        if not any(isinstance(entry, dict) and entry.get("mount-point") == str(self.mount)
                   for entry in entities) or not self.is_mounted(self.mount):
            raise RuntimeError("Installer image did not mount at its staging directory")

    def owned_devices(self):
        result = self.runner("hdiutil", "info", "-plist", capture=True)
        data = plistlib.loads(result.stdout)
        if not isinstance(data, dict) or not isinstance(data.get("images"), list):
            raise RuntimeError("Cannot confirm installer image device ownership")
        nodes = set()
        for image in data["images"]:
            if not isinstance(image, dict) or not isinstance(image.get("image-path"), str):
                raise RuntimeError("Cannot confirm installer image device ownership")
            if Path(image["image-path"]).resolve() == self.image.resolve():
                nodes.update(device_nodes(image.get("system-entities")))
        return nodes

    def detach(self):
        for device in sorted(self.owned_devices()):
            # Detaching a partition may remove the whole image. Do not act on
            # another snapshot node after its ownership has changed.
            if device in self.owned_devices():
                self.runner("hdiutil", "detach", device)
        if self.owned_devices() or self.is_mounted(self.mount):
            raise RuntimeError("Installer image is still attached or mounted")
        self.pending = False
        self.attached_devices.clear()

    def cleanup(self):
        if self.pending:
            try:
                self.detach()
            except Exception as error:
                print(f"Installer staging retained; device cleanup is incomplete: {error}", file=sys.stderr)
                return False
        return not self.is_mounted(self.mount)


def file_hashes(directory):
    return {
        str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in directory.rglob("*") if path.is_file()
    }


def validate_mounted_contents(project, mount, app, runner=run):
    entries = {path.name for path in mount.iterdir() if not path.name.startswith(".")}
    if entries != {"Yullo.app", "Applications"}:
        raise RuntimeError("Unexpected files in installer image")
    shortcut = mount / "Applications"
    if not shortcut.is_symlink() or os.readlink(shortcut) != "/Applications":
        raise RuntimeError("Invalid Applications shortcut")
    require_bundle_root(mount / "Yullo.app")
    runner(sys.executable, project / "scripts/check-release.py", mount / "Yullo.app")
    if file_hashes(app) != file_hashes(mount / "Yullo.app"):
        raise RuntimeError("Installer app does not match the verified release")


def verify_existing(project, image, app, runner=run, is_mounted=lambda path: path.is_mount()):
    """Verify an existing image against one app, without publishing."""
    if image.is_symlink() or not image.is_file():
        raise RuntimeError("Installer image must be a regular file")
    require_bundle_root(app)
    identity = (project / "signing-identity.txt").read_text().strip()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", identity):
        raise RuntimeError("Invalid signing identity fingerprint")
    requirement = f'=identifier "local.yullo.installer" and certificate leaf = H"{identity}"'
    stage = Path(tempfile.mkdtemp(prefix=".yullo-image-audit-", dir=project / "build"))
    mount = stage / "mount"
    private_image = stage / "image.dmg"
    attachment = ImageAttachment(private_image, mount, runner, is_mounted)
    try:
        # A fresh backing path cannot borrow a device from an image the user
        # already mounted. Keep this copy if device cleanup becomes uncertain.
        original_hash = hashlib.sha256(image.read_bytes()).hexdigest()
        shutil.copyfile(image, private_image)
        if (hashlib.sha256(private_image.read_bytes()).hexdigest() != original_hash
                or hashlib.sha256(image.read_bytes()).hexdigest() != original_hash):
            raise RuntimeError("Installer image changed while preparing verification")
        runner("codesign", "--verify", "--strict", "--test-requirement", requirement, private_image)
        runner("hdiutil", "verify", private_image)
        mount.mkdir()
        attachment.attach()
        validate_mounted_contents(project, mount, app, runner)
        attachment.detach()
        if hashlib.sha256(image.read_bytes()).hexdigest() != original_hash:
            raise RuntimeError("Installer image changed during verification")
    finally:
        if attachment.cleanup():
            shutil.rmtree(stage)
        else:
            print(f"Installer verification mount retained for recovery: {stage}", file=sys.stderr)
            raise RuntimeError("Installer verification cleanup is incomplete; backing image was preserved")


def package(project, runner=run, is_mounted=lambda path: path.is_mount()):
    app = project / "build/Yullo.app"
    audit = project / "scripts/check-release.py"
    require_bundle_root(app)
    runner(sys.executable, audit, app)
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise RuntimeError("Invalid release version")
    identity = (project / "signing-identity.txt").read_text().strip()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", identity):
        raise RuntimeError("Invalid signing identity fingerprint")

    output = project / "build/Installer"
    if output.is_symlink():
        raise RuntimeError("Installer directories must not be symbolic links")
    stage = Path(tempfile.mkdtemp(prefix=".yullo-dmg-", dir=output.parent))
    mount = stage / "mount"
    installer = stage / "Installer"
    image = installer / f"Yullo-{version}.dmg"
    attachment = ImageAttachment(image, mount, runner, is_mounted)
    preserve_stage = False
    try:
        installer.mkdir()
        payload = stage / "payload"
        payload.mkdir()
        shutil.copytree(app, payload / "Yullo.app", symlinks=True)  # Keeps Sparkle.framework's version links.
        (payload / "Applications").symlink_to("/Applications", target_is_directory=True)
        runner("hdiutil", "create", "-volname", "Yullo", "-srcfolder", payload,
            "-fs", "HFS+", "-format", "UDZO", "-imagekey", "zlib-level=9", image)
        runner("codesign", "--force", "--sign", identity, "--timestamp=none",
            "--identifier", "local.yullo.installer", image)
        requirement = f'=identifier "local.yullo.installer" and certificate leaf = H"{identity}"'
        runner("codesign", "--verify", "--strict", "--test-requirement", requirement, image)
        runner("hdiutil", "verify", image)

        mount.mkdir()
        attachment.attach()
        validate_mounted_contents(project, mount, app, runner)
        attachment.detach()

        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        checksum = installer / (image.name + ".sha256")
        checksum.write_text(f"{digest}  {image.name}\n")
        # Publish only after the mounted app, signature and image checksum pass.
        preserve_stage = True  # A raised publication call may already have swapped.
        publish_installer(installer, output)
        if installer.exists():
            # Swap left the previous pair here. Preserve its backing inode even
            # if a user mounted it before or during publication.
            try:
                previous = Path(tempfile.mkdtemp(prefix=".yullo-previous-installer-", dir=output.parent)) / "Installer"
                installer.rename(previous)
            except BaseException as error:
                raise RuntimeError(
                    "New installer is verified and published. "
                    f"Previous installer could not be archived; retained at {installer}"
                ) from error
            print(f"Previous installer retained for recovery: {previous}")
        preserve_stage = False
        print(f"Verified installer: {output / image.name}")
        print(f"SHA-256: {digest}")
        return output
    finally:
        if attachment.cleanup() and not preserve_stage:
            shutil.rmtree(stage)
        else:
            # Keep an attached backing image or an unarchived previous pair.
            print(f"Installer staging retained for recovery: {stage}", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv)
    package(Path(__file__).resolve().parents[1])


if __name__ == "__main__":
    main()
