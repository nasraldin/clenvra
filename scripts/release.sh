#!/bin/zsh
# Builds a Developer ID signed, notarised and stapled DMG of Clenvra in .build/release/.
# One-time setup: a "Developer ID Application" certificate for team CZU6ZC4LYQ in the keychain, and
#   xcrun notarytool store-credentials clenvra-notary --apple-id <Apple ID> --team-id CZU6ZC4LYQ
# Usage: scripts/release.sh [--skip-notarize | --app-only]
#   --app-only: stop after the signed app (.build/release/export/Clenvra.app), for the helper end-to-end test.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=CZU6ZC4LYQ
PROFILE=${CLENVRA_NOTARY_PROFILE:-clenvra-notary}
OUT=.build/release
ARCHIVE=$OUT/Clenvra.xcarchive
EXPORT=$OUT/export

/bin/rm -rf "$OUT"
mkdir -p "$OUT"

echo "▸ Archive (Release)"
xcodebuild -workspace Clenvra.xcworkspace -scheme Clenvra -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath .build/DerivedData-release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet archive

echo "▸ Export with Developer ID"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet

APP="$EXPORT/Clenvra.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT/Clenvra-$VERSION.dmg"

echo "▸ Verify app signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|TeamIdentifier=$TEAM" >/dev/null \
  || { echo "✘ App is not signed with Developer ID for $TEAM"; exit 1; }

if [[ "${1:-}" == "--app-only" ]]; then
  echo "✔ Signed app: $APP"
  exit 0
fi

echo "▸ Build DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
/bin/cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Clenvra $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO -quiet "$DMG"
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM)" | head -1 \
  | sed -E 's/.*"(.*)"/\1/')
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ "${1:-}" == "--skip-notarize" ]]; then
  echo "✔ Signed (not notarised): $DMG"
  exit 0
fi

echo "▸ Notarise (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "▸ Gatekeeper check"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "✔ $DMG"
