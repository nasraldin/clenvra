#!/bin/zsh
# Runs every quality gate: formatting, package tests, app build, and (with --ui) UI tests.
# Usage: scripts/check.sh [--ui]
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(Clenvra ClenvraUITests Packages/ClenvraKit/Sources Packages/ClenvraKit/Tests Packages/ClenvraKit/Package.swift)
XCB=(xcodebuild -workspace Clenvra.xcworkspace -scheme Clenvra -derivedDataPath .build/DerivedData -destination 'platform=macOS,arch=arm64' -quiet)

echo "▸ Format"
xcrun swift-format lint --recursive --strict "${SOURCES[@]}"

echo "▸ Package tests"
"${XCB[@]}" test -only-testing:ClenvraKitTests

echo "▸ App build (Release)"
"${XCB[@]}" -configuration Release build

if [[ "${1:-}" == "--ui" ]]; then
  echo "▸ UI tests (en/ar)"
  "${XCB[@]}" test -only-testing:ClenvraUITests
fi

echo "✔ All checks passed"
