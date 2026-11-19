#!/bin/sh
# Installs the latest Yullo into /Applications.
#
#   curl -fsSL https://yullo.me/install.sh | sh
#
# It downloads Yullo.dmg from the project's GitHub releases, checks it against
# its published SHA-256, checks that Yullo.app inside is signed by Yullo's own
# certificate, copies it into /Applications and cleans up.
# No sudo, and no system settings are changed.

set -eu

release="https://github.com/supnorm/Yullo/releases/latest/download"
app="/Applications/Yullo.app"
# Yullo's signing certificates, by SHA-1. A download signed by anything else is refused.
signed_by='=identifier "me.yullo.app" and (certificate leaf = H"29662f3c112f7660aefab77aee703e685c02b100" or certificate leaf = H"cfc61cc930ad336a0b2fdfca66ec77046e8bb7f9")'

fail() {
  echo "$1" >&2
  exit 1
}

main() {
  [ "$(uname -s)" = Darwin ] || fail "Yullo runs on macOS."
  [ "$(uname -m)" = arm64 ] || fail "Yullo needs a Mac with Apple silicon."
  version=$(sw_vers -productVersion)
  [ "${version%%.*}" -ge 26 ] || fail "Yullo needs macOS 26 or later. This Mac has macOS $version."
  [ -w /Applications ] || fail "Can't write to /Applications. Sign in as an administrator and try again."

  tmp=$(mktemp -d)
  mount="$tmp/mount"
  trap 'hdiutil detach -quiet "$mount" 2>/dev/null; rm -rf "$tmp"' EXIT
  trap 'exit 1' HUP INT TERM

  curl -fsSL -o "$tmp/Yullo.dmg" "$release/Yullo.dmg"
  curl -fsSL -o "$tmp/Yullo.dmg.sha256" "$release/Yullo.dmg.sha256"

  expected=$(awk '{ print $1; exit }' "$tmp/Yullo.dmg.sha256")
  actual=$(shasum -a 256 "$tmp/Yullo.dmg" | awk '{ print $1 }')
  [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
    fail "The download doesn't match its checksum. Nothing was installed."

  mkdir "$mount"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$tmp/Yullo.dmg" </dev/null
  [ -d "$mount/Yullo.app" ] || fail "Yullo.app is missing from the download. Nothing was installed."
  ditto "$mount/Yullo.app" "$tmp/Yullo.app"
  codesign --verify --strict --deep --test-requirement "$signed_by" "$tmp/Yullo.app" 2>/dev/null ||
    fail "The download isn't signed by Yullo. Nothing was installed."

  # Ask a running Yullo to quit, and wait up to ten seconds for it.
  if pgrep -xq Yullo; then
    osascript -e 'quit app "Yullo"' >/dev/null 2>&1 || true
    tries=0
    while pgrep -xq Yullo; do
      tries=$((tries + 1))
      [ "$tries" -le 20 ] || fail "Yullo is still open. Quit it, then run this again."
      sleep 0.5
    done
  fi

  # Move the old app aside, and put it back if the new one can't go in.
  # The temp folder, and the old copy with it, is removed on exit.
  if [ -e "$app" ]; then
    mv "$app" "$tmp/Yullo-previous.app" || fail "Couldn't replace Yullo. Your current version is unchanged."
  fi
  if ! mv "$tmp/Yullo.app" "$app"; then
    [ -e "$tmp/Yullo-previous.app" ] && mv "$tmp/Yullo-previous.app" "$app"
    fail "Couldn't replace Yullo. Your current version is unchanged."
  fi
  echo "Yullo is in Applications."
}

main "$@"
