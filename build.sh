#!/bin/sh
# ./build.sh      build, install to /Applications (login item points there), launch
# ./build.sh dmg  build Swity.dmg (Developer ID + notarized) and version.json; bump CFBundleShortVersionString first
#                 one-time: Developer ID Application cert (Xcode → Settings → Accounts → Manage Certificates)
#                 and: xcrun notarytool store-credentials switcy --team-id J226WEZ2AM
# Release: bump CFBundleShortVersionString and CFBundleVersion in Info.plist, ./build.sh dmg, then
#   gh release create v<version> Swity.dmg version.json
# Installed copies poll swity.io/version.json, which redirects to the latest release's version.json.
set -e
cd "$(dirname "$0")"
APP="/Applications/Swity.app"
[ "$1" = dmg ] && rm -rf build && APP="build/Swity.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns MenuIconTemplate.tiff "$APP/Contents/Resources/"
# One app for Apple Silicon and Intel, macOS 11 and later
swiftc -O -target arm64-apple-macos11 main.swift -o build-arm64
swiftc -O -target x86_64-apple-macos11 main.swift -o build-x86_64
lipo -create build-arm64 build-x86_64 -output "$APP/Contents/MacOS/Swity"
rm build-arm64 build-x86_64
# One stable identity everywhere: Input Monitoring grant survives rebuilds.
# A Mac without the Developer ID (building from source) signs ad hoc: fine for yourself, and the DMG is not notarized.
ID="Developer ID Application"
security find-identity -v -p codesigning | grep -q "$ID" || ID="-"
if [ "$1" = dmg ]; then
    # notarization requires hardened runtime + timestamp
    if [ "$ID" = "-" ]; then codesign -f -s - "$APP"; else codesign -f -o runtime --timestamp -s "$ID" "$APP"; fi
    ln -s /Applications build/Applications
    mkdir build/.background
    cp DmgBackground.tiff build/.background/
    # Window layout (background with the arrow, icon places) is stored by Finder on the volume itself,
    # so the image is made writable first, arranged, then compressed. First run asks to let the terminal control Finder.
    hdiutil detach /Volumes/Swity 2>/dev/null || true
    # Finder writes the image's own path into the layout it stores; keep it out of the home folder
    RW="$(mktemp -d)/Swity-rw.dmg"
    hdiutil create -volname Swity -srcfolder build -ov -format UDRW "$RW"
    hdiutil attach "$RW" -noautoopen
    osascript <<'END'
tell application "Finder" to tell disk "Swity"
    open
    tell container window
        set current view to icon view
        set toolbar visible to false
        set statusbar visible to false
        set bounds to {200, 120, 740, 528}  -- 540 x 380 of content under a 28 pt title bar
    end tell
    set o to icon view options of container window
    set arrangement of o to not arranged
    set icon size of o to 96
    set text size of o to 13
    set background picture of o to file ".background:DmgBackground.tiff"
    set position of item "Swity.app" to {150, 184}
    set position of item "Applications" to {390, 184}
    close
    open
    delay 1
    close
end tell
END
    sync
    hdiutil detach /Volumes/Swity
    hdiutil convert "$RW" -ov -format UDZO -o Swity.dmg
    rm -rf build "$RW"
    if [ "$ID" = "-" ]; then
        echo "Swity.dmg built and signed ad hoc (no Developer ID here): for this Mac, not for sharing"
        exit
    fi
    codesign -f --timestamp -s "$ID" Swity.dmg
    xcrun notarytool submit Swity.dmg --keychain-profile switcy --wait  # "switcy": credential label from the old name, still valid
    xcrun stapler staple Swity.dmg  # ticket inside the DMG, so first launch works offline too
    spctl -a -t open --context context:primary-signature -v Swity.dmg
    # Update feed the installed apps poll; attached to the GitHub release next to Swity.dmg
    V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    printf '{"version": "%s", "url": "https://github.com/one-focus/swity/releases/download/v%s/Swity.dmg"}\n' "$V" "$V" > version.json
    exit
fi
if [ "$ID" = "-" ]; then codesign -f -s - "$APP"; else codesign -f -o runtime -s "$ID" "$APP"; fi
pkill -x Swity && while pgrep -qx Swity; do sleep 0.1; done  # else open hits the dying instance
open "$APP"
