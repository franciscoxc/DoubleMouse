#!/bin/bash
set -euo pipefail

VERSION="${1:-1.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT/.build/release-package"
BUILD_DIR="$PACKAGE_DIR/swift-build"
APP="$PACKAGE_DIR/DoubleMouse.app"
RW_DMG="$PACKAGE_DIR/DoubleMouse-rw.dmg"
MOUNT="$PACKAGE_DIR/mount"
DIST="$ROOT/dist"
DMG="$DIST/DoubleMouse-$VERSION.dmg"

rm -rf "$PACKAGE_DIR"
MOUNTED=0
cleanup() {
    if [[ $MOUNTED -eq 1 ]]; then
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    fi
    rm -rf "$PACKAGE_DIR"
}
trap cleanup EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MOUNT" "$DIST"

swift build -c release --arch arm64 --arch x86_64 --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "$BUILD_DIR" --show-bin-path)"
BINARY="$BIN_DIR/DoubleMouse"

[[ -x "$BINARY" ]]
ARCHS="$(lipo -archs "$BINARY")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]]
cp -X "$BINARY" "$APP/Contents/MacOS/DoubleMouse"
cp -X "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${VERSION//./}" "$APP/Contents/Info.plist"

cp -X "$ROOT/Assets/DoubleMouse.icns" "$APP/Contents/Resources/DoubleMouse.icns"
xattr -cr "$APP"

SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - --timestamp=none "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

rm -f "$DMG" "$DMG.sha256"
hdiutil create -size 32m -fs HFS+ -volname DoubleMouse "$RW_DMG" >/dev/null
hdiutil attach -nobrowse -noverify -mountpoint "$MOUNT" "$RW_DMG" >/dev/null
MOUNTED=1
ditto --norsrc "$APP" "$MOUNT/DoubleMouse.app"
ln -s /Applications "$MOUNT/Applications"
xattr -cr "$MOUNT/DoubleMouse.app"
codesign --verify --deep --strict "$MOUNT/DoubleMouse.app"
hdiutil detach "$MOUNT" >/dev/null
MOUNTED=0
hdiutil convert "$RW_DMG" -format UDZO -ov -o "$DMG" >/dev/null

# Notarization needs a real Developer ID; an ad-hoc signature cannot be notarized.
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        echo "NOTARY_PROFILE is set but the build is ad-hoc signed; set CODESIGN_IDENTITY too." >&2
        exit 1
    fi
    # notarytool can exit 0 on a rejected submission, so check the reported status.
    SUBMIT_LOG="$PACKAGE_DIR/notarize.txt"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$SUBMIT_LOG"
    grep -q "status: Accepted" "$SUBMIT_LOG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    # The check Gatekeeper actually runs on a downloaded disk image.
    spctl -a -t open --context context:primary-signature -v "$DMG"
fi

# After stapling, because stapling rewrites the disk image.
hdiutil verify "$DMG" >/dev/null
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "$DMG"
