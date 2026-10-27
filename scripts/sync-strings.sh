#!/bin/zsh
# Builds the app and merges every user-facing string from source into the String Catalog.
# New keys appear untranslated; the StringCatalog test then fails until they have Arabic translations.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED=.build/DerivedData
xcodebuild -workspace Clenvra.xcworkspace -scheme Clenvra -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' -quiet build
DATA=("${(@f)$(find "$DERIVED/Build/Intermediates.noindex/Clenvra.build/Debug/Clenvra.build" "$DERIVED/Build/Intermediates.noindex/ClenvraKit.build/Debug/ClenvraKit-t.build" -name '*.stringsdata')}")
xcrun xcstringstool sync Clenvra/Resources/Localizable.xcstrings --stringsdata "${DATA[@]}"
echo "✔ String Catalog synced"
