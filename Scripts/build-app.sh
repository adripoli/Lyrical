#!/usr/bin/env bash
#
# build-app.sh — produce build/Lyrical.app from a clean checkout.
#
# No Xcode UI involved: this is the same path CI takes, so "it builds on my
# machine" and "it builds in the release workflow" are the same claim.
#
# Signing:
#   unset DEVELOPER_ID  -> ad-hoc ("Sign to Run Locally"). Runs fine on the
#                          machine that built it; Gatekeeper will quarantine it
#                          if it travels over the internet.
#   DEVELOPER_ID="Developer ID Application: You (TEAMID)"
#                       -> real signature + Hardened Runtime, which is the only
#                          combination `notarytool` accepts.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_OUT="$BUILD_DIR/Lyrical.app"
CONFIGURATION="${CONFIGURATION:-Release}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------

command -v xcodebuild >/dev/null 2>&1 \
    || fail "xcodebuild not found. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"

if ! xcodebuild -version >/dev/null 2>&1; then
    fail "xcodebuild is present but not usable — you may have only the Command Line Tools selected. Run: sudo xcode-select -s /Applications/Xcode.app"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    fail "xcodegen not found. Install it with: brew install xcodegen
(Lyrical.xcodeproj is generated from project.yml and deliberately not committed.)"
fi

# --- Generate + build --------------------------------------------------------

info "Generating Lyrical.xcodeproj from project.yml"
xcodegen generate --quiet

# The icon is committed, but regenerate it if someone deleted it rather than
# shipping a bundle with a blank generic document icon.
if [[ ! -f "$REPO_ROOT/Lyrical/Resources/Lyrical.icns" ]]; then
    info "Icon missing — regenerating"
    "$REPO_ROOT/Scripts/make-icon.swift"
fi

SIGN_ARGS=()
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    info "Building $CONFIGURATION, signing as: $DEVELOPER_ID"
    SIGN_ARGS=(
        CODE_SIGN_IDENTITY="$DEVELOPER_ID"
        CODE_SIGN_STYLE=Manual
        ENABLE_HARDENED_RUNTIME=YES
        OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
    )
    [[ -n "${DEVELOPMENT_TEAM:-}" ]] && SIGN_ARGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
else
    info "Building $CONFIGURATION, ad-hoc signed (set DEVELOPER_ID to sign for distribution)"
    SIGN_ARGS=(
        CODE_SIGN_IDENTITY="-"
        CODE_SIGN_STYLE=Manual
        DEVELOPMENT_TEAM=""
    )
fi

rm -rf "$APP_OUT"
mkdir -p "$BUILD_DIR"

# xcpretty if it happens to be around, raw log otherwise — never a hard dep.
BUILD_LOG="$BUILD_DIR/xcodebuild.log"
set +e
xcodebuild \
    -project Lyrical.xcodeproj \
    -scheme Lyrical \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    "${SIGN_ARGS[@]}" \
    build > "$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

if [[ $BUILD_STATUS -ne 0 ]]; then
    printf '\n'
    grep -E "(error|warning):" "$BUILD_LOG" | head -40 || tail -40 "$BUILD_LOG"
    fail "build failed — full log at $BUILD_LOG"
fi

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/Lyrical.app"
[[ -d "$BUILT_APP" ]] || fail "build reported success but $BUILT_APP is missing"

cp -R "$BUILT_APP" "$APP_OUT"

# --- Verify ------------------------------------------------------------------

codesign --verify --deep --strict "$APP_OUT" \
    || fail "code signature on $APP_OUT did not verify"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_OUT/Contents/Info.plist")"

info "Built Lyrical $VERSION -> $APP_OUT"
codesign -dv "$APP_OUT" 2>&1 | grep -E '^(Authority|Signature|TeamIdentifier)' || true
