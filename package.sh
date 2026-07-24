#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
dist_dir="$script_dir/dist"
archive="$dist_dir/Sleep-Switch.zip"

"$script_dir/build.sh"
mkdir -p "$dist_dir"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$script_dir/build/Sleep Switch.app" "$archive"

echo "$archive"
