#!/usr/bin/env bash
# One entry point shared by CI and local runs:
# scripts/ci.sh lint|ios|ipad|tvos|mac|studio|admin|admin-ipad|admin-mac|live-qa|boot <job>
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_OS="${AUN_IOS_SIM_OS:-26.4}"
TVOS_OS="${AUN_TVOS_SIM_OS:-26.4}"
DERIVED="${AUN_DERIVED_DATA:-build/DerivedData}"
COMMON=(-workspace AlUmmahNow.xcworkspace -derivedDataPath "$DERIVED" -configuration Debug
        -skipPackagePluginValidation -skipMacroValidation)
UNSIGNED=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
# Ad hoc Mac builds drop Associated Domains: macOS kills an app claiming it without a provisioning profile.
ADHOC=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= AUN_MAC_ENTITLEMENTS_VARIANT=.adhoc)
IPHONE="iPhone 17"
IPAD="iPad Pro 11-inch (M5)"

# The simulator xcodebuild would pick for a name on $IOS_OS, by UDID.
sim_udid() {
  python3 - "$1" "$IOS_OS" <<'PY'
import json, subprocess, sys
name, version = sys.argv[1], sys.argv[2]
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", "runtimes"]))["runtimes"]
ids = [r["identifier"] for r in runtimes if r.get("version") == version and r.get("isAvailable", True)]
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", "devices", "available"]))["devices"]
for rid in ids:
    for d in devices.get(rid, []):
        if d["name"] == name:
            print(d["udid"]); sys.exit(0)
sys.exit(f"no {name} simulator on iOS {version}")
PY
}

# Freshly booted simulators run system work for several minutes; on a 3-vCPU runner that starved the Admin app's main
# thread for 25-30 s (and failed launches outright) on the first UI tests of a pass. Boot early, test once settled.
boot_early() { dyld_cache; local udid; udid=$(sim_udid "$1"); xcrun simctl boot "$udid" 2>/dev/null || true; echo "$udid"; }
# Without the runtime's dyld shared cache every simulator process loads its frameworks one by one, which made app
# launches several times slower. Build it when the runner image lacks it (a no-op when it exists) and log which.
dyld_cache() {
  local runtime waited=0
  runtime=$(xcrun simctl list -j runtimes | python3 -c 'import json,sys; v=sys.argv[1]; print(next(r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("version") == v))' "$IOS_OS")
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
settled() { local udid; udid=$(sim_udid "$1"); xcrun simctl bootstatus "$udid" -b >/dev/null; echo "$udid"; }

case "${1:-}" in
  lint)
    "${SWIFTLINT:-swiftlint}" lint --strict --quiet
    find Apps Packages UITests -name "*.swift" -not -name Package.swift -not -path "*/.build/*" -print0 | xargs -0 xcrun swift-format lint --strict
    ;;
  ios)
    xcodebuild test "${COMMON[@]}" -scheme ViewerIOS \
      -destination "platform=iOS Simulator,name=iPhone 17,OS=$IOS_OS" "${UNSIGNED[@]}"
    ;;
  ipad)
    xcodebuild test "${COMMON[@]}" -scheme ViewerIOS -only-testing:ViewerIOSUITests \
      -destination "platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=$IOS_OS" "${UNSIGNED[@]}"
    ;;
  tvos)
    xcodebuild test "${COMMON[@]}" -scheme ViewerTV \
      -destination "platform=tvOS Simulator,name=Apple TV,OS=$TVOS_OS" "${UNSIGNED[@]}"
    ;;
  mac)
    xcodebuild test "${COMMON[@]}" -scheme ViewerMac -destination "platform=macOS" "${ADHOC[@]}"
    ;;
  studio)
    xcodebuild test "${COMMON[@]}" -scheme StudioIOS \
      -destination "platform=iOS Simulator,name=iPhone 17,OS=$IOS_OS" "${UNSIGNED[@]}"
    xcodebuild test "${COMMON[@]}" -scheme StudioMac -destination "platform=macOS" "${ADHOC[@]}"
    ;;
  boot)
    # CI runs this first, so the simulator settles while the job installs tools and builds.
    case "${2:-}" in
      admin) boot_early "$IPHONE" ;;
      admin-ipad) boot_early "$IPAD" ;;
      *) echo "boot: nothing to boot early for ${2:-}" ;;
    esac
    ;;
  admin)
    # The Admin app on fixtures (no network, no pushes, no AI): unit tests and UI flows on iPhone. iPad: admin-ipad.
    UDID=$(settled "$IPHONE")
    xcodebuild test "${COMMON[@]}" -scheme AdminIOS -destination "platform=iOS Simulator,id=$UDID" "${UNSIGNED[@]}"
    ;;
  admin-ipad)
    UDID=$(settled "$IPAD")
    xcodebuild test "${COMMON[@]}" -scheme AdminIOS -only-testing:AdminIOSUITests \
      -destination "platform=iOS Simulator,id=$UDID" "${UNSIGNED[@]}"
    ;;
  admin-mac)
    xcodebuild test "${COMMON[@]}" -scheme AdminMac -destination "platform=macOS" "${ADHOC[@]}"
    ;;
  live-qa)
    # Real sign-in, upload and manage against auth.qa and videos.api.qa, as the QA creator. Signed to run locally
    # (ad hoc), because the Keychain needs entitlements. Upload runs first; manage then cleans up its uploads.
    : "${AUN_QA_EMAIL:?}" "${AUN_QA_PASSWORD:?}"
    LIVE=(TEST_RUNNER_AUN_LIVE_QA=1 TEST_RUNNER_AUN_QA_EMAIL="$AUN_QA_EMAIL" TEST_RUNNER_AUN_QA_PASSWORD="$AUN_QA_PASSWORD")
    for tests in "LiveQASignInTests LiveQAUploadTests" "LiveQAManageTests"; do
      ONLY=()
      for test in $tests; do ONLY+=("-only-testing:StudioIOSUITests/$test"); done
      env "${LIVE[@]}" TEST_RUNNER_AUN_EXPECT_TEST_UPLOADS=1 xcodebuild test "${COMMON[@]}" -scheme StudioIOS "${ONLY[@]}" \
        -destination "platform=iOS Simulator,name=iPhone 17,OS=$IOS_OS" "${ADHOC[@]}"
    done
    ;;
  *) echo "usage: $0 lint|ios|ipad|tvos|mac|studio|admin|admin-ipad|admin-mac|live-qa|boot <job>" >&2; exit 2 ;;
esac
