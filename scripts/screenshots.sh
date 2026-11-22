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
        -skipPackagePluginValidation -skipMacroValidation
        # Store frames show the app's real name: no " QA" suffix in the status bar, Dock or window title.
        AUN_DISPLAY_SUFFIX=)
IPHONE="iPhone 17 Pro Max"
IPAD="iPad Pro 13-inch (M5)"
TV="Apple TV 4K (3rd generation)"
AUN_SCREENSHOT_LANGUAGES="${AUN_SCREENSHOT_LANGUAGES:-en,ar}"
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

# The status bar clock at 9:41 in every language. simctl's --time draws Latin digits and rejects an Arabic string, so
# with AUN_FREEZE_CLOCK=1 (the CI workflow) the clock itself is held at 09:41 today: the simulator follows the host
# clock, and each language's system draws it in its own digits, «٩:٤١» in Arabic. A background loop sets the host
# back to 09:41:00 every 20 seconds during the simulator passes, so the minute never turns, and network time is
# restored when the script exits. Only on an ephemeral GitHub-hosted runner, never on someone's own Mac.
freeze_clock_pid=""
freeze_real_start=0
freeze_mono_start=0
freeze_clock() {
  [[ "${AUN_FREEZE_CLOCK:-0}" == 1 ]] || return 0
  if [[ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
    echo "AUN_FREEZE_CLOCK needs a GitHub-hosted runner; keeping the live clock" >&2
    return 0
  fi
  # The real time and a monotonic reading, so thaw_clock can put the real time back without the network.
  freeze_real_start=$(date -u +%s)
  freeze_mono_start=$(python3 -I -c 'import time; print(int(time.monotonic()))')
  sudo systemsetup -setusingnetworktime off >/dev/null 2>&1 || true
  (while :; do sudo date "$(date +%m%d)0941$(date +%y)" >/dev/null; sleep 20; done) &
  freeze_clock_pid=$!
  sleep 1
  echo "clock held at $(date)"
}
thaw_clock() {
  [[ -n "$freeze_clock_pid" ]] || return 0
  kill "$freeze_clock_pid" 2>/dev/null || true
  wait "$freeze_clock_pid" 2>/dev/null || true
  freeze_clock_pid=""
  local real
  real=$((freeze_real_start + $(python3 -I -c 'import time; print(int(time.monotonic()))') - freeze_mono_start))
  sudo date -u "$(date -u -r "$real" +%m%d%H%M%Y.%S)" >/dev/null
  sudo sntp -sS time.apple.com >/dev/null 2>&1 || true
  sudo systemsetup -setusingnetworktime on >/dev/null 2>&1 || true
  echo "clock restored: $(date)"
}
virtual_display_pid=""
stop_virtual_display() { [[ -z "$virtual_display_pid" ]] || kill "$virtual_display_pid" 2>/dev/null || true; }
trap 'thaw_clock; stop_virtual_display' EXIT

# Battery, signal and, unless the clock is held (above), a 9:41 override for English. Errors are not hidden: a pass
# without its overrides fails instead of filing wrong frames.
status_bar_overrides() { # udid lang
  local clock=()
  [[ "$2" == ar || -n "$freeze_clock_pid" ]] || clock=(--time "9:41")
  xcrun simctl status_bar "$1" clear &&
    xcrun simctl status_bar "$1" override ${clock[@]+"${clock[@]}"} --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
}

# Runs one target's StoreScreenshots test and files its attachments as <app>/<locale>/<device>-….png.
# On a simulator: only that simulator runs (the previous pass's one is shut down), it boots before the build so its
# first-boot system work settles while xcodebuild compiles, and the test starts once it has finished booting.
# Two simulators, or a freshly booted one, on the 3-vCPU runner timed out the iPad pass ("Timed out waiting for AX
# loaded notification", "Timed out while requesting screenshot"; #47).
shoot() { # app scheme destination device themes [udid]
  local app="$1" scheme="$2" destination="$3" device="$4" themes="$5" udid="${6:-}"
  local signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  [[ "$destination" == "platform=macOS" ]] && signing=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)
  if [[ -n "$udid" ]]; then
    xcrun simctl shutdown all 2>/dev/null || true
    xcrun simctl boot "$udid" 2>/dev/null || true
  fi
  xcodebuild build-for-testing "${COMMON[@]}" -scheme "$scheme" -destination "$destination" "${signing[@]}"
  # One pass per language. On a simulator the system itself switches language (and Eastern Arabic digits), so its own
  # chrome matches the app: the status bar's app name comes from the app's InfoPlist.strings and the clock uses Arabic digits.
  local lang
  [[ -z "$udid" ]] || freeze_clock
  for lang in ${AUN_SCREENSHOT_LANGUAGES//,/ }; do
    local bundle="$RESULTS/$app-$device-$lang.xcresult"
    rm -rf "$bundle" "$RESULTS/$app-$device-$lang"
    if [[ -n "$udid" ]]; then
      local prefs="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/Preferences/.GlobalPreferences.plist"
      local locale="en_US"
      [[ "$lang" == ar ]] && locale="ar_SA@calendar=gregorian;numbers=arab"
      xcrun simctl shutdown "$udid" 2>/dev/null || true
      # plutil edits the file in place (as fastlane snapshot does); `defaults write` on a path goes through cfprefsd's
      # cache and the booted simulator never saw it. The log line proves which language the pass runs in.
      [[ -f "$prefs" ]] || { mkdir -p "$(dirname "$prefs")"; plutil -create xml1 "$prefs"; }
      plutil -replace AppleLanguages -json "[\"$lang\"]" "$prefs"
      plutil -replace AppleLocale -string "$locale" "$prefs"
      echo "simulator $udid: $(plutil -extract AppleLanguages json -o - "$prefs") $(plutil -extract AppleLocale raw -o - "$prefs")"
      # iPad apps full screen: with windowed multitasking (Stage Manager style windows) on, every iPad frame showed the
      # window's resize corner. SpringBoard reads these when it starts, so they are written before the boot.
      if [[ "$device" == ipad ]]; then
        local board="${prefs%/*}/com.apple.springboard.plist"
        [[ -f "$board" ]] || plutil -create xml1 "$board"
        plutil -replace SBChamoisWindowingEnabled -bool NO "$board"
        plutil -replace SBMedusaMultitaskingEnabled -bool NO "$board"
        echo "simulator $udid: windowing $(plutil -extract SBChamoisWindowingEnabled raw -o - "$board")"
      fi
      # Boot, wait and set the status bar as one step with one retry: on the shared runner a boot sometimes dies
      # mid-way, and the status bar call then fails on a shut-down simulator (SimError 405).
      local booted=0 try
      for try in 1 2; do
        xcrun simctl boot "$udid" 2>/dev/null || true
        if xcrun simctl bootstatus "$udid" -b >/dev/null && xcrun simctl list devices booted | grep -q "$udid" \
          && status_bar_overrides "$udid" "$lang"; then
          booted=1
          break
        fi
        echo "simulator $udid did not come up for $lang (try $try)"
        xcrun simctl shutdown "$udid" 2>/dev/null || true
      done
      ((booted)) || { echo "simulator $udid failed to boot twice" >&2; return 1; }
    fi
    # One retry: the shared runner sometimes loses the test runner while it bootstraps, or an app won't terminate.
    local attempt
    for attempt in 1 2; do
      rm -rf "$bundle"
      if TEST_RUNNER_AUN_SCREENSHOTS=1 TEST_RUNNER_AUN_REVIEW_SHOTS="${AUN_REVIEW_SHOTS:-0}" \
        TEST_RUNNER_AUN_SCREENSHOT_THEMES="${AUN_SCREENSHOT_THEMES:-$themes}" \
        TEST_RUNNER_AUN_SCREENSHOT_LANGUAGES="$lang" \
        xcodebuild test-without-building "${COMMON[@]}" -scheme "$scheme" -destination "$destination" \
        -only-testing:"${scheme}UITests/StoreScreenshots" -resultBundlePath "$bundle" "${signing[@]}"; then
        break
      fi
      ((attempt == 2)) && return 1
      echo "screenshot pass $app $device $lang failed, retrying once"
    done
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$RESULTS/$app-$device-$lang" >/dev/null
    python3 scripts/file-screenshots.py "$RESULTS/$app-$device-$lang" "$OUT/$app" "$device"
  done
  if [[ -n "$udid" ]]; then xcrun simctl shutdown "$udid" 2>/dev/null || true; fi
  thaw_clock
}

viewer_ios() {
  dyld_cache iOS "$IOS_OS"
  # iPad first: after the iPhone pass, GitHub's runner cancelled the job while the iPad simulator ran (#75).
  shoot viewer-ios ViewerIOS "platform=iOS Simulator,id=$(simulator "$IPAD" iOS "$IOS_OS")" ipad dark \
    "$(simulator "$IPAD" iOS "$IOS_OS")"
  shoot viewer-ios ViewerIOS "platform=iOS Simulator,id=$(simulator "$IPHONE" iOS "$IOS_OS")" iphone "dark,light" \
    "$(simulator "$IPHONE" iOS "$IOS_OS")"
}
viewer_tv() {
  local udid
  dyld_cache tvOS "$TVOS_OS"
  udid=$(simulator "$TV" tvOS "$TVOS_OS")
  shoot viewer-tv ViewerTV "platform=tvOS Simulator,id=$udid" tv dark "$udid"
}
# Mac review frames at the window's native 2x. GitHub's hosted runner has one 1x display (1024x768, 1x modes up to
# 1920x1080, none HiDPI), so a HiDPI virtual display (scripts/virtual-display.m) becomes the main one and the windows
# open there. If the runner refuses it, the display goes to 1920x1080 so the window keeps its full 1100x680 pt size at
# 1x. Never fails the run; the frames are cropped to the window with no upscaling and no letterbox
# (scripts/file-screenshots.py).
hidpi_display() {
  [[ "${AUN_REVIEW_SHOTS:-0}" == 1 && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || return 0
  command -v displayplacer >/dev/null || brew install -q displayplacer >/dev/null 2>&1 || return 0
  local list phys vid="" big tool="build/virtual-display" ids="build/virtual-display.id"
  list=$(displayplacer list 2>&1 || true)
  printf '%s\n' "$list" | grep -E "Persistent screen id|Contextual screen id|Resolution:|Scaling" | head -12 || true
  phys=$(printf '%s\n' "$list" | awk '/Contextual screen id:/ {print $4; exit}' || true)
  mkdir -p build
  if clang -fobjc-arc -framework Foundation -framework CoreGraphics scripts/virtual-display.m -o "$tool" 2>&1; then
    "$tool" >"$ids" 2>&1 &
    virtual_display_pid=$!
    sleep 3
    vid=$(head -1 "$ids" | grep -E '^[0-9]+$' || true)
  fi
  if [[ -n "$vid" && -n "$phys" ]] &&
    displayplacer "id:$vid res:1440x900 scaling:on origin:(0,0) degree:0" "id:$phys origin:(1440,0) degree:0"; then
    sleep 3
    echo "virtual HiDPI display $vid is the main display"
  else
    echo "virtual display: $(cat "$ids" 2>/dev/null | head -2 | xargs || true)"
    stop_virtual_display
    virtual_display_pid=""
    big=$(printf '%s\n' "$list" | grep -E "mode [0-9]+: res:1920x1080" | head -1 | sed -E 's/^ *mode ([0-9]+):.*/\1/' || true)
    [[ -z "$phys" || -z "$big" ]] || displayplacer "id:$phys mode:$big" || true
    sleep 3
  fi
  echo "display: $(system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Resolution|UI Looks like|Main Display' | head -6 | xargs || true)"
}

viewer_mac() {
  hidpi_display
  shoot viewer-mac ViewerMac "platform=macOS" mac dark
}
studio_ios() {
  dyld_cache iOS "$IOS_OS"
  # iPad first: after the iPhone pass, GitHub's runner cancelled the job while the iPad simulator ran (#75).
  shoot studio-ios StudioIOS "platform=iOS Simulator,id=$(simulator "$IPAD" iOS "$IOS_OS")" ipad dark \
    "$(simulator "$IPAD" iOS "$IOS_OS")"
  shoot studio-ios StudioIOS "platform=iOS Simulator,id=$(simulator "$IPHONE" iOS "$IOS_OS")" iphone "dark,light" \
    "$(simulator "$IPHONE" iOS "$IOS_OS")"
}
studio_mac() {
  hidpi_display
  shoot studio-mac StudioMac "platform=macOS" mac dark
}

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
