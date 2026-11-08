#!/bin/bash
# ScreenLingo 2.1.0 spec §13.8: one screenshot per fixture × device × appearance × text size.
# Output: ui-screenshots/<device>/<appearance>-<text>/<fixture>.png plus fixtures.txt and devices.txt.
# Needs: xcodegen already run, macOS runner with Xcode and iOS simulator runtimes.
set -euo pipefail

OUT=${OUT:-ui-screenshots}
# QUICK=1: only the iPhone 16 Pro class device and default text size (about a quarter of the time).
TEXTS="default ax3"; [ "${QUICK:-0}" = 1 ] && TEXTS="default"
BUNDLE=com.diam0ndnex.screenlingo
FIXTURES=(idle idle-pack-missing starting live-short live-long paused attention-lost
          library-empty library-many diagnostics-idle diagnostics-live diagnostics-bad
          settings-root settings-caption settings-interface languages-sheet onboarding area-editor kit)
rm -rf "$OUT"
mkdir -p "$OUT"
printf '%s\n' "${FIXTURES[@]}" > "$OUT/fixtures.txt"

echo "Building Debug simulator app with SCREENLINGO_FIXTURES…"
if ! xcodebuild -project ScreenLingo.xcodeproj -scheme ScreenLingo -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ui-build \
    CODE_SIGNING_ALLOWED=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG SCREENLINGO_FIXTURES' \
    build > /tmp/ui-build.log 2>&1; then
    grep -E "error:" /tmp/ui-build.log | head -60 || true
    tail -80 /tmp/ui-build.log
    exit 1
fi
APP=ui-build/Build/Products/Debug-iphonesimulator/ScreenLingo.app

# Pick the newest iOS runtime and a device type by name preference (first match wins).
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["name"].startswith("iOS")]
if not rts: sys.exit("no iOS runtime")
print(sorted(rts, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])')
echo "Runtime: $RUNTIME"

device_type() {
    xcrun simctl list devicetypes -j | python3 -c '
import json, sys
names = sys.argv[1].split("|")
types = json.load(sys.stdin)["devicetypes"]
for want in names:
    for t in types:
        if t["name"] == want:
            print(t["identifier"] + "\t" + t["name"]); raise SystemExit
raise SystemExit("none of " + sys.argv[1])' "$1"
}

shoot_device() {
    local slug=$1 prefs=$2
    local found type name udid
    found=$(device_type "$prefs")
    type=${found%%$'\t'*}; name=${found#*$'\t'}
    udid=$(xcrun simctl create "ScreenLingo $slug" "$type" "$RUNTIME")
    echo "$slug: $name ($udid)" | tee -a "$OUT/devices.txt"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b > /dev/null
    xcrun simctl status_bar "$udid" override --time '9:41' --batteryState charged --batteryLevel 100 \
        --wifiBars 3 --cellularMode active --cellularBars 4 || true
    xcrun simctl install "$udid" "$APP"
    for scheme in light dark; do
        xcrun simctl ui "$udid" appearance "$scheme"
        for text in $TEXTS; do
            if [ "$text" = ax3 ]; then size=accessibility-extra-large; else size=large; fi
            xcrun simctl ui "$udid" content_size "$size"
            local dir="$OUT/$slug/$scheme-$text"
            mkdir -p "$dir"
            for fixture in "${FIXTURES[@]}"; do
                local onboarded=YES detailed=NO
                [ "$fixture" = onboarding ] && onboarded=NO
                case "$fixture" in diagnostics-live|diagnostics-bad) detailed=YES ;; esac
                xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1 || true
                xcrun simctl launch "$udid" "$BUNDLE" -uiFixture "$fixture" -onboarded "$onboarded" -detailedCollection "$detailed" \
                    -appearance system > /dev/null
                # Sheets open after a short router delay; give every fixture the same settle time.
                sleep 4
                xcrun simctl io "$udid" screenshot "$dir/$fixture.png" > /dev/null
            done
        done
    done
    xcrun simctl shutdown "$udid" || true
    xcrun simctl delete "$udid" || true
}

[ "${QUICK:-0}" = 1 ] || shoot_device iphone-se "iPhone SE (3rd generation)|iPhone SE (2nd generation)|iPhone 16e"
shoot_device iphone-16-pro "iPhone 16 Pro|iPhone 17 Pro|iPhone 15 Pro"
echo "Screenshots: $(find "$OUT" -name '*.png' | wc -l | tr -d ' ')"
