#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
build_dir="${SLEEP_SWITCH_BUILD_DIR:-$script_dir/build}"
dist_dir="$script_dir/dist"
archive="$dist_dir/Sleep-Switch.zip"
signing_identity="${SLEEP_SWITCH_SIGNING_IDENTITY:--}"
notary_profile="${SLEEP_SWITCH_NOTARY_PROFILE:-}"
require_distribution_signature="${SLEEP_SWITCH_REQUIRE_DISTRIBUTION_SIGNATURE:-0}"

if [[ "$require_distribution_signature" == "1" ]]; then
  if [[ "$signing_identity" == "-" || -z "$notary_profile" ]]; then
    echo "Distribution packaging requires SLEEP_SWITCH_SIGNING_IDENTITY and SLEEP_SWITCH_NOTARY_PROFILE."
    echo "Configure the Developer ID certificate and a notarytool keychain profile before publishing a release."
    exit 1
  fi
fi

"$script_dir/build.sh"
mkdir -p "$dist_dir"

create_archive() {
  rm -f "$archive"
  ditto -c -k --sequesterRsrc --keepParent \
    "$build_dir/Sleep Switch.app" \
    "$archive"
}

create_archive

if [[ -n "$notary_profile" ]]; then
  if [[ "$signing_identity" == "-" ]]; then
    echo "Notarization requires SLEEP_SWITCH_SIGNING_IDENTITY."
    exit 1
  fi

  xcrun notarytool submit \
    "$archive" \
    --keychain-profile "$notary_profile" \
    --wait
  xcrun stapler staple "$build_dir/Sleep Switch.app"
  xcrun stapler validate "$build_dir/Sleep Switch.app"
  create_archive

  SLEEP_SWITCH_DIRECT_APP="$build_dir/Sleep Switch.app" \
  SLEEP_SWITCH_REQUIRE_DISTRIBUTION_SIGNATURE=1 \
    "$script_dir/test-direct.sh"
elif [[ "$signing_identity" != "-" ]]; then
  echo "Warning: the signed archive is not notarized; set SLEEP_SWITCH_NOTARY_PROFILE."
fi

echo "$archive"
