#!/bin/zsh
# End-to-end test of the privileged helper in a disposable VM: the real signed app, the real helper, the real
# macOS approval and password dialogs. Never on a real Mac: the test really uninstalls and disables what it seeds.
#
# 1. Builds the Developer ID signed app on this Mac (scripts/release.sh --app-only; nothing is installed here).
# 2. Clones the UI-test VM (copy-on-write, deleted afterwards) and seeds it: an app installed by a real installer
#    package (with a root-owned support folder and an installer record), and a Mac-wide startup daemon.
# 3. HelperE2EUITests installs and approves the helper, disables the daemon and uninstalls the app, typing the VM
#    account's password ("admin", the test image's default) into each macOS password dialog.
# 4. Checks the result on disk in the VM.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "${1:-}" == "--reuse-build" && -d .build/release/export/Clenvra.app ]] || scripts/release.sh --app-only

read -r -d '' SETUP <<'EOF' || true
set -e
sudo ditto "/Volumes/My Shared Files/repo/.build/release/export/Clenvra.app" /Applications/Clenvra.app
# An app installed by a real package: the bundle and a support folder, both owned by root, plus its record.
stage=$(mktemp -d); mkdir -p "$stage/Applications/Writer.app/Contents/MacOS" "$stage/Library/Application Support/com.example.writer"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.writer" -c "Add :CFBundleName string Writer" \
  -c "Add :CFBundleExecutable string Writer" -c "Add :CFBundlePackageType string APPL" \
  "$stage/Applications/Writer.app/Contents/Info.plist" >/dev/null
printf '#!/bin/sh\nexit 0\n' > "$stage/Applications/Writer.app/Contents/MacOS/Writer"
chmod +x "$stage/Applications/Writer.app/Contents/MacOS/Writer"
mkfile 1m "$stage/Library/Application Support/com.example.writer/state.bin"
pkgbuild --root "$stage" --identifier com.example.writer.pkg --version 1.0 --install-location / /tmp/writer.pkg >/dev/null
sudo installer -pkg /tmp/writer.pkg -target / >/dev/null
# A Mac-wide startup daemon that keeps running until disabled.
sudo tee /Library/LaunchDaemons/com.example.e2e.daemon.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.e2e.daemon</string>
  <key>ProgramArguments</key><array><string>/bin/sleep</string><string>86400</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.e2e.daemon.plist
pkgutil --pkg-info com.example.writer.pkg >/dev/null && echo "seeded: Writer (package), e2e daemon (running)"
EOF

read -r -d '' VERIFY <<'EOF' || true
fail=0
check() { if eval "$2"; then echo "✔ $1"; else echo "✘ $1"; fail=1; fi; }
check "helper installed and approved" 'sudo launchctl print system/com.nasraldin.clenvra.helper >/dev/null 2>&1 || sudo launchctl print-disabled system | grep -q clenvra'
check "daemon disabled" 'sudo launchctl print-disabled system | grep -E "\"com.example.e2e.daemon\" => (disabled|true)" >/dev/null'
check "daemon stopped" '! sudo launchctl print system/com.example.e2e.daemon >/dev/null 2>&1'
check "daemon's plist kept (Disable is undoable)" '[ -f /Library/LaunchDaemons/com.example.e2e.daemon.plist ]'
check "app deleted for good" '[ ! -e /Applications/Writer.app ] && ! ls ~/.Trash | grep -q Writer'
check "its root-owned folder deleted" '[ ! -e "/Library/Application Support/com.example.writer" ]'
check "installer record forgotten" '! pkgutil --pkg-info com.example.writer.pkg >/dev/null 2>&1'
exit $fail
EOF

BASE=${CLENVRA_UI_VM:-clenvra-ui}
E2E_VM=clenvra-helper-e2e
tart delete "$E2E_VM" >/dev/null 2>&1 || true
tart clone "$BASE" "$E2E_VM"
trap 'tart stop "$E2E_VM" >/dev/null 2>&1 || true; tart delete "$E2E_VM" >/dev/null 2>&1 || true' EXIT

CLENVRA_UI_VM=$E2E_VM CLENVRA_HELPER_E2E=1 CLENVRA_VM_SETUP=$SETUP CLENVRA_VM_VERIFY=$VERIFY \
  scripts/ui-tests-vm.sh ClenvraUITests/HelperE2EUITests
