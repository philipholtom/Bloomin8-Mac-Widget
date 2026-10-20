#!/bin/bash
# Builds and installs the two Bloomin8 products:
#   Bloomin8 Widget.app  menu bar widget (LSUIElement, popover)
#   Bloomin8 Mac.app     full window app (sidebar + gallery grid)
# Both link the shared Bloomin8Core library.
#
# Usage: ./build_app.sh [widget|app|all]   (default: all)
set -euo pipefail
cd "$(dirname "$0")"

BUILD_CONFIG="Release"
XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/Blooming8_Screen_Widget-bemzrgmnicnbnxfhqswrxccqxuqi"
PRODUCTS="$DERIVED_DATA/Build/Products/$BUILD_CONFIG"

TARGET="${1:-all}"

# $1 scheme/binary name, $2 .app bundle name, $3 Info.plist, $4 bundle id
build_product() {
    local scheme="$1" bundle="$2" plist="$3" bundle_id="$4"

    "$XCODE_BETA/usr/bin/xcodebuild" -scheme "$scheme" -configuration "$BUILD_CONFIG" \
        -destination "generic/platform=macOS" build

    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp "$PRODUCTS/$scheme" "$bundle/Contents/MacOS/$scheme"
    cp "$plist" "$bundle/Contents/Info.plist"
    cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"

    # Codesign the assembled bundle. Without this the only signature is the one
    # the linker applied to the bare executable, before Info.plist was copied in
    # — so the plist is left unsealed ("Info.plist=not bound"). TCC refuses to
    # trust an unsealed NSBluetoothAlwaysUsageDescription and denies Bluetooth
    # outright, which surfaces as CBCentralManager reporting .unauthorized and
    # every BLE wake failing silently.
    # Ad-hoc is enough to seal it. (A stable self-signed identity was tried
    # to stop Keychain re-prompting after every rebuild; it made no
    # difference, since macOS doesn't grant lasting Keychain trust to a
    # self-signed certificate, so it was dropped.)
    codesign --force --sign - --identifier "$bundle_id" "$bundle"
    if codesign -dv "$bundle" 2>&1 | grep -q "Info.plist=not bound"; then
        echo "ERROR: Info.plist still unsealed in $bundle; Bluetooth will be denied." >&2
        exit 1
    fi

    local installed="/Applications/$bundle"
    pkill -x "$scheme" 2>/dev/null || true
    sleep 1
    rm -rf "$installed"
    cp -R "$bundle" "$installed"
    echo "Installed $installed"

    # The apps were called Blooming8 / Blooming8Widget before the rename;
    # remove the old copies (and stop them) so two of each don't linger.
    pkill -x "Blooming8App" 2>/dev/null || true
    pkill -x "Blooming8Widget" 2>/dev/null || true
    rm -rf "/Applications/Blooming8.app" "/Applications/Blooming8Widget.app" "Blooming8.app" "Blooming8Widget.app"

    # Let Finder pick up the app's "Send to Frame" service and image file
    # types without waiting for a log out / log in.
    if [ "$bundle" = "Bloomin8 Mac.app" ]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed" >/dev/null 2>&1 || true
        /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
    fi
}

if [ "$TARGET" = "widget" ] || [ "$TARGET" = "all" ]; then
    build_product "Bloomin8Widget" "Bloomin8 Widget.app" "Info.plist" "com.pholtom.blooming8widget"
fi

if [ "$TARGET" = "app" ] || [ "$TARGET" = "all" ]; then
    build_product "Bloomin8App" "Bloomin8 Mac.app" "Info-App.plist" "com.pholtom.blooming8app"
fi

case "$TARGET" in
    widget) open "/Applications/Bloomin8 Widget.app" ;;
    app)    open "/Applications/Bloomin8 Mac.app" ;;
    all)    open "/Applications/Bloomin8 Widget.app"; open "/Applications/Bloomin8 Mac.app" ;;
esac
