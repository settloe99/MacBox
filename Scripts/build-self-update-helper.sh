#!/bin/sh
set -eu

# Embed the self-update helper in Release builds.
# DEBUG builds continue without the helper.
# Production installation remains disabled in the helper itself.

if [ "${CONFIGURATION:-}" != "Release" ]; then
    echo "MacBox: Skipping updater helper for non-Release build."
    exit 0
fi

SOURCE="${SRCROOT}/MacBox/Helpers/MacBoxSelfUpdateHelper.swift"

DESTINATION="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Helpers"
EXECUTABLE="${DESTINATION}/MacBoxSelfUpdateHelper"

if [ ! -f "$SOURCE" ]; then
    echo "ERROR: MacBox updater helper source missing."
    exit 1
fi

mkdir -p "$DESTINATION"

echo "MacBox: Compiling updater helper..."

xcrun swiftc \
    -O \
    -target "arm64-apple-macos${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
    "$SOURCE" \
    -o "$EXECUTABLE"

chmod 755 "$EXECUTABLE"

echo "MacBox: Updater helper embedded successfully."