#!/usr/bin/env bash
set -euo pipefail

# Build signed macOS .app for Tome (Swift)
# Usage:
#   ./scripts/build_swift_app.sh
#
# For CI / explicit identity:
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/build_swift_app.sh
#
# For notarization:
#   APPLE_ID="name@example.com"
#   APPLE_TEAM_ID="TEAMID123"
#   APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SWIFT_DIR="$ROOT_DIR/Tome"
APP_NAME="Tome"
BUNDLE_ID="io.gremble.tome"

echo "=== Building $APP_NAME (Swift) ==="

# Build release binary
cd "$SWIFT_DIR"
swift build -c release 2>&1
BINARY_PATH=".build/release/Tome"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH"
  exit 1
fi

echo "Binary built: $BINARY_PATH"

# Create .app bundle
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

# Copy binary
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/Tome"

# Make the SwiftPM-built executable behave like a normal app bundle by
# teaching dyld to search the app's embedded Frameworks directory.
APP_BINARY="$APP_DIR/Contents/MacOS/Tome"
if ! otool -l "$APP_BINARY" | grep -Fq "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
  echo "Added app Frameworks rpath to executable"
fi

# Copy Info.plist
cp "$SWIFT_DIR/Sources/Tome/Info.plist" "$APP_DIR/Contents/Info.plist"

# Copy app icon
ICON_PATH="$SWIFT_DIR/Sources/Tome/Assets/AppIcon.icns"
if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "App icon copied"
fi

# Copy Sparkle framework
SPARKLE_ARTIFACT_DIR="$SWIFT_DIR/.build/artifacts/sparkle"
SPARKLE_FW=$(find "$SPARKLE_ARTIFACT_DIR" -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [[ -n "$SPARKLE_FW" ]]; then
  cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/"
  echo "Sparkle.framework copied"
else
  echo "Warning: Sparkle.framework not found in build artifacts"
fi

# Add PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "App bundle created: $APP_DIR"

# Auto-detect signing identity if not set
ADHOC_SIGN=0
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  fi
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    echo "No Developer ID / Apple Development identity found — falling back to ad-hoc signing (local testing only)."
    CODESIGN_IDENTITY="-"
    ADHOC_SIGN=1
  fi
elif [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  ADHOC_SIGN=1
fi

# Timestamp/runtime flags: ad-hoc cannot use --timestamp (no trust chain) and
# must disable library validation (Sparkle has a different / no Team ID).
ENTITLEMENTS="$SWIFT_DIR/Sources/Tome/Tome.entitlements"
TIMESTAMP_FLAG=(--timestamp)
if [[ "$ADHOC_SIGN" == "1" ]]; then
  TIMESTAMP_FLAG=()
  ADHOC_ENTITLEMENTS="$(mktemp -t tome-adhoc-entitlements).plist"
  /usr/libexec/PlistBuddy -c "Merge $ENTITLEMENTS" "$ADHOC_ENTITLEMENTS" >/dev/null 2>&1 || cp "$ENTITLEMENTS" "$ADHOC_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ADHOC_ENTITLEMENTS" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :com.apple.security.cs.disable-library-validation true" "$ADHOC_ENTITLEMENTS"
  ENTITLEMENTS="$ADHOC_ENTITLEMENTS"
  trap 'rm -f "$ADHOC_ENTITLEMENTS"' EXIT
fi

echo "Signing with: $CODESIGN_IDENTITY"

# Sign Sparkle components inside-out (innermost first)
SPARKLE_FW_BUNDLE="$APP_DIR/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW_BUNDLE" ]]; then
  # Sign XPC service executables, then their bundles
  for xpc in "$SPARKLE_FW_BUNDLE"/Versions/B/XPCServices/*.xpc; do
    if [[ -d "$xpc" ]]; then
      codesign --force --options runtime --sign "$CODESIGN_IDENTITY" ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} "$xpc/Contents/MacOS/$(basename "${xpc%.xpc}")"
      codesign --force --options runtime --sign "$CODESIGN_IDENTITY" ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} "$xpc"
    fi
  done

  # Sign Autoupdate helper
  AUTOUPDATE="$SPARKLE_FW_BUNDLE/Versions/B/Autoupdate"
  if [[ -f "$AUTOUPDATE" ]]; then
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} "$AUTOUPDATE"
  fi

  # Sign Updater.app
  UPDATER_APP="$SPARKLE_FW_BUNDLE/Versions/B/Updater.app"
  if [[ -d "$UPDATER_APP" ]]; then
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} "$UPDATER_APP/Contents/MacOS/Updater"
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} "$UPDATER_APP"
  fi

  # Sign the framework dylib, then the framework bundle
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} "$SPARKLE_FW_BUNDLE/Versions/B/Sparkle"
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} "$SPARKLE_FW_BUNDLE"
fi

# Sign the main app bundle
codesign --force --options runtime \
  --sign "$CODESIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} \
  "$APP_DIR"

echo "Code signing complete"
codesign -vvv "$APP_DIR"

# Leave the built bundle in dist/ — caller copies it where they need.
# Ad-hoc-signed apps inherit no Developer ID trust, so strip the quarantine
# attribute to avoid Gatekeeper blocking launch on local installs.
if [[ "$ADHOC_SIGN" == "1" ]]; then
  xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
  echo "Note: app is ad-hoc signed — for local testing only, not distributable."
fi
echo "Built bundle: $APP_DIR"

echo "=== Build complete ==="
