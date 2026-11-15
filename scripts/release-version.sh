#!/usr/bin/env bash
# Version and build number for a release run, printed as GITHUB_OUTPUT lines (version=, build=, release=):
#   scripts/release-version.sh <ref_type> <ref_name> <run_number> [run_attempt]
#
# Tag vX.Y.Z[-N] (N = rebuild of the same version, 1-99; Y, Z < 100):
#   CFBundleShortVersionString = X.Y.Z
#   CFBundleVersion            = ((X*100 + Y)*100 + Z)*100 + N      v1.2.3 → 1020300, v1.2.3-2 → 1020302
#   so every tag gets its own, always increasing build number, which App Store Connect requires.
# Anything else (workflow_dispatch from a branch) never uploads: version 0.0.<run>, build 0.<run>.<attempt>. A build
# number below 1 sorts under every tag's number, so a dev build can never take or block a release's number.
set -euo pipefail

REF_TYPE="${1:?ref type}"
REF_NAME="${2:?ref name}"
RUN="${3:?run number}"
ATTEMPT="${4:-1}"

if [[ "$REF_TYPE" == tag ]]; then
  if [[ ! "$REF_NAME" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9]+))?$ ]]; then
    echo "::error::tag must be vX.Y.Z or vX.Y.Z-N (got $REF_NAME)" >&2
    exit 1
  fi
  X=$((10#${BASH_REMATCH[1]})) Y=$((10#${BASH_REMATCH[2]})) Z=$((10#${BASH_REMATCH[3]})) N=$((10#${BASH_REMATCH[5]:-0}))
  if ((Y > 99 || Z > 99 || N > 99)); then
    echo "::error::minor, patch and rebuild must each be below 100 (got $REF_NAME)" >&2
    exit 1
  fi
  if ((X > 20000)); then
    echo "::error::major $X is too large for a build number (got $REF_NAME)" >&2
    exit 1
  fi
  echo "version=$X.$Y.$Z"
  echo "build=$(( ((X * 100 + Y) * 100 + Z) * 100 + N ))"
  echo "release=true"
else
  echo "version=0.0.$RUN"
  echo "build=0.$RUN.$ATTEMPT"
  echo "release=false"
fi
