#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_ACTIONS:?GITHUB_ACTIONS is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${RUNNER_ENVIRONMENT:?RUNNER_ENVIRONMENT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${XCODE_APP:?XCODE_APP is required}"

MIN_FREE_GIB="${MIN_FREE_GIB:-110}"
audit_file="$RUNNER_TEMP/ue5-macos-runner-space-reclaim.txt"
rows_file="$RUNNER_TEMP/ue5-macos-runner-space-reclaim-rows.md"

cleanup() {
  rm -f "$rows_file"
}
trap cleanup EXIT

disk_free_gib() {
  df -Pk / | awk 'NR == 2 { print int($4 / 1024 / 1024) }'
}

fail() {
  {
    echo 'UE5_MACOS_RUNNER_SPACE_RECLAIM_FAILED'
    printf 'disk_free_gib=%s\n' "$(disk_free_gib)"
    printf 'error=%s\n' "$*"
  } >> "$audit_file"
  echo "::error::$*"
  exit 1
}

remove_target() {
  local label="$1"
  local target="$2"
  local size_kib
  local size_mib

  case "$target" in
    /Users/runner/Library/Developer/CoreSimulator | \
    /Library/Developer/CoreSimulator | \
    /Users/runner/Library/Android | \
    /Users/runner/hostedtoolcache | \
    '/Applications/Google Chrome.app' | \
    '/Applications/Microsoft Edge.app' | \
    /Applications/Firefox.app)
      ;;
    *)
      fail "Refusing to remove a path outside the hosted-runner reclaim allowlist: ${target}"
      ;;
  esac

  if ! test -e "$target"; then
    printf '%s=missing\n' "$label" >> "$audit_file"
    printf '| `%s` | `missing` |\n' "$label" >> "$rows_file"
    return
  fi
  test ! -L "$target" || fail "Refusing to remove a symbolic link: ${target}"
  test -d "$target" || fail "Reclaim target is not a directory: ${target}"

  size_kib="$(sudo du -sk "$target" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  [[ "$size_kib" =~ ^[0-9]+$ ]] || fail "Could not measure reclaim target: ${target}"
  size_mib="$(( (size_kib + 1023) / 1024 ))"

  echo "Removing hosted-runner-only disk consumer: ${label} (${size_mib} MiB logical)"
  sudo rm -rf -- "$target" || fail "Could not remove hosted-runner target: ${target}"
  test ! -e "$target" || fail "Hosted-runner target still exists after removal: ${target}"

  printf '%s_removed_mib=%s\n' "$label" "$size_mib" >> "$audit_file"
  printf '| `%s` | `%s MiB` |\n' "$label" "$size_mib" >> "$rows_file"
}

umask 077
: > "$audit_file"
: > "$rows_file"

test "$GITHUB_ACTIONS" = true || fail 'Reclaim is restricted to GitHub Actions.'
test "$RUNNER_ENVIRONMENT" = github-hosted || fail 'Reclaim is restricted to a GitHub-hosted runner.'
test "$(uname -s)" = Darwin || fail 'Reclaim is restricted to macOS.'
test "$(id -un)" = runner || fail 'Reclaim requires the ephemeral runner account.'
case "$RUNNER_TEMP" in
  /Users/runner/work/_temp | /Users/runner/work/_temp/*)
    ;;
  *)
    fail 'RUNNER_TEMP is outside the expected ephemeral runner path.'
    ;;
esac
test -d "$XCODE_APP/Contents/Developer" || fail 'The selected Xcode is missing before reclaim.'
test "$(xcode-select -p)" = "$XCODE_APP/Contents/Developer" ||
  fail 'The selected Xcode changed before reclaim.'

disk_before_gib="$(disk_free_gib)"
printf 'disk_free_before_gib=%s\n' "$disk_before_gib" >> "$audit_file"

remove_target runner_core_simulator /Users/runner/Library/Developer/CoreSimulator
remove_target system_core_simulator /Library/Developer/CoreSimulator
remove_target android_sdk /Users/runner/Library/Android
remove_target hosted_toolcache /Users/runner/hostedtoolcache
remove_target google_chrome '/Applications/Google Chrome.app'
remove_target microsoft_edge '/Applications/Microsoft Edge.app'
remove_target firefox /Applications/Firefox.app

test -d "$XCODE_APP/Contents/Developer" || fail 'The selected Xcode was removed during reclaim.'
test "$(xcode-select -p)" = "$XCODE_APP/Contents/Developer" ||
  fail 'The selected Xcode changed during reclaim.'
xcodebuild -version
xcrun --sdk macosx --find clang >/dev/null
xcrun --sdk iphoneos --find clang >/dev/null
xcrun --sdk iphoneos --show-sdk-version >/dev/null

disk_after_gib="$(disk_free_gib)"
reclaimed_gib="$((disk_after_gib - disk_before_gib))"
printf 'disk_free_after_gib=%s\n' "$disk_after_gib" >> "$audit_file"
printf 'disk_reclaimed_gib=%s\n' "$reclaimed_gib" >> "$audit_file"
printf 'minimum_required_free_gib=%s\n' "$MIN_FREE_GIB" >> "$audit_file"

(( disk_after_gib >= MIN_FREE_GIB )) ||
  fail "Hosted-runner reclaim left ${disk_after_gib} GiB free; at least ${MIN_FREE_GIB} GiB is required."

echo 'UE5_MACOS_RUNNER_SPACE_RECLAIM_SUCCESS' >> "$audit_file"

{
  echo '## Hosted macOS source-build space reclaim'
  echo
  echo '| Removed class | Logical size |'
  echo '| --- | ---: |'
  sed -n '1,200p' "$rows_file"
  echo
  printf 'Free disk increased from `%s GiB` to `%s GiB` (`%s GiB` actual).\n' \
    "$disk_before_gib" "$disk_after_gib" "$reclaimed_gib"
  printf 'MacOSX and iPhoneOS toolchains remain available through `%s`.\n' "$XCODE_APP"
} >> "$GITHUB_STEP_SUMMARY"

printf 'Hosted macOS runner reclaim completed with %s GiB free.\n' "$disk_after_gib"
