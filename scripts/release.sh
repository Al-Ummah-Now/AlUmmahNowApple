#!/usr/bin/env bash
# Release builds, run only by .github/workflows/release.yml: scripts/release.sh mac|ios <config> <out-dir>
#   <config> is Release (production) or QA.
# Without signing secrets it builds unsigned artifacts, so the pipeline is proven before the owner's Apple
# credentials exist. With them:
#   mac: Developer ID signed, notarized and stapled .zip and .dmg (attached to the GitHub release)
#   ios: an App Store Connect upload (TestFlight)
# Signing uses an App Store Connect API key (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8) with Xcode's automatic,
# cloud-managed signing for team APPLE_TEAM_ID; the Mac can instead sign with an exported Developer ID Application
# certificate (DEVELOPER_ID_P12 base64, DEVELOPER_ID_P12_PASSWORD) in a throwaway keychain. Nothing secret is written to the repo; the key file lives in
# $RUNNER_TEMP and is deleted at exit.
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:?mac|ios}"
CONFIG="${2:?Release|QA}"
OUT="${3:?out dir}"
mkdir -p "$OUT"
DERIVED="${AUN_DERIVED_DATA:-build/DerivedData}"
WORK="${RUNNER_TEMP:-$(mktemp -d)}/aun-release-$PLATFORM-$CONFIG"
rm -rf "$WORK" && mkdir -p "$WORK"
cleanup() {
  rm -f "$WORK/AuthKey.p8" "$WORK/developer-id.p12"
  [[ -f "$WORK/release.keychain-db" ]] && security delete-keychain "$WORK/release.keychain-db" || true
}
trap cleanup EXIT

SIGNED=0
AUTH=()
if [[ -n "${ASC_KEY_P8:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  SIGNED=1
  printf '%s' "$ASC_KEY_P8" > "$WORK/AuthKey.p8"
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$WORK/AuthKey.p8"
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

VERSION="${AUN_VERSION:-0.1.0}"
BUILD="${AUN_BUILD_NUMBER:-1}"
COMMON=(-workspace AlUmmahNow.xcworkspace -derivedDataPath "$DERIVED" -configuration "$CONFIG"
        -skipPackagePluginValidation -skipMacroValidation
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD")
SUFFIX=$([[ "$CONFIG" == QA ]] && echo "-qa" || echo "")

export_options() { # method destination
  cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>$1</string>
  <key>destination</key><string>$2</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${APPLE_TEAM_ID:-}</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
}

case "$PLATFORM" in
  mac)
    ARCHIVE="$WORK/StudioMac.xcarchive"
    NAME="AlUmmahNowStudio$SUFFIX-$VERSION-macOS"
    if [[ $SIGNED == 1 && -n "${DEVELOPER_ID_P12:-}" ]]; then
      # A Developer ID Application certificate exported by the account holder, in a throwaway keychain. Manual
      # signing has no provisioning profile, so this build leaves out Associated Domains (no native passkeys; the
      # "Sign in another way" browser flow still works). The cloud-managed path below keeps them.
      printf '%s' "$DEVELOPER_ID_P12" | base64 --decode > "$WORK/developer-id.p12"
      KEYCHAIN_PASSWORD=$(uuidgen)
      security create-keychain -p "$KEYCHAIN_PASSWORD" "$WORK/release.keychain-db"
      security set-keychain-settings -lut 3600 "$WORK/release.keychain-db"
      security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$WORK/release.keychain-db"
      security import "$WORK/developer-id.p12" -k "$WORK/release.keychain-db" -P "${DEVELOPER_ID_P12_PASSWORD:-}" \
        -T /usr/bin/codesign
      security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$WORK/release.keychain-db" >/dev/null
      security list-keychains -d user -s "$WORK/release.keychain-db" $(security list-keychains -d user | tr -d '"')
      xcodebuild archive "${COMMON[@]}" -scheme StudioMac -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES \
        AUN_MAC_ENTITLEMENTS_VARIANT=.adhoc
      APP="$ARCHIVE/Products/Applications/$(ls "$ARCHIVE/Products/Applications" | head -1)"
    elif [[ $SIGNED == 1 ]]; then
      # Cloud-managed Developer ID signing through the API key (needs a key allowed to use it).
      xcodebuild archive "${COMMON[@]}" "${AUTH[@]}" -scheme StudioMac -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic ENABLE_HARDENED_RUNTIME=YES
      export_options developer-id export
      xcodebuild -exportArchive "${AUTH[@]}" -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
        -exportOptionsPlist "$WORK/ExportOptions.plist"
      APP=$(find "$WORK/export" -maxdepth 1 -name "*.app" | head -1)
    fi
    if [[ $SIGNED == 1 ]]; then
      ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
      xcrun notarytool submit "$WORK/notarize.zip" --key "$WORK/AuthKey.p8" --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER_ID" --wait --timeout 30m
      xcrun stapler staple "$APP"
      spctl --assess --type execute --verbose=2 "$APP"
    else
      # Ad hoc: runs on the machine that builds it; other Macs need a right-click Open (Gatekeeper).
      xcodebuild archive "${COMMON[@]}" -scheme StudioMac -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
        AUN_MAC_ENTITLEMENTS_VARIANT=.adhoc
      APP="$ARCHIVE/Products/Applications/$(ls "$ARCHIVE/Products/Applications" | head -1)"
      NAME="$NAME-unsigned"
    fi
    # Ship the bundle under the app's name (the folder name is not part of the signature).
    mkdir -p "$WORK/pkg"
    PRETTY="$WORK/pkg/Al Ummah Now Studio$([[ "$CONFIG" == QA ]] && echo " QA").app"
    ditto "$APP" "$PRETTY"
    APP="$PRETTY"
    ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"
    ln -s /Applications "$WORK/pkg/Applications"
    hdiutil create -volname "Al Ummah Now Studio" -srcfolder "$WORK/pkg" -ov -format UDZO "$OUT/$NAME.dmg" >/dev/null
    if [[ $SIGNED == 1 ]]; then
      xcrun notarytool submit "$OUT/$NAME.dmg" --key "$WORK/AuthKey.p8" --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER_ID" --wait --timeout 30m
      xcrun stapler staple "$OUT/$NAME.dmg"
    fi
    ;;
  ios)
    ARCHIVE="$WORK/StudioIOS.xcarchive"
    if [[ $SIGNED == 1 ]]; then
      xcodebuild archive "${COMMON[@]}" "${AUTH[@]}" -scheme StudioIOS -destination "generic/platform=iOS" \
        -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic
      # Uploads to App Store Connect; the build appears in TestFlight after processing.
      export_options app-store-connect upload
      xcodebuild -exportArchive "${AUTH[@]}" -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
        -exportOptionsPlist "$WORK/ExportOptions.plist"
      echo "uploaded StudioIOS $VERSION ($BUILD) $CONFIG to App Store Connect" > "$OUT/StudioIOS$SUFFIX-upload.txt"
    else
      # Proves the device build; an unsigned archive cannot be installed or uploaded.
      xcodebuild archive "${COMMON[@]}" -scheme StudioIOS -destination "generic/platform=iOS" \
        -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
      ditto -c -k --keepParent "$ARCHIVE" "$OUT/AlUmmahNowStudio$SUFFIX-$VERSION-iOS-unsigned.xcarchive.zip"
    fi
    ;;
  *) echo "usage: $0 mac|ios Release|QA <out-dir>" >&2; exit 2 ;;
esac
ls -la "$OUT"
