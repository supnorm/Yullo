#!/usr/bin/env python3
"""Configure this checkout's signing identity; credentials never enter source exports."""

import argparse
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Only new identities use this label; configured fingerprints remain authoritative.
NAME = "Yullo"


def fingerprint(value):
    value = value.strip().upper()
    if not re.fullmatch(r"[0-9A-F]{40}", value):
        raise ValueError("Use the 40-character SHA-1 signing certificate fingerprint.")
    return value


def available_identities():
    # Match certificate/private-key pairs, including local self-signed identities.
    # Trust for distribution is separate; the build still signs and audits the leaf.
    result = subprocess.run(
        ["security", "find-identity", "-p", "codesigning"],
        check=True, capture_output=True, text=True,
    )
    return set(re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"', result.stdout, re.MULTILINE))


def check_identity(root=ROOT):
    path = root / "signing-identity.txt"
    if not path.is_file() or path.is_symlink():
        raise ValueError("Configure signing first: python3 scripts/setup-signing.py --identity CERTIFICATE_SHA1")
    identity = fingerprint(path.read_text())
    if identity not in {item.upper() for item in available_identities()}:
        raise ValueError("The configured signing identity is unavailable. Restore its certificate/private key; do not replace an existing app's identity.")
    return identity


def configure_identity(identity, root=ROOT):
    identity = fingerprint(identity)
    path = root / "signing-identity.txt"
    if path.is_symlink():
        raise ValueError("Signing configuration must be a local regular file.")
    if path.exists():
        if fingerprint(path.read_text()) != identity:
            raise ValueError("A different signing identity is already configured; existing configuration was preserved.")
        return check_identity(root)
    if identity not in {item.upper() for item in available_identities()}:
        raise ValueError("This certificate and its private key are not available for code signing on this Mac.")
    with path.open("x") as output:
        output.write(identity + "\n")
    return identity


def create_identity(root=ROOT, name=NAME):
    if os.path.lexists(root / "signing-identity.txt"):
        raise ValueError("Signing is already configured. Use --check; existing identities are not replaced.")
    existing = subprocess.run(
        ["security", "find-certificate", "-a", "-c", name], capture_output=True, text=True,
    )
    if existing.returncode not in (0, 44):
        raise ValueError("Could not inspect the local signing certificates.")
    # -c matches any name containing this one; only an exact label conflicts.
    if f'"labl"<blob>="{name}"' in existing.stdout:
        raise ValueError("The local certificate already exists. Use --identity with its fingerprint instead of creating another.")
    keychain = str(Path.home() / "Library/Keychains/login.keychain-db")
    with tempfile.TemporaryDirectory(prefix="yullo-signing-") as folder:
        path = Path(folder)
        (path / "cert.cnf").write_text(f"""[req]
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
        subprocess.run(
            ["openssl", "req", "-new", "-newkey", "rsa:3072", "-x509", "-sha256", "-days", "3650", "-nodes",
             "-config", str(path / "cert.cnf"), "-keyout", str(path / "key.pem"), "-out", str(path / "cert.pem")],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        os.chmod(path / "key.pem", 0o600)
        password = secrets.token_urlsafe(32)
        environment = dict(os.environ, YULLO_P12_PASSWORD=password)
        # macOS `security import` reads only SHA-1 MAC / 3DES PKCS#12; OpenSSL 3
        # defaults to AES with a SHA-256 MAC, which it rejects as a wrong password.
        subprocess.run(
            ["openssl", "pkcs12", "-export", "-inkey", str(path / "key.pem"), "-in", str(path / "cert.pem"),
             "-name", name, "-out", str(path / "identity.p12"), "-passout", "env:YULLO_P12_PASSWORD",
             "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
            env=environment, check=True,
        )
        subprocess.run(
            ["security", "import", str(path / "identity.p12"), "-k", keychain, "-P", password, "-T", "/usr/bin/codesign"],
            check=True,
        )
        value = subprocess.check_output(
            ["openssl", "x509", "-in", str(path / "cert.pem"), "-noout", "-fingerprint", "-sha1"], text=True,
        ).strip().split("=", 1)[1].replace(":", "")
        return configure_identity(value, root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true", help="verify existing local configuration without importing or signing")
    action.add_argument("--identity", metavar="SHA1", help="use an existing code-signing identity on this Mac")
    action.add_argument("--create", action="store_true", help="explicitly create/import a new local identity; macOS may request authorization")
    parser.add_argument("--name", default=NAME, help=f"certificate name for --create (default: {NAME})")
    options = parser.parse_args()
    try:
        if options.check:
            check_identity()
            print("Configured signing identity is available.")
        elif options.identity:
            configure_identity(options.identity)
            print("Local signing identity configured; no private key was exported.")
        else:
            create_identity(name=options.name)
            print("Local signing identity created in Keychain; temporary key files removed.")
    except subprocess.CalledProcessError as error:
        # An explicit import command carries a one-use archive password. Never
        # echo its argv when reporting a failed command.
        parser.exit(1, f"Signing setup command failed (exit {error.returncode}).\n")
    except (ValueError, OSError) as error:
        parser.exit(1, f"Signing setup: {error}\n")


if __name__ == "__main__":
    main()
