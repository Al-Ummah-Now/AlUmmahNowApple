#!/usr/bin/env bash
# Checks scripts/release-version.sh: scripts/test-release-version.sh (CI runs it in the store job).
set -euo pipefail
cd "$(dirname "$0")"
fail=0
expect() { # args... -- expected
  local out want="${*: -1}"
  out=$(./release-version.sh "${@:1:$#-1}" 2>/dev/null | tr '\n' ' ' | sed 's/ $//') || out="error"
  if [[ "$out" != "$want" ]]; then echo "FAIL: $* → '$out'"; fail=1; else echo "ok: ${*:1:$#-1} → $out"; fi
}
expect tag v1.2.3 7 "version=1.2.3 build=1020300 release=true"
expect tag v1.2.3-2 7 "version=1.2.3 build=1020302 release=true"
expect tag v0.1.0 7 "version=0.1.0 build=10000 release=true"
expect tag v2026.11.14 7 "version=2026.11.14 build=2026111400 release=true"
expect tag v1.10.0 7 "version=1.10.0 build=1100000 release=true"
expect tag v01.02.03 7 "version=1.2.3 build=1020300 release=true"
expect branch main 42 3 "version=0.0.42 build=0.42.3 release=false"
expect branch feat/x 42 "version=0.0.42 build=0.42.1 release=false"
expect tag v1.2 7 "error"
expect tag v1.2.3-beta 7 "error"
expect tag 1.2.3 7 "error"
expect tag v1.100.0 7 "error"
expect tag v1.2.3-100 7 "error"
expect tag admin-v1.2.3 7 "error"
# Every later tag gets a higher build number.
prev=0
for tag in v0.1.0 v0.1.1 v0.2.0 v0.2.0-1 v0.2.0-2 v1.0.0 v1.0.1 v2026.1.1 v2026.11.14 v2026.11.14-1; do
  build=$(./release-version.sh tag "$tag" 1 | sed -n 's/^build=//p')
  if ((build <= prev)); then echo "FAIL: $tag build $build is not above $prev"; fail=1; fi
  prev=$build
done
exit $fail
