#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
build_dir="${SLEEP_SWITCH_BUILD_DIR:-$script_dir/build}"
dist_dir="$script_dir/dist"
archive="$dist_dir/Sleep-Switch.zip"

"$script_dir/build.sh"
mkdir -p "$dist_dir"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$build_dir/Sleep Switch.app" "$archive"

echo "$archive"
