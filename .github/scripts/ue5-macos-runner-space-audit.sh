#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${XCODE_APP:?XCODE_APP is required}"

audit_file="$RUNNER_TEMP/ue5-macos-runner-space-audit.txt"
rows_file="$RUNNER_TEMP/ue5-macos-runner-space-rows.md"

cleanup() {
  rm -f "$rows_file"
}
trap cleanup EXIT

disk_free_gib() {
  df -Pk / | awk 'NR == 2 { print int($4 / 1024 / 1024) }'
}

measure_path() {
  local label="$1"
  local path="$2"
  local size_kib
  local size_mib

  if ! test -e "$path"; then
    printf '%s=missing\n' "$label" >> "$audit_file"
    printf '| `%s` | `missing` |\n' "$label" >> "$rows_file"
    return
  fi

  if ! size_kib="$(sudo du -sk "$path" 2>/dev/null | awk 'NR == 1 { print $1 }')"; then
    printf '%s=unreadable\n' "$label" >> "$audit_file"
    printf '| `%s` | `unreadable` |\n' "$label" >> "$rows_file"
    return
  fi
  [[ "$size_kib" =~ ^[0-9]+$ ]] || {
    printf '%s=unreadable\n' "$label" >> "$audit_file"
    printf '| `%s` | `unreadable` |\n' "$label" >> "$rows_file"
    return
  }

  size_mib="$(( (size_kib + 1023) / 1024 ))"
  printf '%s_mib=%s\n' "$label" "$size_mib" >> "$audit_file"
  printf '| `%s` | `%s MiB` |\n' "$label" "$size_mib" >> "$rows_file"
}

umask 077
: > "$audit_file"
: > "$rows_file"

test "$(uname -s)" = Darwin
test -d "$XCODE_APP/Contents/Developer"

echo 'UE5_MACOS_RUNNER_SPACE_AUDIT_SUCCESS' >> "$audit_file"
printf 'disk_free_gib=%s\n' "$(disk_free_gib)" >> "$audit_file"

measure_path applications /Applications
measure_path selected_xcode "$XCODE_APP"
measure_path android_sdk /Users/runner/Library/Android
measure_path runner_caches /Users/runner/Library/Caches
measure_path runner_core_simulator /Users/runner/Library/Developer/CoreSimulator
measure_path system_core_simulator /Library/Developer/CoreSimulator
measure_path rustup /Users/runner/.rustup
measure_path cargo /Users/runner/.cargo
measure_path homebrew /opt/homebrew
measure_path usr_local /usr/local
measure_path google_chrome '/Applications/Google Chrome.app'
measure_path microsoft_edge '/Applications/Microsoft Edge.app'
measure_path firefox /Applications/Firefox.app

toolcache_path="${AGENT_TOOLSDIRECTORY:-/Users/runner/hostedtoolcache}"
case "$toolcache_path" in
  /Users/runner/*)
    measure_path hosted_toolcache "$toolcache_path"
    ;;
  *)
    echo 'hosted_toolcache=untrusted-path' >> "$audit_file"
    echo '| `hosted_toolcache` | `untrusted path` |' >> "$rows_file"
    ;;
esac

platforms_root="$XCODE_APP/Contents/Developer/Platforms"
measure_path xcode_iphone_simulator "$platforms_root/iPhoneSimulator.platform"
measure_path xcode_appletv_device "$platforms_root/AppleTVOS.platform"
measure_path xcode_appletv_simulator "$platforms_root/AppleTVSimulator.platform"
measure_path xcode_watch_device "$platforms_root/WatchOS.platform"
measure_path xcode_watch_simulator "$platforms_root/WatchSimulator.platform"
measure_path xcode_vision_device "$platforms_root/XROS.platform"
measure_path xcode_vision_simulator "$platforms_root/XRSimulator.platform"
measure_path xcode_driverkit "$platforms_root/DriverKit.platform"

{
  echo '## Hosted macOS runner space audit'
  echo
  printf 'Free disk after versioned Xcode cleanup: `%s GiB`.\n' "$(disk_free_gib)"
  echo
  echo '| Path class | Logical size |'
  echo '| --- | ---: |'
  sed -n '1,200p' "$rows_file"
} >> "$GITHUB_STEP_SUMMARY"

echo 'Hosted macOS runner space audit completed.'
