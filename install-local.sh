#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source_app="${SLEEP_SWITCH_INSTALL_APP:-$script_dir/build/Sleep Switch.app}"
install_dir="${SLEEP_SWITCH_INSTALL_DIR:-/Applications}"
target_app="$install_dir/Sleep Switch.app"
mode="${1:---check}"

case "$mode" in
  --check|--install|--replace)
    ;;
  *)
    echo "Usage: ./install-local.sh [--check|--install|--replace]"
    exit 64
    ;;
esac

if [[ ! -d "$source_app" \
   || ! -x "$source_app/Contents/MacOS/SleepSwitch" ]]; then
  echo "Sleep Switch app not found: $source_app"
  exit 1
fi

sleep_disabled="$(
  /usr/bin/pmset -g \
    | /usr/bin/awk \
        '$1 == "SleepDisabled" && !found { print $2; found = 1 }
         END { if (!found) exit 1 }'
)"
if [[ "$sleep_disabled" != "0" ]]; then
  echo "Refusing installation: macOS normal sleep is not verified."
  echo "Expected pmset to report SleepDisabled 0."
  exit 1
fi

SLEEP_SWITCH_DIRECT_APP="$source_app" \
SLEEP_SWITCH_REQUIRE_DISTRIBUTION_SIGNATURE=1 \
  "$script_dir/test-direct.sh"

if /usr/bin/pgrep -x SleepSwitch >/dev/null 2>&1; then
  echo "Quit Sleep Switch before installing or replacing it."
  exit 1
fi

if /bin/launchctl print \
    system/lt.mantas.sleepswitch.fanhelper \
    >/dev/null 2>&1; then
  echo "Remove the Cooling Helper from the current app before replacing it."
  exit 1
fi

if [[ "$mode" == "--check" ]]; then
  echo "Sleep Switch is ready for a safe local install."
  exit 0
fi

if [[ ! -d "$install_dir" || ! -w "$install_dir" ]]; then
  echo "Install directory is not writable: $install_dir"
  echo "This script never invokes sudo."
  exit 1
fi

if [[ -e "$target_app" && "$mode" != "--replace" ]]; then
  echo "Sleep Switch is already installed."
  echo "Use --replace to preserve it as a timestamped backup."
  exit 1
fi

staging_root="$(
  /usr/bin/mktemp -d "$install_dir/.sleep-switch-install.XXXXXX"
)"
staged_app="$staging_root/Sleep Switch.app"

cleanup_staging() {
  if [[ -n "${staging_root:-}" \
     && "$staging_root" == "$install_dir"/.sleep-switch-install.* \
     && -d "$staging_root" ]]; then
    /bin/rm -rf -- "$staging_root"
  fi
}

stop_installation() {
  trap - INT TERM
  cleanup_staging
  exit 130
}

trap cleanup_staging EXIT
trap stop_installation INT TERM

/usr/bin/ditto "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$staged_app"

backup_app=""
if [[ -e "$target_app" ]]; then
  timestamp="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
  backup_app="$install_dir/Sleep Switch.backup.$timestamp.$$.app"
  /bin/mv "$target_app" "$backup_app"
fi

if ! /bin/mv "$staged_app" "$target_app"; then
  if [[ -n "$backup_app" && -e "$backup_app" ]]; then
    if ! /bin/mv "$backup_app" "$target_app"; then
      echo "Installation failed and the previous app could not be restored."
      echo "Previous app remains at: $backup_app"
      exit 1
    fi
    echo "Installation failed; the previous app was restored."
  else
    echo "Installation failed; no app was installed."
  fi
  exit 1
fi

if ! /usr/bin/codesign \
    --verify --deep --strict --verbose=4 "$target_app"; then
  if ! /bin/mv "$target_app" "$staged_app"; then
    echo "Installed copy failed verification and remains at: $target_app"
    if [[ -n "$backup_app" && -e "$backup_app" ]]; then
      echo "Previous app remains at: $backup_app"
    fi
    exit 1
  fi
  if [[ -n "$backup_app" && -e "$backup_app" ]] \
     && ! /bin/mv "$backup_app" "$target_app"; then
    echo "Installed copy failed verification and was moved aside."
    echo "Previous app could not be restored and remains at: $backup_app"
    exit 1
  fi
  if [[ -n "$backup_app" ]]; then
    echo "Installed copy failed verification; the previous app was restored."
  else
    echo "Installed copy failed verification; no app was installed."
  fi
  exit 1
fi

echo "Installed: $target_app"
if [[ -n "$backup_app" ]]; then
  echo "Previous app preserved at: $backup_app"
fi
echo "Sleep Switch was not launched automatically."
