#!/usr/bin/env bash
# App Store screenshots from the UI tests (UITests/*/StoreScreenshots.swift), on fixture data only:
#   scripts/screenshots.sh [all|viewer-ios|viewer-tv|viewer-mac|studio-ios|studio-mac] [out-dir]
# `make screenshots` runs all of them; Actions → "Store screenshots" runs them on CI and keeps them as an artifact.
#
# Output, in fastlane `deliver`'s layout (it picks the device from the image size):
#   <out>/<app>/<en-US|ar-SA>/<device>-<NN>-<screen>-<theme>.png
# Sizes: iPhone 6.9" 1320×2868 (iPhone 17 Pro Max), iPad 13" 2064×2752 (iPad Pro 13-inch (M5)),
# Apple TV 3840×2160 or 1920×1080, Mac 2880×1800 (the window, scaled and centred on the theme's page colour).
# Phones get dark and light; the other devices dark (AUN_SCREENSHOT_THEMES overrides).
set -euo pipefail
cd "$(dirname "$0")/.."

WHAT="${1:-all}"
OUT="${2:-build/screenshots}"
IOS_OS="${AUN_IOS_SIM_OS:-26.4}"
TVOS_OS="${AUN_TVOS_SIM_OS:-26.4}"
DERIVED="${AUN_DERIVED_DATA:-build/DerivedData}"
RESULTS="build/screenshot-results"
COMMON=(-workspace AlUmmahNow.xcworkspace -derivedDataPath "$DERIVED" -configuration Debug
        -skipPackagePluginValidation -skipMacroValidation)
IPHONE="iPhone 17 Pro Max"
IPAD="iPad Pro 13-inch (M5)"
TV="Apple TV 4K (3rd generation)"
mkdir -p "$OUT" "$RESULTS"

# The simulator's UDID for a device name on a runtime version, created when the runner has none.
simulator() { # name platform version
  python3 - "$1" "$2" "$3" <<'PY'
import json, subprocess, sys
name, platform, version = sys.argv[1:]
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", "runtimes"]))["runtimes"]
runtime = next((r for r in runtimes if r.get("platform", r["name"].split()[0]) == platform
                and r.get("version", "").startswith(version) and r.get("isAvailable", True)), None)
if runtime is None:
    sys.exit(f"no {platform} {version} runtime")
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", "devices", "available"]))["devices"]
for d in devices.get(runtime["identifier"], []):
    if d["name"] == name:
        print(d["udid"]); sys.exit(0)
types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", "devicetypes"]))["devicetypes"]
kind = next((t["identifier"] for t in types if t["name"] == name), None)
if kind is None:
    sys.exit(f"no device type {name}")
print(subprocess.check_output(["xcrun", "simctl", "create", name, kind, runtime["identifier"]], text=True).strip())
PY
}

# Runs one target's StoreScreenshots test and files its attachments as <app>/<locale>/<device>-….png.
shoot() { # app scheme destination device themes [udid]
  local app="$1" scheme="$2" destination="$3" device="$4" themes="$5" udid="${6:-}"
  local bundle="$RESULTS/$app-$device.xcresult"
  rm -rf "$bundle" "$RESULTS/$app-$device"
  if [[ -n "$udid" ]]; then
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 2>/dev/null || true
  fi
  local signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  [[ "$destination" == "platform=macOS" ]] && signing=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)
  TEST_RUNNER_AUN_SCREENSHOTS=1 TEST_RUNNER_AUN_SCREENSHOT_THEMES="${AUN_SCREENSHOT_THEMES:-$themes}" \
    xcodebuild test "${COMMON[@]}" -scheme "$scheme" -destination "$destination" \
    -only-testing:"${scheme}UITests/StoreScreenshots" -resultBundlePath "$bundle" "${signing[@]}"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$RESULTS/$app-$device" >/dev/null
  python3 scripts/file-screenshots.py "$RESULTS/$app-$device" "$OUT/$app" "$device"
}

viewer_ios() {
  shoot viewer-ios ViewerIOS "platform=iOS Simulator,id=$(simulator "$IPHONE" iOS "$IOS_OS")" iphone "dark,light" \
    "$(simulator "$IPHONE" iOS "$IOS_OS")"
  shoot viewer-ios ViewerIOS "platform=iOS Simulator,id=$(simulator "$IPAD" iOS "$IOS_OS")" ipad dark \
    "$(simulator "$IPAD" iOS "$IOS_OS")"
}
viewer_tv() {
  local udid
  udid=$(simulator "$TV" tvOS "$TVOS_OS")
  shoot viewer-tv ViewerTV "platform=tvOS Simulator,id=$udid" tv dark "$udid"
}
viewer_mac() { shoot viewer-mac ViewerMac "platform=macOS" mac dark; }
studio_ios() {
  shoot studio-ios StudioIOS "platform=iOS Simulator,id=$(simulator "$IPHONE" iOS "$IOS_OS")" iphone "dark,light" \
    "$(simulator "$IPHONE" iOS "$IOS_OS")"
  shoot studio-ios StudioIOS "platform=iOS Simulator,id=$(simulator "$IPAD" iOS "$IOS_OS")" ipad dark \
    "$(simulator "$IPAD" iOS "$IOS_OS")"
}
studio_mac() { shoot studio-mac StudioMac "platform=macOS" mac dark; }

case "$WHAT" in
  all) viewer_ios; viewer_tv; viewer_mac; studio_ios; studio_mac ;;
  viewer-ios) viewer_ios ;;
  viewer-tv) viewer_tv ;;
  viewer-mac) viewer_mac ;;
  studio-ios) studio_ios ;;
  studio-mac) studio_mac ;;
  *) echo "usage: $0 [all|viewer-ios|viewer-tv|viewer-mac|studio-ios|studio-mac] [out-dir]" >&2; exit 2 ;;
esac
find "$OUT" -name "*.png" | sort
