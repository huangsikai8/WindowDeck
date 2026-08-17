#!/bin/bash
# Builds WindowDeck and assembles a runnable .app bundle.
# SwiftPM can't emit app bundles, so the wrapper is put together by hand.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="WindowDeck"
CONFIG="${CONFIG:-release}"
BUNDLE="build/${APP_NAME}.app"

echo "==> Compiling (${CONFIG})"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling ${BUNDLE}"
# Quit any running copy first, or the binary can't be replaced. The app handles
# SIGTERM and flushes its state before exiting, so group membership survives a
# rebuild; the pause gives that write time to land.
if pkill -x "$APP_NAME" 2>/dev/null; then
    sleep 0.6
fi

rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN_PATH}/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
# Regenerate the icon only when it is missing — drawing it is cheap but pointless
# on every build. Delete Resources/AppIcon.icns to force a redraw after editing
# Tools/MakeIcon.swift.
if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "==> Drawing app icon"
    rm -rf build/AppIcon.iconset
    swift Tools/MakeIcon.swift build/AppIcon.iconset >/dev/null
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

# Sign with a stable identity so the Accessibility grant survives rebuilds.
# An ad-hoc signature is derived from the binary, so it changes every build and
# macOS silently treats the app as a stranger — the System Settings toggle stays
# on while the app is actually blocked. A fixed certificate keeps the designated
# requirement constant, so the grant is given once and holds.
IDENTITY="${IDENTITY:-WindowDeck Dev}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "==> Signing as '${IDENTITY}'"
    codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE"
else
    echo "==> WARNING: '${IDENTITY}' not found; falling back to ad-hoc."
    echo "    The Accessibility grant will need re-granting after every rebuild."
    codesign --force --sign - --timestamp=none "$BUNDLE"
fi

if [[ "${RESET_TCC:-0}" == "1" ]]; then
    echo "==> Clearing stale Accessibility grant"
    tccutil reset Accessibility com.sikaihuang.WindowDeck >/dev/null 2>&1 || true
fi

echo "==> Built ${BUNDLE}"
