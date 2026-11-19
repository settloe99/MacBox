#!/bin/bash
set -euo pipefail
umask 077

VERSION="0.6.4"
ROOT="$HOME/MacBox-ReleaseTest"
OUTPUT="$ROOT/Release-Staging/v$VERSION"
DERIVED="$HOME/Developer/MacBox-Production-Unsigned-DerivedData"
LOG="$HOME/Developer/MacBox-Production-Unsigned-build.log"

PRIVATE="$HOME/Library/Application Support/MacBoxReleaseSigning/release-p256-private.pem"

SOURCE="$DERIVED/Build/Products/Release/MacBox.app"
APP="$OUTPUT/MacBox.app"
ZIP="$OUTPUT/MacBox-v$VERSION.zip"
MANIFEST="$OUTPUT/MacBox-release.manifest"
SIGNATURE="$OUTPUT/MacBox-release.manifest.sig"

echo "=== MacBox v$VERSION release preparation ==="

if [ ! -d "$ROOT" ] || [ -L "$ROOT" ]; then
    echo "FAIL: Release-Test directory is unsafe."
    exit 1
fi

if [ ! -f "$PRIVATE" ] || [ -L "$PRIVATE" ]; then
    echo "FAIL: Private release-signing key unavailable."
    exit 1
fi

if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
    echo "FAIL: Release candidate directory already exists."
    echo "Nothing has been overwritten."
    exit 1
fi

echo
echo "=== 1. Building production application ==="

if ! xcodebuild \
    -project MacBox.xcodeproj \
    -scheme MacBox \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    MACOSX_DEPLOYMENT_TARGET=12.0 \
    CODE_SIGNING_ALLOWED=NO \
    build > "$LOG" 2>&1; then

    grep -E 'error:|BUILD FAILED|Sandbox:' "$LOG" |
        tail -n 20 || true
    exit 1
fi

echo "PASS: Production build succeeded."

IDENTIFIER=$(/usr/libexec/PlistBuddy \
    -c "Print CFBundleIdentifier" \
    "$SOURCE/Contents/Info.plist")

BUILT_VERSION=$(/usr/libexec/PlistBuddy \
    -c "Print CFBundleShortVersionString" \
    "$SOURCE/Contents/Info.plist")

if [ "$IDENTIFIER" != "io.github.settloe99.MacBox" ] ||
   [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "FAIL: Incorrect application identity or version."
    echo "Found: $IDENTIFIER / $BUILT_VERSION"
    exit 1
fi

echo "PASS: Application identity and version verified."

echo
echo "=== 2. Preparing release application ==="

mkdir -p "$OUTPUT"
ditto "$SOURCE" "$APP"

FRAMEWORKS="$APP/Contents/Frameworks"

if [ -d "$FRAMEWORKS" ]; then
    while IFS= read -r -d '' LIBRARY; do
        codesign --force --sign - "$LIBRARY"
    done < <(find "$FRAMEWORKS" \
        -type f -name '*.dylib' -print0)

    while IFS= read -r -d '' FRAMEWORK; do
        codesign --force --sign - "$FRAMEWORK"
    done < <(find "$FRAMEWORKS" \
        -depth -type d -name '*.framework' -print0)
fi

HELPER="$APP/Contents/Helpers/MacBoxSelfUpdateHelper"

if [ ! -x "$HELPER" ]; then
    echo "FAIL: Embedded updater helper missing."
    exit 1
fi

codesign --force --sign - "$HELPER"
codesign --force --sign - --options runtime "$APP"

codesign --verify --deep --strict "$APP"

echo "PASS: Application and helper ad-hoc signed."

if find "$APP" -type l -print -quit | grep -q .; then
    echo "FAIL: Application contains symbolic links."
    exit 1
fi

echo
echo "=== 3. Creating release ZIP ==="

ditto -c -k --keepParent "$APP" "$ZIP"
unzip -tq "$ZIP" >/dev/null

echo "PASS: Release ZIP created and validated."

echo
echo "=== 4. Signing release manifest ==="

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

printf 'macbox-release-v1\nversion=%s\nsha256=%s\n' \
    "$VERSION" "$SHA" > "$MANIFEST"

openssl dgst -sha256 \
    -sign "$PRIVATE" \
    -out "$SIGNATURE" \
    "$MANIFEST"

echo "PASS: Release manifest signed."

echo
echo "=== 5. Verifying complete release ==="

"$HELPER" --verify-release-package \
    "$MANIFEST" \
    "$SIGNATURE" \
    "$ZIP"

echo
echo "=== Release artifacts ==="

ls -lh "$ZIP" "$MANIFEST" "$SIGNATURE"

echo
echo "PASS: MacBox v$VERSION release candidate prepared."
echo "Location: $OUTPUT"
