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
IOS_OS="${AUN_IOS_SIM_OS:-27.0}"
TVOS_OS="${AUN_TVOS_SIM_OS:-27.0}"
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

# Without the runtime's dyld shared cache every simulator process loads its frameworks one by one, which makes app
# launches several times slower (see scripts/ci.sh). Built once per run when the runner image lacks it.
dyld_cache() { # platform version
  local runtime waited=0
  runtime=$(xcrun simctl list -j runtimes | python3 -c 'import json,sys; p,v=sys.argv[1:]; print(next(r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == p and r.get("version","").startswith(v)))' "$1" "$2")
  if compgen -G "/Library/Developer/CoreSimulator/Caches/dyld/*/$runtime.*" >/dev/null; then
    echo "dyld shared cache for $runtime: present"
    return
  fi
  echo "dyld shared cache for $runtime: missing, building"
  xcrun simctl runtime dyld_shared_cache update "$runtime"
  until compgen -G "/Library/Developer/CoreSimulator/Caches/dyld/*/$runtime.*" >/dev/null || ((waited >= 900)); do
    sleep 10
    waited=$((waited + 10))
  done
  echo "dyld shared cache for $runtime: ready after ${waited} s"
}

# Runs one target's StoreScreenshots test and files its attachments as <app>/<locale>/<device>-….png.
# On a simulator: only that simulator runs (the previous pass's one is shut down), it boots before the build so its
# first-boot system work settles while xcodebuild compiles, and the test starts once it has finished booting.
# Two simulators, or a freshly booted one, on the 3-vCPU runner timed out the iPad pass ("Timed out waiting for AX
# loaded notification", "Timed out while requesting screenshot"; #47).
shoot() { # app scheme destination device themes [udid]
  local app="$1" scheme="$2" destination="$3" device="$4" themes="$5" udid="${6:-}"
  local bundle="$RESULTS/$app-$device.xcresult"
  rm -rf "$bundle" "$RESULTS/$app-$device"
  local signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  [[ "$destination" == "platform=macOS" ]] && signing=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)
  if [[ -n "$udid" ]]; then
    xcrun simctl shutdown all 2>/dev/null || true
    xcrun simctl boot "$udid" 2>/dev/null || true
  fi
  xcodebuild build-for-testing "${COMMON[@]}" -scheme "$scheme" -destination "$destination" "${signing[@]}"
  if [[ -n "$udid" ]]; then
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 2>/dev/null || true
  fi
  TEST_RUNNER_AUN_SCREENSHOTS=1 TEST_RUNNER_AUN_SCREENSHOT_THEMES="${AUN_SCREENSHOT_THEMES:-$themes}" \
    xcodebuild test-without-building "${COMMON[@]}" -scheme "$scheme" -destination "$destination" \
    -only-testing:"${scheme}UITests/StoreScreenshots" -resultBundlePath "$bundle" "${signing[@]}"
  [[ -n "$udid" ]] && { xcrun simctl shutdown "$udid" 2>/dev/null || true; }
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$RESULTS/$app-$device" >/dev/null
  python3 scripts/file-screenshots.py "$RESULTS/$app-$device" "$OUT/$app" "$device"
}

viewer_ios() {
  dyld_cache iOS "$IOS_OS"
  shoot viewer-ios ViewerIOS "platform=iOS Simulator,id=$(simulator "$IPHONE" iOS "$IOS_OS")" iphone "dark,light" \
    "$(simulator "$IPHONE" iOS "$IOS_OS")"
  shoot viewer-ios ViewerIOS "platform=iOS Simulator,id=$(simulator "$IPAD" iOS "$IOS_OS")" ipad dark \
    "$(simulator "$IPAD" iOS "$IOS_OS")"
}
viewer_tv() {
  local udid
  dyld_cache tvOS "$TVOS_OS"
  udid=$(simulator "$TV" tvOS "$TVOS_OS")
  shoot viewer-tv ViewerTV "platform=tvOS Simulator,id=$udid" tv dark "$udid"
}
viewer_mac() { shoot viewer-mac ViewerMac "platform=macOS" mac dark; }
studio_ios() {
  dyld_cache iOS "$IOS_OS"
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
