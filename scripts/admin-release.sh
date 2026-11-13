#!/usr/bin/env bash
# Admin app releases, run only by .github/workflows/admin-release.yml: scripts/admin-release.sh ios|mac <config>
#   <config> is Release (production) or QA.
# The Admin app is internal (wiki AUN-ADMIN-NATIVE, AD10): TestFlight internal testing only. Nothing is written for
# download: no GitHub release, no workflow artifact, no .dmg (the repo is public).
# With the owner's App Store Connect key (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8) and APPLE_TEAM_ID it archives with
# automatic, cloud-managed signing and uploads to App Store Connect. Without them it builds an unsigned archive and
# throws it away, so the pipeline is proven before the credentials exist.
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:?ios|mac}"
CONFIG="${2:?Release|QA}"
DERIVED="${AUN_DERIVED_DATA:-build/DerivedData}"
WORK="${RUNNER_TEMP:-$(mktemp -d)}/aun-admin-$PLATFORM-$CONFIG"
rm -rf "$WORK" && mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

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

case "$PLATFORM" in
  ios) SCHEME=AdminIOS; DEST="generic/platform=iOS" ;;
  mac) SCHEME=AdminMac; DEST="generic/platform=macOS" ;;
  *) echo "usage: $0 ios|mac Release|QA" >&2; exit 2 ;;
esac
ARCHIVE="$WORK/$SCHEME.xcarchive"

if [[ $SIGNED == 1 ]]; then
  EXTRA=()
  [[ $PLATFORM == mac ]] && EXTRA=(ENABLE_HARDENED_RUNTIME=YES)
  xcodebuild archive "${COMMON[@]}" "${AUTH[@]}" -scheme "$SCHEME" -destination "$DEST" -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic "${EXTRA[@]}"
  cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>testFlightInternalTestingOnly</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
  # Uploads to App Store Connect; the build is for internal TestFlight testers only and never goes to review.
  xcodebuild -exportArchive "${AUTH[@]}" -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
    -exportOptionsPlist "$WORK/ExportOptions.plist"
  echo "uploaded $SCHEME $VERSION ($BUILD) $CONFIG to TestFlight (internal only)"
else
  xcodebuild archive "${COMMON[@]}" -scheme "$SCHEME" -destination "$DEST" -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  echo "built $SCHEME $VERSION ($BUILD) $CONFIG unsigned; nothing kept (no Apple secrets)"
fi
