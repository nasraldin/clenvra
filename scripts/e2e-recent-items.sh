#!/bin/zsh
# End-to-end test of Recent Items in a throwaway copy of the UI-test VM. Never on a real Mac: it really clears the
# lists. Fills them by opening documents in TextEdit, apps and Finder folders, runs RecentItemsE2EUITests, then
# checks the lists through the same public interfaces and that the documents themselves are untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -d '' SETUP <<'EOF' || true
set -e
/bin/rm -rf ~/.Trash/*textedit*
mkdir -p ~/Documents/RecentE2E
echo one > ~/Documents/RecentE2E/one.txt; echo two > ~/Documents/RecentE2E/two.txt
open -a TextEdit ~/Documents/RecentE2E/one.txt; sleep 3; open -a TextEdit ~/Documents/RecentE2E/two.txt; sleep 3
pkill -x TextEdit || true; open -a Calculator; sleep 3; pkill -x Calculator || true
# Recent folders without open windows: in this VM only, Finder does not reopen its windows after it restarts.
defaults write com.apple.finder NSQuitAlwaysKeepsWindows -bool false
open ~/Documents/RecentE2E; sleep 3; open ~/Downloads; sleep 3
kill -TERM $(pgrep -x Finder); sleep 6
for _ in $(seq 1 30); do pgrep -xq TextEdit || break; sleep 1; done
xcrun swiftc -o /tmp/recent-lists "/Volumes/My Shared Files/repo/scripts/e2e/recent-lists.swift" 2>/dev/null
/tmp/recent-lists
echo "Finder folders: $(defaults read com.apple.finder FXRecentFolders 2>/dev/null | grep -c 'name =')"
[ "$(defaults read com.apple.finder FXRecentFolders 2>/dev/null | grep -c 'name =')" -gt "$(/tmp/recent-lists | awk '/finderWindows/ {print $2}')" ] || { echo "seed: need more recent folders than open windows"; exit 1; }
ls ~/"Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.textedit.sfl4"
EOF

read -r -d '' VERIFY <<'EOF' || true
fail=0
check() { if eval "$2"; then echo "✔ $1"; else echo "✘ $1"; fail=1; fi; }
lists=$(/tmp/recent-lists); echo "$lists"
check "Recent Applications is empty" 'echo "$lists" | grep -qx "applications 0"'
check "Recent Documents is empty" 'echo "$lists" | grep -qx "documents 0"'
sleep 5
echo "Finder folders now: $(defaults read com.apple.finder FXRecentFolders 2>/dev/null | grep 'name =' | tr -d ' ;' | tr '\n' ' ')"
# Finder reopens the windows it had, and their folders count as opened again: at most one folder per window.
windows=$(/tmp/recent-lists | awk '/finderWindows/ {print $2}')
check "Finder's Recent Folders holds only reopened windows' folders" '[ "$(defaults read com.apple.finder FXRecentFolders 2>/dev/null | grep -c "name =")" -le "$windows" ]'
check "Finder is running again" 'pgrep -xq Finder'
check "TextEdit's list went to the Trash" 'ls ~/.Trash | grep -q "com.apple.textedit"'
check "and is not back in its folder" '[ ! -e ~/"Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.textedit.sfl4" ]'
check "the documents are untouched" '[ "$(cat ~/Documents/RecentE2E/one.txt ~/Documents/RecentE2E/two.txt)" = "$(printf "one\ntwo")" ]'
exit $fail
EOF

# A throwaway copy of the UI-test VM (copy-on-write, instant), so the shared VM keeps its lists.
BASE=${CLENVRA_UI_VM:-clenvra-ui}
E2E_VM=clenvra-e2e-recents
tart delete "$E2E_VM" >/dev/null 2>&1 || true
tart clone "$BASE" "$E2E_VM"
trap 'tart stop "$E2E_VM" >/dev/null 2>&1 || true; tart delete "$E2E_VM" >/dev/null 2>&1 || true' EXIT

CLENVRA_UI_VM=$E2E_VM CLENVRA_E2E=1 CLENVRA_VM_SETUP=$SETUP CLENVRA_VM_VERIFY=$VERIFY \
  scripts/ui-tests-vm.sh ClenvraUITests/RecentItemsE2EUITests
