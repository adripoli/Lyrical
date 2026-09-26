#!/usr/bin/env bash
#
# package.sh — turn build/Lyrical.app into the two things a GitHub release
# actually needs: a drag-to-Applications .dmg and a .zip.
#
# Optional notarization (needs a paid Apple Developer account):
#
#   xcrun notarytool store-credentials Lyrical \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
#   DEVELOPER_ID="Developer ID Application: You (TEAMID)" \
#   NOTARY_PROFILE=Lyrical ./Scripts/package.sh
#
# The staple happens before checksums are printed, so what you upload is what
# Gatekeeper will have already approved.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
APP="$BUILD_DIR/Lyrical.app"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$1" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

if [[ ! -d "$APP" ]]; then
    info "No build/Lyrical.app yet — building"
    "$REPO_ROOT/Scripts/build-app.sh"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST_DIR/Lyrical-$VERSION.dmg"
ZIP="$DIST_DIR/Lyrical-$VERSION.zip"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# --- ZIP ---------------------------------------------------------------------
#
# ditto, not `zip`: it is the only archiver that round-trips a bundle's symlinks
# and extended attributes intact, and a mangled signature is exactly what makes
# a downloaded app "damaged".

info "Creating $(basename "$ZIP")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# --- DMG ---------------------------------------------------------------------

info "Creating $(basename "$DMG")"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/Lyrical.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Lyrical $VERSION" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

# --- Notarize ----------------------------------------------------------------

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if ! codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
        fail "NOTARY_PROFILE is set but the app is not Developer ID signed.
Rebuild with DEVELOPER_ID=\"Developer ID Application: ...\" ./Scripts/build-app.sh"
    fi

    info "Submitting to Apple for notarization (this usually takes 1-5 minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
        || fail "notarization failed — run: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"

    info "Stapling the ticket"
    xcrun stapler staple "$DMG"

    # The zip can't be stapled directly; staple the app and re-zip so both
    # artifacts open without a network round trip.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    info "Notarized and stapled"
else
    warn "Not notarized. Anyone downloading this will hit Gatekeeper and must use
      the 'Open Anyway' / xattr steps documented in the README."
fi

# --- Report ------------------------------------------------------------------

printf '\n'
info "Artifacts in dist/"
for f in "$DMG" "$ZIP"; do
    printf '  %-28s %8s  sha256:%s\n' \
        "$(basename "$f")" \
        "$(du -h "$f" | cut -f1)" \
        "$(shasum -a 256 "$f" | cut -c1-16)…"
done
