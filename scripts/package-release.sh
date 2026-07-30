#!/bin/bash
set -euo pipefail

VERSION="${1:-1.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Build outside the repository. This checkout can live under Desktop or
# Documents, which iCloud Drive syncs, and its file provider stamps
# com.apple.FinderInfo on the app bundle while the build is running. codesign
# then refuses the bundle with "resource fork, Finder information, or similar
# detritus not allowed", intermittently, depending on when the daemon runs.
PACKAGE_DIR="$(mktemp -d /private/tmp/doublemouse-release.XXXXXX)"
BUILD_DIR="$PACKAGE_DIR/swift-build"
APP="$PACKAGE_DIR/DoubleMouse.app"
RW_DMG="$PACKAGE_DIR/DoubleMouse-rw.dmg"
MOUNT="$PACKAGE_DIR/mount"
DIST="$ROOT/dist"
# Staged here and moved into DIST once it is signed, notarized, and stapled.
DMG="$PACKAGE_DIR/DoubleMouse-$VERSION.dmg"

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
SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGN_ARGS=(--sign - --timestamp=none)
else
    SIGN_ARGS=(--options runtime --timestamp --sign "$SIGNING_IDENTITY")
fi

# macOS re-applies com.apple.provenance on its own, sometimes between clearing
# the attributes and signing, and codesign rejects any bundle that carries one.
# Retry rather than lose a release build to the race.
# The condition of an `if` is exempt from set -e; `cmd && break` is not, and
# would abort the script on the first failure instead of retrying.
for attempt in 1 2 3; do
    xattr -cr "$APP"
    if codesign --force "${SIGN_ARGS[@]}" "$APP"; then
        break
    fi
    if [[ $attempt -eq 3 ]]; then
        echo "codesign failed three times; extended attributes still present:" >&2
        xattr -lr "$APP" >&2
        exit 1
    fi
    sleep 2
done
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
(cd "$PACKAGE_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

NAME="$(basename "$DMG")"
rm -f "$DIST/$NAME" "$DIST/$NAME.sha256"
mv "$DMG" "$DMG.sha256" "$DIST/"

echo "$DIST/$NAME"
