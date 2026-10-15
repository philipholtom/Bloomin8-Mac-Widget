#!/bin/bash
# Packages the two built apps into a drag-to-install disk image for a GitHub
# release: dist/Blooming8-<version>.dmg
#
# Run ./build_app.sh all first — this packages the Blooming8.app and
# Blooming8Widget.app it leaves in the repo root.
set -euo pipefail
cd "$(dirname "$0")"

for app in Blooming8.app Blooming8Widget.app; do
    [ -d "$app" ] || { echo "Missing $app — run ./build_app.sh all first." >&2; exit 1; }
done

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info-App.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R Blooming8.app Blooming8Widget.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<TXT
Blooming8 $VERSION

1. Drag Blooming8 and Blooming8Widget onto the Applications folder.
2. These apps aren't notarized by Apple, so macOS will block the first launch.
   Either run this once in Terminal (works on every macOS version):
       xattr -dr com.apple.quarantine /Applications/Blooming8.app /Applications/Blooming8Widget.app
   or try to open each app, then go to System Settings > Privacy & Security
   and click "Open Anyway". (On macOS 14 and earlier, right-click > Open also works.)
3. Enter your frame's IP address in Settings.
TXT

mkdir -p dist
OUT="dist/Blooming8-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "Blooming8 $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "Created $OUT ($(du -h "$OUT" | cut -f1))"
