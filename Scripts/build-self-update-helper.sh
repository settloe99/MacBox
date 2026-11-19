#!/bin/sh
set -eu

# Build the Universal MacBox self-update helper.
# Supports Apple Silicon and Intel Macs.

if [ "${CONFIGURATION:-}" != "Release" ]; then
    echo "MacBox: Skipping helper for non-Release build."
    exit 0
fi

SOURCE="${SRCROOT}/MacBox/Helpers/MacBoxSelfUpdateHelper.swift"

DESTINATION="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Helpers"
EXECUTABLE="${DESTINATION}/MacBoxSelfUpdateHelper"

THIN_DIR="${DERIVED_FILE_DIR}"
ARM64="${THIN_DIR}/MacBoxSelfUpdateHelper-arm64"
X86_64="${THIN_DIR}/MacBoxSelfUpdateHelper-x86_64"

MIN_VERSION="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

if [ ! -f "$SOURCE" ]; then
    echo "ERROR: MacBox updater helper source missing."
    exit 1
fi

mkdir -p "$DESTINATION" "$THIN_DIR"

echo "MacBox: Compiling Apple Silicon updater helper..."

xcrun swiftc \
    -O \
    -sdk "$SDK" \
    -target "arm64-apple-macos${MIN_VERSION}" \
    "$SOURCE" \
    -o "$ARM64"

echo "MacBox: Compiling Intel updater helper..."

xcrun swiftc \
    -O \
    -sdk "$SDK" \
    -target "x86_64-apple-macos${MIN_VERSION}" \
    "$SOURCE" \
    -o "$X86_64"

echo "MacBox: Creating Universal updater helper..."

xcrun lipo \
    -create \
    -output "$EXECUTABLE" \
    "$ARM64" \
    "$X86_64"

chmod 755 "$EXECUTABLE"

echo "MacBox: Verifying Universal architectures..."

ARCHS="$(xcrun lipo -archs "$EXECUTABLE")"

case " $ARCHS " in
    *" arm64 "*)
        echo "PASS: ARM64 architecture present."
        ;;
    *)
        echo "ERROR: ARM64 architecture missing."
        exit 1
        ;;
esac

case " $ARCHS " in
    *" x86_64 "*)
        echo "PASS: Intel architecture present."
        ;;
    *)
        echo "ERROR: Intel architecture missing."
        exit 1
        ;;
esac

echo "MacBox: Universal updater helper embedded successfully."
echo "Architectures: $ARCHS"
