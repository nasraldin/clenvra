#!/bin/zsh
# Runs every quality gate: formatting, package tests, app build, and (with --ui) UI tests.
# Usage: scripts/check.sh [--ui]
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(Clenvra ClenvraHelper ClenvraUITests Packages/ClenvraKit/Sources Packages/ClenvraKit/Tests Packages/ClenvraKit/Package.swift)
XCB=(xcodebuild -workspace Clenvra.xcworkspace -scheme Clenvra -derivedDataPath .build/DerivedData -destination 'platform=macOS,arch=arm64' -quiet)

# Signs with the project's team when this Mac has a signing identity for it; otherwise ad-hoc (like CI), so the
# checks run on any Mac. Helper end-to-end tests still need the real team signature (see docs/STATUS.md).
TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' Clenvra.xcodeproj/project.pbxproj | head -1)
has_team_identity() {
  local hash
  for hash in $(security find-identity -v -p codesigning 2>/dev/null | awk '$2 ~ /^[0-9A-F]{40}$/ {print $2}'); do
    security find-certificate -a -Z -p 2>/dev/null \
      | awk -v h="$hash" '/^SHA-1 hash:/ {on = ($3 == h)} on && /BEGIN/,/END/ {if (on) print}' \
      | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *$TEAM" && return 0
  done
  return 1
}
if [[ -n "$TEAM" ]] && has_team_identity; then
  echo "▸ Signing with team $TEAM"
else
  echo "▸ No signing identity for team ${TEAM:-?} on this Mac: signing ad hoc"
  XCB+=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

# xcodebuild passes only TEST_RUNNER_-prefixed variables to tests; timing tests allow for slow CI runners.
[[ "${CI:-}" == "true" ]] && export TEST_RUNNER_CI=true

echo "▸ Format"
xcrun swift-format lint --recursive --strict "${SOURCES[@]}"

echo "▸ Package tests"
"${XCB[@]}" test -only-testing:ClenvraKitTests

echo "▸ App build (Release)"
"${XCB[@]}" -configuration Release build

if [[ "${1:-}" == "--ui" ]]; then
  echo "▸ UI tests (en/ar × light/dark, accessibility audit)"
  "${XCB[@]}" test -only-testing:ClenvraUITests
fi

echo "✔ All checks passed"
