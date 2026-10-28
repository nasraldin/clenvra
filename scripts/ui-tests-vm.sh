#!/bin/zsh
# Runs the UI tests inside a macOS virtual machine, so they never take over this Mac's screen, mouse or keyboard.
# The VM runs macOS 26 (the oldest supported version) with Xcode 27.1.
#
# One-time setup (about 50 GB):
#   brew install cirruslabs/cli/tart
#   tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:27.1 clenvra-ui
#
# Usage: scripts/ui-tests-vm.sh [xcodebuild test filter, e.g. ClenvraUITests/NavigationUITests]
#        CLENVRA_SCREENSHOTS=1 scripts/ui-tests-vm.sh ClenvraUITests/ScreenshotUITests   # screenshots of every page
# Results: .build/ui-vm/Results.xcresult (screenshots and failures), copied back to this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

VM=${CLENVRA_UI_VM:-clenvra-ui}
FILTER=${1:-ClenvraUITests}
REPO=$PWD
OUT=$REPO/.build/ui-vm
GUEST_REPO="/Volumes/My Shared Files/repo"

command -v tart >/dev/null || { echo "✘ tart is not installed (see the setup lines at the top of this script)"; exit 1; }
tart list | awk '{print $2}' | grep -qx "$VM" || { echo "✘ No VM named $VM (see the setup lines at the top of this script)"; exit 1; }

/bin/rm -rf "$OUT"
mkdir -p "$OUT"

echo "▸ Starting $VM (no window)"
tart run "$VM" --no-graphics --dir=repo:"$REPO" >"$OUT/vm.log" 2>&1 &
VM_PID=$!
trap 'tart stop "$VM" >/dev/null 2>&1 || true; wait $VM_PID 2>/dev/null || true' EXIT

# The guest agent answers once macOS has booted.
for _ in {1..90}; do
  tart exec "$VM" true >/dev/null 2>&1 && break
  sleep 2
done
tart exec "$VM" true >/dev/null 2>&1 || { echo "✘ The VM did not finish booting"; exit 1; }

echo "▸ Copying the project into the VM"
# Build inside the VM's own disk: shared folders are slow and the host's build folder is not for this macOS.
tart exec "$VM" /bin/zsh -c "rm -rf ~/clenvra && rsync -a --exclude .build --exclude .git '$GUEST_REPO/' ~/clenvra/"

echo "▸ UI tests: $FILTER"
set +e
tart exec "$VM" /bin/zsh -c "cd ~/clenvra && TEST_RUNNER_CLENVRA_SCREENSHOTS=${CLENVRA_SCREENSHOTS:-0} xcodebuild test -workspace Clenvra.xcworkspace -scheme Clenvra \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/dd -resultBundlePath ~/Results.xcresult \
  -only-testing:$FILTER -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="
STATUS=$?
set -e

echo "▸ Copying results back"
tart exec "$VM" /bin/zsh -c "rm -rf '$GUEST_REPO/.build/ui-vm/Results.xcresult' && cp -R ~/Results.xcresult '$GUEST_REPO/.build/ui-vm/'" || true

if [[ $STATUS -eq 0 ]]; then
  echo "✔ UI tests passed in $VM: $OUT/Results.xcresult"
else
  echo "✘ UI tests failed in $VM: open $OUT/Results.xcresult in Xcode for details"
fi
exit $STATUS
