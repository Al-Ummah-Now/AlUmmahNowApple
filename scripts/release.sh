#!/usr/bin/env bash
# Release builds, run only by .github/workflows/release.yml: scripts/release.sh <scheme> <config> <out-dir>
#   <scheme>  StudioMac | StudioIOS | ViewerIOS | ViewerTV | ViewerMac
#   <config>  Release (production) or QA
# Version and build number come from AUN_VERSION / AUN_BUILD_NUMBER (scripts/release-version.sh, from the tag).
#
# Without signing secrets it builds unsigned artifacts, so the pipeline is proven before the owner's Apple
# credentials exist, and says which secret is missing. With them:
#   StudioMac             Developer ID signed, notarized and stapled .zip and .dmg (attached to the GitHub release)
#   StudioIOS, ViewerIOS  App Store Connect upload (TestFlight, iPhone + iPad)
#   ViewerTV              App Store Connect upload (TestFlight, Apple TV)
#   ViewerMac             App Store Connect upload (TestFlight for Mac, Mac App Store build)
# Signing uses an App Store Connect API key (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8) with Xcode's automatic,
# cloud-managed signing for team APPLE_TEAM_ID; Studio for Mac can instead sign with an exported Developer ID
# Application certificate (DEVELOPER_ID_P12 base64, DEVELOPER_ID_P12_PASSWORD) in a throwaway keychain. Nothing secret
# is written to the repo; the key file lives in $RUNNER_TEMP and is deleted at exit.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="${1:?StudioMac|StudioIOS|ViewerIOS|ViewerTV|ViewerMac}"
CONFIG="${2:?Release|QA}"
OUT="${3:?out dir}"
case "$CONFIG" in Release | QA) ;; *) echo "config must be Release or QA" >&2; exit 2 ;; esac
case "$SCHEME" in
  StudioMac) KIND=developer-id; DEST="generic/platform=macOS"; FILE=AlUmmahNowStudio; TITLE="Al Ummah Now Studio" ;;
  StudioIOS) KIND=store; DEST="generic/platform=iOS"; FILE=AlUmmahNowStudio; TITLE="Al Ummah Now Studio"; OS=iOS ;;
  ViewerIOS) KIND=store; DEST="generic/platform=iOS"; FILE=AlUmmahNow; TITLE="Al Ummah Now"; OS=iOS ;;
  ViewerTV) KIND=store; DEST="generic/platform=tvOS"; FILE=AlUmmahNow; TITLE="Al Ummah Now"; OS=tvOS ;;
  ViewerMac) KIND=store-mac; DEST="generic/platform=macOS"; FILE=AlUmmahNow; TITLE="Al Ummah Now"; OS=macOS ;;
  *) echo "usage: $0 StudioMac|StudioIOS|ViewerIOS|ViewerTV|ViewerMac Release|QA <out-dir>" >&2; exit 2 ;;
esac
mkdir -p "$OUT"
DERIVED="${AUN_DERIVED_DATA:-build/DerivedData}"
WORK="${RUNNER_TEMP:-$(mktemp -d)}/aun-release-$SCHEME-$CONFIG"
rm -rf "$WORK" && mkdir -p "$WORK"
cleanup() {
  rm -f "$WORK/AuthKey.p8" "$WORK/developer-id.p12"
  [[ -f "$WORK/release.keychain-db" ]] && security delete-keychain "$WORK/release.keychain-db" || true
}
trap cleanup EXIT

SIGNED=0
AUTH=()
MISSING=()
for name in APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8; do
  [[ -n "${!name:-}" ]] || MISSING+=("$name")
done
if ((${#MISSING[@]} == 0)); then
  SIGNED=1
  printf '%s' "$ASC_KEY_P8" > "$WORK/AuthKey.p8"
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$WORK/AuthKey.p8"
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
else
  echo "::notice title=$SCHEME $CONFIG unsigned::Missing secret(s): ${MISSING[*]}. Built unsigned, nothing uploaded (docs/RELEASING.md)."
fi

VERSION="${AUN_VERSION:-0.1.0}"
BUILD="${AUN_BUILD_NUMBER:-1}"
COMMON=(-workspace AlUmmahNow.xcworkspace -derivedDataPath "$DERIVED" -configuration "$CONFIG"
        -skipPackagePluginValidation -skipMacroValidation
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD")
SUFFIX=$([[ "$CONFIG" == QA ]] && echo "-qa" || echo "")
PRETTY_SUFFIX=$([[ "$CONFIG" == QA ]] && echo " QA" || echo "")
ARCHIVE="$WORK/$SCHEME.xcarchive"
# Ad hoc and certificate-only signing have no provisioning profile, so they cannot carry universal links (restricted
# entitlements kill the app at launch); those builds use the Debug entitlements (sandbox only).
# (Only the Mac app targets read AUN_ENTITLEMENTS_VARIANT, so the package targets are untouched.)
PLAIN_ENTITLEMENTS="AUN_ENTITLEMENTS_VARIANT=.debug"

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

# The .app inside an archive.
archived_app() { echo "$ARCHIVE/Products/Applications/$(ls "$ARCHIVE/Products/Applications" | head -1)"; }

# A Mac app as a .zip (and a .dmg for Studio), under the app's display name.
package_mac() { # app name-without-extension with-dmg
  mkdir -p "$WORK/pkg"
  local pretty="$WORK/pkg/$TITLE$PRETTY_SUFFIX.app"
  ditto "$1" "$pretty"
  ditto -c -k --keepParent "$pretty" "$OUT/$2.zip"
  if [[ "$3" == dmg ]]; then
    ln -s /Applications "$WORK/pkg/Applications"
    hdiutil create -volname "$TITLE" -srcfolder "$WORK/pkg" -ov -format UDZO "$OUT/$2.dmg" >/dev/null
  fi
}

case "$KIND" in
  developer-id)
    NAME="$FILE$SUFFIX-$VERSION-macOS"
    if [[ $SIGNED == 1 && -n "${DEVELOPER_ID_P12:-}" ]]; then
      # A Developer ID Application certificate exported by the account holder, in a throwaway keychain.
      printf '%s' "$DEVELOPER_ID_P12" | base64 --decode > "$WORK/developer-id.p12"
      KEYCHAIN_PASSWORD=$(uuidgen)
      security create-keychain -p "$KEYCHAIN_PASSWORD" "$WORK/release.keychain-db"
      security set-keychain-settings -lut 3600 "$WORK/release.keychain-db"
      security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$WORK/release.keychain-db"
      security import "$WORK/developer-id.p12" -k "$WORK/release.keychain-db" -P "${DEVELOPER_ID_P12_PASSWORD:-}" \
        -T /usr/bin/codesign
      security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$WORK/release.keychain-db" >/dev/null
      security list-keychains -d user -s "$WORK/release.keychain-db" $(security list-keychains -d user | tr -d '"')
      echo "::notice title=$SCHEME $CONFIG::Signed with the DEVELOPER_ID_P12 certificate (no profile): universal links are left out of this build."
      xcodebuild archive "${COMMON[@]}" -scheme "$SCHEME" -destination "$DEST" \
        -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual "$PLAIN_ENTITLEMENTS" \
        CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES
      APP=$(archived_app)
    elif [[ $SIGNED == 1 ]]; then
      # Cloud-managed Developer ID signing through the API key (needs a key allowed to use it).
      xcodebuild archive "${COMMON[@]}" "${AUTH[@]}" -scheme "$SCHEME" -destination "$DEST" \
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
      xcodebuild archive "${COMMON[@]}" -scheme "$SCHEME" -destination "$DEST" \
        -archivePath "$ARCHIVE" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= "$PLAIN_ENTITLEMENTS"
      APP=$(archived_app)
      NAME="$NAME-unsigned"
    fi
    package_mac "$APP" "$NAME" dmg
    if [[ $SIGNED == 1 ]]; then
      xcrun notarytool submit "$OUT/$NAME.dmg" --key "$WORK/AuthKey.p8" --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER_ID" --wait --timeout 30m
      xcrun stapler staple "$OUT/$NAME.dmg"
    fi
    ;;
  store | store-mac)
    if [[ $SIGNED == 1 ]]; then
      xcodebuild archive "${COMMON[@]}" "${AUTH[@]}" -scheme "$SCHEME" -destination "$DEST" \
        -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic
      # Uploads to App Store Connect; the build appears in TestFlight after processing. Never submitted for review.
      export_options app-store-connect upload
      xcodebuild -exportArchive "${AUTH[@]}" -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
        -exportOptionsPlist "$WORK/ExportOptions.plist"
      echo "uploaded $SCHEME $VERSION ($BUILD) $CONFIG to App Store Connect" > "$OUT/$SCHEME$SUFFIX-upload.txt"
    elif [[ $KIND == store-mac ]]; then
      # Ad hoc, so the Mac app can be opened from the artifact (right-click Open the first time).
      xcodebuild archive "${COMMON[@]}" -scheme "$SCHEME" -destination "$DEST" -archivePath "$ARCHIVE" \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= "$PLAIN_ENTITLEMENTS"
      package_mac "$(archived_app)" "$FILE$SUFFIX-$VERSION-macOS-unsigned" no-dmg
    else
      # Proves the device build; an unsigned archive cannot be installed or uploaded.
      xcodebuild archive "${COMMON[@]}" -scheme "$SCHEME" -destination "$DEST" \
        -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
      ditto -c -k --keepParent "$ARCHIVE" "$OUT/$FILE$SUFFIX-$VERSION-$OS-unsigned.xcarchive.zip"
    fi
    ;;
esac
# The archive must carry the version and build number from the tag.
ARCHIVED=$(archived_app)
PLIST="$ARCHIVED/Contents/Info.plist"
[[ -f "$PLIST" ]] || PLIST="$ARCHIVED/Info.plist"
GOT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
GOT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
if [[ "$GOT_VERSION" != "$VERSION" || "$GOT_BUILD" != "$BUILD" ]]; then
  echo "::error::$SCHEME archived as $GOT_VERSION ($GOT_BUILD), expected $VERSION ($BUILD)"
  exit 1
fi
echo "$SCHEME $CONFIG: version $GOT_VERSION, build $GOT_BUILD"
ls -la "$OUT"
