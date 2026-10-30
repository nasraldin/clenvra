#!/bin/zsh
# End-to-end test of the gap features in the disposable UI-test VM, on seeded test data only.
# Never on a real Mac: the tests really remove what they find. Needs the VM from scripts/ui-tests-vm.sh.
#
# Seeds: a trashed app with Library data, a second drive "TestDrive" with an item in its Trash, generated blurry and
# dark photos (from .build/e2e/photos, made from Apple's wallpapers). Then runs GapFeaturesE2EUITests and checks the
# files on disk.
set -euo pipefail
cd "$(dirname "$0")/.."

PHOTOS=.build/e2e/photos
[[ -n "$(ls $PHOTOS/*.jpg 2>/dev/null)" ]] || { echo "✘ No test photos in $PHOTOS"; exit 1; }
# A 512 MB APFS drive image, raw (what tart attaches), made fresh for each run.
DISK=$PWD/.build/e2e/extra.img
/bin/rm -f "$DISK" "${DISK%.img}.dmg"
hdiutil create -size 512m -fs APFS -volname TestDrive -layout GPTSPUD "${DISK%.img}.dmg" >/dev/null 2>&1
hdiutil convert "${DISK%.img}.dmg" -format UDTO -o "${DISK%.img}" >/dev/null 2>&1
mv "${DISK%.img}.cdr" "$DISK" && /bin/rm -f "${DISK%.img}.dmg"

# Inside the VM. The extra drive is a pre-formatted APFS image named TestDrive, which macOS mounts by itself (a blank
# disk would raise a "not readable" alert over the app).
read -r -d '' SETUP <<'EOF' || true
set -e
for _ in $(seq 1 30); do [ -d /Volumes/TestDrive ] && break; sleep 1; done
[ -d /Volumes/TestDrive ] || { echo "no test drive"; exit 1; }
mkdir -p "/Volumes/TestDrive/.Trashes/$(id -u)"
mkfile 3m "/Volumes/TestDrive/.Trashes/$(id -u)/old-file.bin"
mkdir -p ~/.Trash/Foo.app/Contents
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.foo" -c "Add :CFBundleName string Foo" \
  -c "Add :CFBundlePackageType string APPL" ~/.Trash/Foo.app/Contents/Info.plist >/dev/null
mkdir -p ~/"Library/Application Support/com.example.foo"
mkfile 2m ~/"Library/Application Support/com.example.foo/data.bin"
mkdir -p ~/Pictures/E2E
cp "/Volumes/My Shared Files/repo/.build/e2e/photos/"*.jpg ~/Pictures/E2E/
echo "seeded; runtimes: $(xcrun simctl runtime list | tail -1)"
EOF

read -r -d '' VERIFY <<'EOF' || true
fail=0
check() { if eval "$2"; then echo "✔ $1"; else echo "✘ $1"; fail=1; fi; }
check "trashed app's data left Library" '[ ! -e ~/"Library/Application Support/com.example.foo" ]'
check "and went to the Trash" 'ls ~/.Trash | grep -q com.example.foo'
check "other drive's Trash item is gone" '[ ! -e "/Volumes/TestDrive/.Trashes/$(id -u)/old-file.bin" ]'
check "a test photo went to the Trash" 'ls ~/.Trash | grep -q "photo.*\.jpg"'
check "originals were kept" '[ $(ls ~/Pictures/E2E | grep -c original) -eq 3 ]'
check "xrOS runtime removed" '! xcrun simctl runtime list | grep -q "xrOS 27.0"'
exit $fail
EOF

# A throwaway copy of the UI-test VM (copy-on-write, instant), so the removals never touch the shared VM.
BASE=${CLENVRA_UI_VM:-clenvra-ui}
E2E_VM=clenvra-e2e
tart delete "$E2E_VM" >/dev/null 2>&1 || true
tart clone "$BASE" "$E2E_VM"
trap 'tart stop "$E2E_VM" >/dev/null 2>&1 || true; tart delete "$E2E_VM" >/dev/null 2>&1 || true; /bin/rm -f "$DISK"' EXIT

CLENVRA_UI_VM=$E2E_VM CLENVRA_E2E=1 CLENVRA_VM_DISK=$DISK CLENVRA_VM_SETUP=$SETUP CLENVRA_VM_VERIFY=$VERIFY \
  scripts/ui-tests-vm.sh ClenvraUITests/GapFeaturesE2EUITests
