#!/bin/bash
# Install the native messaging host manifest for Firefox.
# This must be run once so Firefox can discover the native app.

set -e

MANIFEST_DIR="$HOME/.mozilla/native-messaging-hosts"
MANIFEST_NAME="com.hdrupscaler.app.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/$MANIFEST_NAME"

if [ ! -f "$SOURCE" ]; then
    echo "Error: $SOURCE not found"
    exit 1
fi

mkdir -p "$MANIFEST_DIR"
cp "$SOURCE" "$MANIFEST_DIR/$MANIFEST_NAME"

echo "Installed native messaging host manifest:"
echo "  $MANIFEST_DIR/$MANIFEST_NAME"
echo ""
echo "Make sure the binary path in the manifest is correct:"
cat "$MANIFEST_DIR/$MANIFEST_NAME" | grep '"path"'
echo ""
echo "Build the native app first:  cd native-app && swift build"
