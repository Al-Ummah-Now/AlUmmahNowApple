#!/usr/bin/env bash
# One entry point shared by CI and local runs: scripts/ci.sh lint|ios|ipad|tvos|mac|studio|live-qa
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_OS="${AUN_IOS_SIM_OS:-26.4}"
TVOS_OS="${AUN_TVOS_SIM_OS:-26.4}"
DERIVED="${AUN_DERIVED_DATA:-build/DerivedData}"
COMMON=(-workspace AlUmmahNow.xcworkspace -derivedDataPath "$DERIVED" -configuration Debug
        -skipPackagePluginValidation -skipMacroValidation)
UNSIGNED=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
ADHOC=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)

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
  live-qa)
    # Real sign-in against auth.qa. Signed to run locally (ad hoc), because the Keychain needs entitlements.
    : "${AUN_QA_EMAIL:?}" "${AUN_QA_PASSWORD:?}"
    TEST_RUNNER_AUN_LIVE_QA=1 TEST_RUNNER_AUN_QA_EMAIL="$AUN_QA_EMAIL" TEST_RUNNER_AUN_QA_PASSWORD="$AUN_QA_PASSWORD" \
      xcodebuild test "${COMMON[@]}" -scheme StudioIOS \
      -only-testing:StudioIOSUITests/LiveQASignInTests/testSignInThroughAuthAndSignOut \
      -destination "platform=iOS Simulator,name=iPhone 17,OS=$IOS_OS" "${ADHOC[@]}"
    ;;
  *) echo "usage: $0 lint|ios|ipad|tvos|mac|studio|live-qa" >&2; exit 2 ;;
esac
