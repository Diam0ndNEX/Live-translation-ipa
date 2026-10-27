#!/bin/bash
set -euo pipefail
# Choose a real available iPhone simulator from the runner instead of pinning an OS/device name.
xcrun simctl list devices available --json > /tmp/screenlingo-simulators.json
SIMULATOR_ID=$(python3 - <<'PY'
import json
with open('/tmp/screenlingo-simulators.json') as f:
    devices = json.load(f)['devices']
for runtime, values in sorted(devices.items(), reverse=True):
    if 'iOS' not in runtime:
        continue
    for device in values:
        if device.get('isAvailable') and 'iPhone' in device['name']:
            print(device['udid'])
            raise SystemExit
raise SystemExit('No available iPhone simulator')
PY
)
xcrun simctl boot "$SIMULATOR_ID" || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
if ! xcodebuild -project ScreenLingo.xcodeproj -scheme ScreenLingo \
    -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath preview CODE_SIGNING_ALLOWED=NO build > /tmp/screenlingo-preview-build.log 2>&1; then
    tail -120 /tmp/screenlingo-preview-build.log
    exit 1
fi
xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' --batteryState charged --batteryLevel 100
xcrun simctl install "$SIMULATOR_ID" preview/Build/Products/Debug-iphonesimulator/ScreenLingo.app
xcrun simctl launch "$SIMULATOR_ID" com.diam0ndnex.screenlingo -onboarded YES
sleep 4
mkdir -p interface-preview
xcrun simctl io "$SIMULATOR_ID" screenshot interface-preview/screenlingo-live.png
cp App/Assets.xcassets/AppIcon.appiconset/icon-1024.png interface-preview/screenlingo-icon.png
xcrun simctl terminate "$SIMULATOR_ID" com.diam0ndnex.screenlingo
