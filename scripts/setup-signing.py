#!/usr/bin/env python3
"""Set up the certificate this folder signs Yullo with. The key stays in your keychain."""

import argparse
import ctypes
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Only new identities use this label; configured fingerprints remain authoritative.
NAME = "Yullo"
LOGIN_KEYCHAIN = Path.home() / "Library/Keychains/login.keychain-db"
# The keychain to create or look up identities in. Unset means the login keychain
# for --create and the user's keychain search list otherwise.
KEYCHAIN_VARIABLE = "YULLO_KEYCHAIN"
# Its password, for a keychain made only for signing (tests, build machines).
PASSWORD_VARIABLE = "YULLO_KEYCHAIN_PASSWORD"
CREATE_COMMAND = "python3 scripts/setup-signing.py --create"


def fingerprint(value):
    value = value.strip().upper()
    if not re.fullmatch(r"[0-9A-F]{40}", value):
        raise ValueError("Use the 40-character SHA-1 signing certificate fingerprint.")
    return value


def chosen_keychain():
    value = os.environ.get(KEYCHAIN_VARIABLE, "").strip()
    return Path(value).expanduser() if value else None


def readable(path):
    """A path as people type it: ~ for the home folder, quoted only when needed."""
    text = str(path)
    home = str(Path.home())
    rest = text[len(home):]
    if text.startswith(home + "/") and re.fullmatch(r"[A-Za-z0-9_./-]+", rest):
        return "~" + rest
    return shlex.quote(text)


def unlock_command(keychain):
    return f"security unlock-keychain {readable(keychain)}"


def identity_list(keychain=None):
    """Fingerprint -> name of every certificate with its private key usable for code signing.

    Self-signed identities are listed as not trusted; that is expected and the
    build does not need them trusted, since it pins the exact certificate.
    """
    command = ["security", "find-identity", "-p", "codesigning"]
    keychain = keychain or chosen_keychain()
    if keychain is not None:
        command.append(str(keychain))
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    found = {}
    for value, name in re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"', result.stdout, re.MULTILINE):
        found.setdefault(value.upper(), name)
    return found


def available_identities():
    return set(identity_list())


def certificate_keychains(keychain=None):
    """SHA-1 fingerprint -> the keychain file each certificate is stored in."""
    command = ["security", "find-certificate", "-a", "-Z"]
    keychain = keychain or chosen_keychain()
    if keychain is not None:
        command.append(str(keychain))
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode not in (0, 44):
        return {}
    found, current = {}, None
    for line in result.stdout.splitlines():
        hashed = re.match(r"SHA-1 hash: ([0-9A-Fa-f]{40})", line)
        if hashed:
            current = hashed.group(1).upper()
        stored = re.match(r'keychain: "(.*)"', line)
        if stored and current:
            found.setdefault(current, Path(stored.group(1)))
    return found


def keychain_locked(path):
    """True when the keychain is locked, None when it can't be read. Never prompts."""
    try:
        security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        foundation = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError:
        return None
    security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    security.SecKeychainGetStatus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    foundation.CFRelease.argtypes = [ctypes.c_void_p]
    keychain = ctypes.c_void_p()
    if security.SecKeychainOpen(os.fsencode(str(path)), ctypes.byref(keychain)) != 0 or not keychain:
        return None
    try:
        status = ctypes.c_uint32()
        if security.SecKeychainGetStatus(keychain, ctypes.byref(status)) != 0:
            return None
        return not status.value & 1  # kSecUnlockStateStatus
    finally:
        foundation.CFRelease(keychain)


def require_unlocked(keychain, unlock=False):
    """A locked keychain makes macOS wait on a password window during the build."""
    if keychain_locked(keychain) is not True:
        return
    password = os.environ.get(PASSWORD_VARIABLE)
    if password and chosen_keychain() is not None and Path(keychain) == chosen_keychain():
        if subprocess.run(["security", "unlock-keychain", "-p", password, str(keychain)],
                          capture_output=True).returncode == 0:
            return
    if unlock and sys.stdin.isatty():
        print(f"Your keychain {readable(keychain)} is locked. Type your Mac login password to unlock it.")
        if subprocess.run(["security", "unlock-keychain", str(keychain)]).returncode == 0:
            return
    raise ValueError(f"Your keychain is locked, so macOS can't use the signing key. Unlock it: {unlock_command(keychain)}")


def check_identity(root=ROOT):
    path = root / "signing-identity.txt"
    if path.is_symlink():
        raise ValueError("signing-identity.txt must be a plain file in this folder.")
    if not path.is_file():
        raise ValueError(f"Signing isn't set up in this folder yet. Run: {CREATE_COMMAND}")
    identity = fingerprint(path.read_text())
    if identity not in available_identities():
        keychain = chosen_keychain() or LOGIN_KEYCHAIN
        if keychain_locked(keychain):
            raise ValueError(f"Your keychain is locked, so the signing identity can't be found. Unlock it: {unlock_command(keychain)}")
        raise ValueError(
            f"The signing identity this folder uses ({identity[:8]}…) is no longer in your keychain. "
            f"If you can, restore it. Otherwise start again: rm signing-identity.txt && {CREATE_COMMAND}")
    stored = certificate_keychains().get(identity)
    if stored is not None:
        require_unlocked(stored)
    return identity


def configure_identity(identity, root=ROOT):
    identity = fingerprint(identity)
    path = root / "signing-identity.txt"
    if path.is_symlink():
        raise ValueError("signing-identity.txt must be a plain file in this folder.")
    if path.exists():
        if fingerprint(path.read_text()) != identity:
            raise ValueError("This folder already signs with a different identity, and it was kept. "
                             "To change it, delete signing-identity.txt first.")
        return check_identity(root)
    if identity not in available_identities():
        listed = "; ".join(f'{value} "{name}"' for value, name in sorted(identity_list().items()))
        raise ValueError("That certificate isn't on this Mac with its private key, so it can't sign code. "
                         + (f"Certificates that can: {listed}" if listed else f"To make one, run: {CREATE_COMMAND}"))
    with path.open("x") as output:
        output.write(identity + "\n")
    return identity


def openssl():
    # macOS's own LibreSSL writes a PKCS#12 that `security import` reads; prefer it
    # over whichever OpenSSL a package manager put first on PATH.
    return "/usr/bin/openssl" if os.access("/usr/bin/openssl", os.X_OK) else (shutil.which("openssl") or "openssl")


def import_failure(stderr, keychain):
    text = stderr.strip()
    if "User interaction is not allowed" in text or "-25308" in text:
        return f"Your keychain is locked. Unlock it, then run this again: {unlock_command(keychain)}"
    if "canceled" in text.lower() or "-128" in text:
        return "The keychain window was closed without allowing it. Run this again and enter your Mac login password when asked."
    if "-25294" in text or "could not be found" in text:
        return f"The keychain {readable(keychain)} doesn't exist."
    last = text.splitlines()[-1] if text else "no details"
    return f"macOS couldn't add the signing identity to your keychain ({last})."


def test_signature(identity, keychain):
    """Sign a scratch copy of a system tool once, so a keychain question comes now, not mid-build."""
    with tempfile.TemporaryDirectory(prefix="yullo-signing-check-") as folder:
        probe = Path(folder) / "probe"
        shutil.copyfile("/usr/bin/true", probe)
        os.chmod(probe, 0o755)
        command = ["codesign", "--force", "--sign", identity, "--timestamp=none"]
        if keychain is not None:
            command += ["--keychain", str(keychain)]
        result = subprocess.run(command + [str(probe)], capture_output=True, text=True)
        if result.returncode != 0:
            raise ValueError(
                "The identity was created, but macOS didn't let codesign use it. "
                "If a keychain window asked, run this again and choose Always Allow. "
                f"Over SSH, unlock first: {unlock_command(keychain or LOGIN_KEYCHAIN)}")


def create_identity(root=ROOT, name=NAME):
    """Configure an identity: the one already set up, one an earlier setup made, or a new one."""
    path = root / "signing-identity.txt"
    if os.path.lexists(path):
        return check_identity(root), "configured"
    keychain = chosen_keychain()
    existing = subprocess.run(
        ["security", "find-certificate", "-a", "-c", name] + ([str(keychain)] if keychain else []),
        capture_output=True, text=True,
    )
    if existing.returncode not in (0, 44):
        raise ValueError("Couldn't read the certificates in your keychain.")
    # -c matches any name containing this one; only an exact label is ours.
    if f'"labl"<blob>="{name}"' in existing.stdout:
        # An earlier setup, for example in a previous copy of this folder, made it.
        # Reuse it, so an installed build keeps the same signature.
        matches = [value for value, label in identity_list().items() if label == name]
        if len(matches) == 1:
            return configure_identity(matches[0], root), "reused"
        if not matches:
            keychain_in_use = keychain or LOGIN_KEYCHAIN
            if keychain_locked(keychain_in_use):
                raise ValueError(f"Your keychain is locked. Unlock it, then run this again: {unlock_command(keychain_in_use)}")
            raise ValueError(f'A certificate named "{name}" is in your keychain without its private key. '
                             f'Make a new one under another name: {CREATE_COMMAND} --name "{name} 2"')
        listed = ", ".join(matches)
        raise ValueError(f'Several signing identities are named "{name}". Pick one: '
                         f"python3 scripts/setup-signing.py --identity <fingerprint> (one of {listed})")
    target = keychain or LOGIN_KEYCHAIN
    require_unlocked(target, unlock=True)
    with tempfile.TemporaryDirectory(prefix="yullo-signing-") as folder:
        work = Path(folder)
        (work / "cert.cnf").write_text(f"""[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN={name}
[ext]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
""")
        tool = openssl()
        subprocess.run(
            [tool, "req", "-new", "-newkey", "rsa:3072", "-x509", "-sha256", "-days", "3650", "-nodes",
             "-config", str(work / "cert.cnf"), "-keyout", str(work / "key.pem"), "-out", str(work / "cert.pem")],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        os.chmod(work / "key.pem", 0o600)
        password = secrets.token_urlsafe(32)
        environment = dict(os.environ, YULLO_P12_PASSWORD=password)
        # macOS `security import` reads only SHA-1 MAC / 3DES PKCS#12; OpenSSL 3
        # defaults to AES with a SHA-256 MAC, which it rejects as a wrong password.
        subprocess.run(
            [tool, "pkcs12", "-export", "-inkey", str(work / "key.pem"), "-in", str(work / "cert.pem"),
             "-name", name, "-out", str(work / "identity.p12"), "-passout", "env:YULLO_P12_PASSWORD",
             "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
            env=environment, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        imported = subprocess.run(
            ["security", "import", str(work / "identity.p12"), "-k", str(target), "-P", password, "-T", "/usr/bin/codesign"],
            capture_output=True, text=True,
        )
        if imported.returncode != 0:
            raise ValueError(import_failure(imported.stderr, target))
        value = subprocess.check_output(
            [tool, "x509", "-in", str(work / "cert.pem"), "-noout", "-fingerprint", "-sha1"], text=True,
        ).strip().split("=", 1)[1].replace(":", "")
    password = os.environ.get(PASSWORD_VARIABLE)
    if keychain is not None and password:
        # Let Apple's tools use the key without asking, so signing never shows a window.
        subprocess.run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
                        "-k", password, str(keychain)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    identity = configure_identity(value, root)
    test_signature(identity, keychain)
    return identity, "created"


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog=f"Set {KEYCHAIN_VARIABLE}=/path/to/file.keychain-db to keep the identity in another keychain; "
               f"bash build.sh then signs from that keychain too. With {PASSWORD_VARIABLE}, both unlock it "
               "without asking.")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true", help="check the identity this folder uses, changing nothing")
    action.add_argument("--identity", metavar="SHA1", help="use a code-signing certificate you already have")
    action.add_argument("--create", action="store_true",
                        help="make a certificate on this Mac (or reuse the one an earlier setup made)")
    parser.add_argument("--name", default=NAME, help=f"certificate name for --create (default: {NAME})")
    options = parser.parse_args()
    note = ("macOS lists this certificate as not trusted. That's expected for one made on this Mac; "
            "the build doesn't need it trusted.")
    try:
        if options.check:
            identity = check_identity()
            print(f"Signing is set up: {identity}.")
        elif options.identity:
            identity = configure_identity(options.identity)
            print(f"This folder now signs with {identity}.")
        else:
            identity, how = create_identity(name=options.name)
            if how == "configured":
                print(f"Signing is already set up: {identity}. Next: bash build.sh")
            elif how == "reused":
                print(f'Using the "{options.name}" certificate an earlier setup made: {identity}. Next: bash build.sh')
            else:
                print(f'Made the "{options.name}" signing certificate in your keychain: {identity}. Next: bash build.sh')
                print(note)
    except subprocess.CalledProcessError as error:
        # An explicit import command carries a one-use archive password. Never
        # echo its argv when reporting a failed command.
        output = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
        detail = output.strip().splitlines()
        reason = f": {detail[-1]}" if detail else ""
        parser.exit(1, f"Signing setup: a {Path(str(error.cmd[0])).name} step failed (exit {error.returncode}){reason}.\n")
    except (ValueError, OSError) as error:
        parser.exit(1, f"Signing setup: {error}\n")


if __name__ == "__main__":
    main()
