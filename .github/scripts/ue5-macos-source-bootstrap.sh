#!/usr/bin/env bash

set -euo pipefail

: "${BOOTSTRAP_STAGE:?BOOTSTRAP_STAGE is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${UE5_VERSION:?UE5_VERSION is required}"

SOURCE_DIR="${SOURCE_DIR:-$GITHUB_WORKSPACE/ue5-source}"
audit_file="$RUNNER_TEMP/ue5-macos-source-bootstrap.txt"
setup_log="$RUNNER_TEMP/ue5-macos-source-setup.log"
generate_log="$RUNNER_TEMP/ue5-macos-source-generate.log"
disk_reserve="$RUNNER_TEMP/ue5-macos-source-disk-reserve"

reserve_allocated=false
current_phase=checkout

release_reserve() {
  if test "$reserve_allocated" = true; then
    rm -f "$disk_reserve"
    reserve_allocated=false
  fi
}

cleanup() {
  release_reserve
  rm -f "$setup_log" "$generate_log"
}
trap cleanup EXIT

disk_free_kib() {
  df -Pk / | awk 'NR == 2 { print $4 }'
}

disk_free_gib() {
  echo "$(( $(disk_free_kib) / 1024 / 1024 ))"
}

directory_size_mib() {
  du -sk "$1" | awk '{ print int(($1 + 1023) / 1024) }'
}

fail() {
  release_reserve
  {
    echo 'UE5_MACOS_SOURCE_BOOTSTRAP_FAILED'
    printf 'stage=%s\n' "$BOOTSTRAP_STAGE"
    printf 'phase=%s\n' "$current_phase"
    printf 'disk_free_gib=%s\n' "$(disk_free_gib)"
    printf 'error=%s\n' "$*"
  } >> "$audit_file"
  echo "::error::$*"
  exit 1
}

run_source_command() {
  local log_file="$1"
  local command_path="$2"
  local command_status
  local tee_status
  local pipeline_status

  set +e
  (
    cd "$SOURCE_DIR"
    "$command_path"
  ) 2>&1 | tee "$log_file"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e

  command_status="${pipeline_status[0]}"
  tee_status="${pipeline_status[1]}"
  if test "$tee_status" != 0; then
    return "$tee_status"
  fi
  return "$command_status"
}

umask 077
: > "$audit_file"

case "$BOOTSTRAP_STAGE" in
  checkout | setup | generate)
    ;;
  *)
    fail 'BOOTSTRAP_STAGE must be checkout, setup, or generate.'
    ;;
esac

test "$(uname -s)" = Darwin || fail 'This bootstrap must run on macOS.'
command -v git >/dev/null || fail 'git is unavailable.'
command -v jq >/dev/null || fail 'jq is unavailable.'
command -v mkfile >/dev/null || fail 'mkfile is unavailable.'
test -d "$SOURCE_DIR/.git" || fail 'The Unreal Engine source checkout is missing.'

build_version_file="$SOURCE_DIR/Engine/Build/Build.version"
setup_command="$SOURCE_DIR/Setup.command"
generate_command="$SOURCE_DIR/GenerateProjectFiles.command"
test -f "$build_version_file" || fail 'The source checkout has no Engine/Build/Build.version.'
test -x "$setup_command" || fail 'The source checkout has no executable Setup.command.'
test -x "$generate_command" || fail 'The source checkout has no executable GenerateProjectFiles.command.'

build_version="$(jq -c . "$build_version_file")" || fail 'Build.version is not valid JSON.'
printf '%s\n' "$build_version" | jq --exit-status --arg version "$UE5_VERSION" '
  ($version | split(".") | map(tonumber)) as $expected |
  ($expected | length) == 3 and
  .MajorVersion == $expected[0] and
  .MinorVersion == $expected[1] and
  .PatchVersion == $expected[2]
' >/dev/null || fail "The source checkout is not UE ${UE5_VERSION}."

source_sha="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'The source checkout commit is invalid.'
tracked_changes_before="$(git -C "$SOURCE_DIR" status --short --untracked-files=no)"
test -z "$tracked_changes_before" || fail 'The exact source checkout has tracked modifications before setup.'

disk_before_gib="$(disk_free_gib)"
source_checkout_mib="$(directory_size_mib "$SOURCE_DIR")"
source_after_setup_mib="$source_checkout_mib"
source_final_mib="$source_checkout_mib"
setup_seconds=0
generate_seconds=0
workspace_count=0
tracked_changes_after=false

if test "$BOOTSTRAP_STAGE" != checkout; then
  current_phase=reserve-disk
  reserve_start="$(date +%s)"
  mkfile 4g "$disk_reserve" || fail 'Could not allocate the 4 GiB emergency disk reserve.'
  reserve_allocated=true
  reserve_seconds="$(( $(date +%s) - reserve_start ))"
  test -f "$disk_reserve" || fail 'The emergency disk reserve is missing.'

  current_phase=setup
  setup_start="$(date +%s)"
  if ! run_source_command "$setup_log" "$setup_command"; then
    fail 'Epic Setup.command failed; inspect the live Actions log for its console output.'
  fi
  setup_seconds="$(( $(date +%s) - setup_start ))"
  rm -f "$setup_log"
  source_after_setup_mib="$(directory_size_mib "$SOURCE_DIR")"

  test -d "$SOURCE_DIR/Engine/Source" || fail 'Setup removed the Engine source directory unexpectedly.'
  test -x "$SOURCE_DIR/Engine/Build/BatchFiles/RunUAT.sh" ||
    fail 'Setup did not leave an executable RunUAT.sh.'

  if test "$BOOTSTRAP_STAGE" = generate; then
    current_phase=generate-project-files
    generate_start="$(date +%s)"
    if ! run_source_command "$generate_log" "$generate_command"; then
      fail 'GenerateProjectFiles.command failed; inspect the live Actions log for its console output.'
    fi
    generate_seconds="$(( $(date +%s) - generate_start ))"
    rm -f "$generate_log"

    for workspace in "$SOURCE_DIR"/*.xcworkspace; do
      test -e "$workspace" || continue
      workspace_count=$((workspace_count + 1))
    done
    test -d "$SOURCE_DIR/UE5 (Mac).xcworkspace" || fail 'The Mac source workspace was not generated.'
    test -d "$SOURCE_DIR/UE5 (IOS).xcworkspace" || fail 'The iOS source workspace was not generated.'
  fi

  source_final_mib="$(directory_size_mib "$SOURCE_DIR")"
  if test -n "$(git -C "$SOURCE_DIR" status --short --untracked-files=no)"; then
    tracked_changes_after=true
  fi
else
  reserve_seconds=0
fi

current_phase=complete
release_reserve
disk_after_gib="$(disk_free_gib)"

{
  echo 'UE5_MACOS_SOURCE_BOOTSTRAP_SUCCESS'
  printf 'stage=%s\n' "$BOOTSTRAP_STAGE"
  printf 'ue5_version=%s\n' "$UE5_VERSION"
  printf 'source_sha=%s\n' "$source_sha"
  printf 'disk_free_before_gib=%s\n' "$disk_before_gib"
  printf 'disk_free_after_gib=%s\n' "$disk_after_gib"
  printf 'source_checkout_mib=%s\n' "$source_checkout_mib"
  printf 'source_after_setup_mib=%s\n' "$source_after_setup_mib"
  printf 'source_final_mib=%s\n' "$source_final_mib"
  printf 'reserve_allocation_seconds=%s\n' "$reserve_seconds"
  printf 'setup_seconds=%s\n' "$setup_seconds"
  printf 'generate_seconds=%s\n' "$generate_seconds"
  printf 'workspace_count=%s\n' "$workspace_count"
  printf 'tracked_changes_after=%s\n' "$tracked_changes_after"
} > "$audit_file"

{
  echo '## UE 5.5.4 hosted macOS source bootstrap'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  printf '| Stage | `%s` |\n' "$BOOTSTRAP_STAGE"
  printf '| Exact source | `UE %s` at `%s` |\n' "$UE5_VERSION" "$source_sha"
  printf '| Source size checkout / post-setup / final | `%s MiB` / `%s MiB` / `%s MiB` |\n' \
    "$source_checkout_mib" "$source_after_setup_mib" "$source_final_mib"
  printf '| Setup / project generation | `%s s` / `%s s` |\n' "$setup_seconds" "$generate_seconds"
  printf '| Generated Xcode workspaces | `%s` |\n' "$workspace_count"
  printf '| Free disk before / after | `%s GiB` / `%s GiB` |\n' "$disk_before_gib" "$disk_after_gib"
  printf '| Tracked source changes after bootstrap | `%s` |\n' "$tracked_changes_after"
  echo '| Licensed source artifact upload | `disabled` |'
} >> "$GITHUB_STEP_SUMMARY"

printf 'UE %s hosted macOS source bootstrap completed at stage %s.\n' "$UE5_VERSION" "$BOOTSTRAP_STAGE"
