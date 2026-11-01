#!/bin/zsh
# Store screenshots in English and Arabic (dark mode), made in a throwaway copy of the UI-test VM filled with sample
# files (never on a real Mac), then laid out with captions at 2880x1800 into docs/store/screenshots/<language>/.
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -d '' SETUP <<'EOF' || true
set -e
# Sample files only, in this disposable VM: downloads, old large files, duplicates, caches, build data, a project.
mkdir -p ~/Downloads ~/Movies ~/Documents/Reports ~/Documents/Archive ~/Projects/web-app/node_modules/react
mkfile 900m ~/Downloads/"Design Assets.zip"; mkfile 650m ~/Downloads/"Installer.dmg"; mkfile 120m ~/Downloads/"Brochure.pdf"
mkfile 1500m ~/Movies/"Conference Talk.mov"; touch -t 202503010900 ~/Movies/"Conference Talk.mov"
mkfile 400m ~/Documents/Archive/"Backup 2024.zip"; touch -t 202406150900 ~/Documents/Archive/"Backup 2024.zip"
mkfile 30m ~/Documents/Reports/"Annual Report.pdf"; cp ~/Documents/Reports/"Annual Report.pdf" ~/Documents/Archive/
mkdir -p ~/Library/Caches/com.example.editor ~/Library/Logs/com.example.editor
mkfile 300m ~/Library/Caches/com.example.editor/cache.db; mkfile 40m ~/Library/Logs/com.example.editor/editor.log
mkdir -p ~/Library/Developer/Xcode/DerivedData/WebApp-abcdefghijklmnop/Build
mkfile 700m ~/Library/Developer/Xcode/DerivedData/WebApp-abcdefghijklmnop/Build/Products.bin
mkfile 200m ~/Projects/web-app/node_modules/react/bundle.js; echo '{"name":"web-app"}' > ~/Projects/web-app/package.json
echo notes > ~/Documents/Reports/"Meeting Notes.txt"
open -a TextEdit ~/Documents/Reports/"Meeting Notes.txt"; sleep 3; pkill -x TextEdit || true
open -a Calculator; sleep 2; pkill -x Calculator || true
echo seeded
EOF

BASE=${CLENVRA_UI_VM:-clenvra-ui}
VM=clenvra-store
tart delete "$VM" >/dev/null 2>&1 || true
tart clone "$BASE" "$VM"
trap 'tart stop "$VM" >/dev/null 2>&1 || true; tart delete "$VM" >/dev/null 2>&1 || true' EXIT

CLENVRA_UI_VM=$VM CLENVRA_STORE=1 CLENVRA_VM_SETUP=$SETUP scripts/ui-tests-vm.sh ClenvraUITests/StoreScreenshotUITests

RAW=.build/store/raw
/bin/rm -rf "$RAW" && mkdir -p "$RAW"
xcrun xcresulttool export attachments --path .build/ui-vm/Results.xcresult --output-path "$RAW" >/dev/null
python3 -I - "$RAW" <<'PY'
import json, os, sys
folder = sys.argv[1]
for test in json.load(open(os.path.join(folder, "manifest.json"))):
    for item in test.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "")
        if name.startswith("store-"):
            os.rename(os.path.join(folder, item["exportedFileName"]), os.path.join(folder, name.split("_")[0] + ".png"))
PY
python3 -I scripts/store/compose.py "$RAW" docs/store/screenshots
