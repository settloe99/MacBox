#!/bin/sh
set -eu

# Embed the laboratory helper only in Release-Test builds.
case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
    *" MACBOX_RELEASE_TEST "*)
        ;;
    *)
        echo "MacBox: Skipping laboratory updater helper."
        exit 0
        ;;
esac

SOURCE="${SRCROOT}/MacBox/Helpers/MacBoxSelfUpdateHelper.swift"

DESTINATION="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Helpers"
EXECUTABLE="${DESTINATION}/MacBoxSelfUpdateHelper"

if [ ! -f "$SOURCE" ]; then
    echo "ERROR: MacBox updater helper source missing."
    exit 1
fi

mkdir -p "$DESTINATION"

echo "MacBox: Compiling Release-Test updater helper..."

xcrun swiftc \
    -O \
    -target "arm64-apple-macos${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
    "$SOURCE" \
    -o "$EXECUTABLE"

chmod 755 "$EXECUTABLE"

echo "MacBox: Updater helper embedded successfully."
