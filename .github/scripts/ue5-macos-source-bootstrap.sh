#!/usr/bin/env bash

set -euo pipefail

: "${BOOTSTRAP_STAGE:?BOOTSTRAP_STAGE is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${UE5_VERSION:?UE5_VERSION is required}"

SOURCE_DIR="${SOURCE_DIR:-$GITHUB_WORKSPACE/ue5-source}"
SETUP_EXCLUDES="${SETUP_EXCLUDES:-Android,Linux,LinuxArm64,Win32,Win64,HoloLens,TVOS}"
DISK_RESERVE_GIB="${DISK_RESERVE_GIB:-12}"
XCODE_APP="${XCODE_APP:?XCODE_APP is required for the Intel source path}"
EXPECTED_HOST_ARCH="${EXPECTED_HOST_ARCH:-x86_64}"
EXPECTED_RUNNER_ARCH="${EXPECTED_RUNNER_ARCH:-X64}"
EXPECTED_XCODE_VERSION="${EXPECTED_XCODE_VERSION:-16.4}"
EXPECTED_XCODE_BUILD="${EXPECTED_XCODE_BUILD:-16F6}"
EXPECTED_IPHONEOS_SDK="${EXPECTED_IPHONEOS_SDK:-18.5}"
BUILD_COMPILER_ARGUMENTS="-Wno-shorten-64-to-32"
FBX_REDBLACKTREE_SHA256_BEFORE="cd5891b83493f1335302eedf2f62498ce5b42d9a9fdaa4fc02d2437194522c1b"
FBX_REDBLACKTREE_SHA256_AFTER="49efee242da7c0381dcb56f524c496e0f95d19bd39ba20367ba893c52d3d6a97"
audit_file="$RUNNER_TEMP/ue5-macos-source-bootstrap.txt"
setup_log="$RUNNER_TEMP/ue5-macos-source-setup.log"
generate_log="$RUNNER_TEMP/ue5-macos-source-generate.log"
build_log="$RUNNER_TEMP/ue5-macos-source-build.log"
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
  rm -f "$setup_log" "$generate_log" "$build_log"
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
    printf 'setup_excludes=%s\n' "$SETUP_EXCLUDES"
    echo 'setup_cache=disabled'
    echo 'setup_threads=3'
    echo 'build_max_parallel_actions=2'
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
  shift 2

  set +e
  (
    cd "$SOURCE_DIR"
    "$command_path" "$@"
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
  checkout | setup | generate | build)
    ;;
  *)
    fail 'BOOTSTRAP_STAGE must be checkout, setup, generate, or build.'
    ;;
esac

test "$(uname -s)" = Darwin || fail 'This bootstrap must run on macOS.'
test "$EXPECTED_HOST_ARCH" = x86_64 || fail 'EXPECTED_HOST_ARCH must be x86_64 for the Intel source path.'
test "$EXPECTED_RUNNER_ARCH" = X64 || fail 'EXPECTED_RUNNER_ARCH must be X64 for the Intel source path.'
host_arch="$(uname -m)"
test "$host_arch" = "$EXPECTED_HOST_ARCH" || fail "The source path requires ${EXPECTED_HOST_ARCH}; found ${host_arch}."
if [[ -n "${RUNNER_ARCH:-}" ]]; then
  test "$RUNNER_ARCH" = "$EXPECTED_RUNNER_ARCH" || fail 'The GitHub runner architecture is not X64.'
fi
command -v git >/dev/null || fail 'git is unavailable.'
command -v jq >/dev/null || fail 'jq is unavailable.'
command -v mkfile >/dev/null || fail 'mkfile is unavailable.'
command -v perl >/dev/null || fail 'perl is unavailable.'
command -v shasum >/dev/null || fail 'shasum is unavailable.'
command -v xcodebuild >/dev/null || fail 'xcodebuild is unavailable.'
command -v xcode-select >/dev/null || fail 'xcode-select is unavailable.'
command -v xcrun >/dev/null || fail 'xcrun is unavailable.'
command -v lipo >/dev/null || fail 'lipo is unavailable.'
test -d "$XCODE_APP/Contents/Developer" || fail "Required Xcode is missing: ${XCODE_APP}"
sudo xcode-select --switch "$XCODE_APP/Contents/Developer" ||
  fail 'Could not select the required Xcode developer directory.'
test "$(xcode-select -p)" = "$XCODE_APP/Contents/Developer" ||
  fail 'xcode-select did not retain the requested developer directory.'
xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
xcode_build="$(xcodebuild -version | awk 'NR == 2 { print $3 }')"
iphoneos_sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
test "$xcode_version" = "$EXPECTED_XCODE_VERSION" ||
  fail "The selected Xcode version is ${xcode_version}; expected ${EXPECTED_XCODE_VERSION}."
test "$xcode_build" = "$EXPECTED_XCODE_BUILD" ||
  fail "The selected Xcode build is ${xcode_build}; expected ${EXPECTED_XCODE_BUILD}."
test "$iphoneos_sdk" = "$EXPECTED_IPHONEOS_SDK" ||
  fail "The selected iPhoneOS SDK is ${iphoneos_sdk}; expected ${EXPECTED_IPHONEOS_SDK}."
test -d "$SOURCE_DIR/.git" || fail 'The Unreal Engine source checkout is missing.'

build_version_file="$SOURCE_DIR/Engine/Build/Build.version"
setup_command="$SOURCE_DIR/Setup.sh"
generate_command="$SOURCE_DIR/GenerateProjectFiles.command"
build_command="$SOURCE_DIR/Engine/Build/BatchFiles/Mac/Build.sh"
editor_services_dir="$HOME/Library/Services"
test -f "$build_version_file" || fail 'The source checkout has no Engine/Build/Build.version.'
test -x "$setup_command" || fail 'The source checkout has no executable Setup.sh.'
test -x "$generate_command" || fail 'The source checkout has no executable GenerateProjectFiles.command.'
test -x "$build_command" || fail 'The source checkout has no executable Mac Build.sh.'
test ! -L "$editor_services_dir" || fail 'The user Services directory must not be a symbolic link.'
mkdir -p "$editor_services_dir" || fail 'Could not create the user Services directory required by Epic Setup.sh.'
test -d "$editor_services_dir" || fail 'The user Services directory required by Epic Setup.sh is unavailable.'

setup_args=(--force --no-cache --threads=3)
old_ifs="$IFS"
IFS=,
read -r -a setup_exclude_items <<< "$SETUP_EXCLUDES"
IFS="$old_ifs"
test "${#setup_exclude_items[@]}" -gt 0 || fail 'SETUP_EXCLUDES must name at least one non-target platform.'
for setup_exclude in "${setup_exclude_items[@]}"; do
  [[ "$setup_exclude" =~ ^[A-Za-z0-9_]+$ ]] || fail 'SETUP_EXCLUDES contains an invalid folder name.'
  setup_args+=("--exclude=$setup_exclude")
done

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
build_seconds=0
editor_arch=not-built
shader_worker_arch=not-built
editor_binary_bytes=0
fbx_redblacktree_patch=not-required

if test "$BOOTSTRAP_STAGE" != checkout; then
  current_phase=reserve-disk
  reserve_start="$(date +%s)"
  [[ "$DISK_RESERVE_GIB" =~ ^[0-9]+$ ]] || fail 'DISK_RESERVE_GIB must be an integer.'
  (( DISK_RESERVE_GIB >= 4 )) || fail 'DISK_RESERVE_GIB must be at least 4 GiB.'
  mkfile "${DISK_RESERVE_GIB}g" "$disk_reserve" ||
    fail "Could not allocate the ${DISK_RESERVE_GIB} GiB emergency disk reserve."
  reserve_allocated=true
  reserve_seconds="$(( $(date +%s) - reserve_start ))"
  test -f "$disk_reserve" || fail 'The emergency disk reserve is missing.'

  current_phase=setup
  setup_start="$(date +%s)"
  if ! run_source_command "$setup_log" "$setup_command" "${setup_args[@]}"; then
    fail 'Epic Setup.sh failed; inspect the live Actions log for its console output.'
  fi
  setup_seconds="$(( $(date +%s) - setup_start ))"
  rm -f "$setup_log"
  source_after_setup_mib="$(directory_size_mib "$SOURCE_DIR")"

  test -d "$SOURCE_DIR/Engine/Source" || fail 'Setup removed the Engine source directory unexpectedly.'
  test -x "$SOURCE_DIR/Engine/Build/BatchFiles/RunUAT.sh" ||
    fail 'Setup did not leave an executable RunUAT.sh.'

  if test "$BOOTSTRAP_STAGE" = generate || test "$BOOTSTRAP_STAGE" = build; then
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

  if test "$BOOTSTRAP_STAGE" = build; then
    current_phase=apply-xcode-compatibility
    fbx_redblacktree_file="$SOURCE_DIR/Engine/Source/ThirdParty/FBX/2020.2/include/fbxsdk/core/base/fbxredblacktree.h"
    test -f "$fbx_redblacktree_file" || fail 'The FBX red-black tree header is missing.'
    fbx_redblacktree_sha256="$(shasum -a 256 "$fbx_redblacktree_file" | awk '{ print $1 }')"
    case "$fbx_redblacktree_sha256" in
      "$FBX_REDBLACKTREE_SHA256_BEFORE")
        perl -0pi -e 's/mLefttChild/mLeftChild/g' "$fbx_redblacktree_file" ||
          fail 'Could not apply the UE 5.5.4 FBX red-black tree compatibility correction.'
        fbx_redblacktree_patch=applied
        ;;
      "$FBX_REDBLACKTREE_SHA256_AFTER")
        fbx_redblacktree_patch=already-applied
        ;;
      *)
        fail 'The UE 5.5.4 FBX red-black tree header does not match the audited compatibility input.'
        ;;
    esac
    test "$(shasum -a 256 "$fbx_redblacktree_file" | awk '{ print $1 }')" = "$FBX_REDBLACKTREE_SHA256_AFTER" ||
      fail 'The UE 5.5.4 FBX red-black tree compatibility correction failed verification.'

    current_phase=build-unreal-editor
    build_start="$(date +%s)"
    if ! run_source_command "$build_log" "$build_command" \
      UnrealEditor Mac Development \
      -buildscw \
      -MaxParallelActions=2 \
      -CompilerArguments="$BUILD_COMPILER_ARGUMENTS" \
      -NoUBA \
      -NoUBALocal \
      -NoXGE \
      -NoFASTBuild \
      -NoSNDBS \
      -NoArtifactReads \
      -NoArtifactWrites
    then
      fail 'UnrealEditor Mac Development build failed; inspect the live Actions log for its console output.'
    fi
    build_seconds="$(( $(date +%s) - build_start ))"
    rm -f "$build_log"

    editor_binary="$SOURCE_DIR/Engine/Binaries/Mac/UnrealEditor.app/Contents/MacOS/UnrealEditor"
    shader_worker="$SOURCE_DIR/Engine/Binaries/Mac/ShaderCompileWorker"
    test -x "$editor_binary" || fail 'The source build did not produce an executable UnrealEditor.'
    test -x "$shader_worker" || fail 'The source build did not produce an executable ShaderCompileWorker.'
    editor_arch="$(lipo -archs "$editor_binary" 2>/dev/null)" ||
      fail 'Could not inspect the UnrealEditor Mach-O architecture.'
    test "$editor_arch" = "$EXPECTED_HOST_ARCH" ||
      fail "The UnrealEditor binary architecture is ${editor_arch}; expected ${EXPECTED_HOST_ARCH}."
    shader_worker_arch="$(lipo -archs "$shader_worker" 2>/dev/null)" ||
      fail 'Could not inspect the ShaderCompileWorker Mach-O architecture.'
    test "$shader_worker_arch" = "$EXPECTED_HOST_ARCH" ||
      fail "The ShaderCompileWorker architecture is ${shader_worker_arch}; expected ${EXPECTED_HOST_ARCH}."
    editor_binary_bytes="$(stat -f '%z' "$editor_binary")"
    [[ "$editor_binary_bytes" =~ ^[0-9]+$ ]] || fail 'Could not measure the UnrealEditor binary.'
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
  printf 'host_arch=%s\n' "$host_arch"
  printf 'xcode_app=%s\n' "$XCODE_APP"
  printf 'xcode_version=%s\n' "$xcode_version"
  printf 'xcode_build=%s\n' "$xcode_build"
  printf 'iphoneos_sdk=%s\n' "$iphoneos_sdk"
  printf 'disk_free_before_gib=%s\n' "$disk_before_gib"
  printf 'disk_free_after_gib=%s\n' "$disk_after_gib"
  printf 'source_checkout_mib=%s\n' "$source_checkout_mib"
  printf 'source_after_setup_mib=%s\n' "$source_after_setup_mib"
  printf 'source_final_mib=%s\n' "$source_final_mib"
  printf 'setup_excludes=%s\n' "$SETUP_EXCLUDES"
  echo 'setup_cache=disabled'
  echo 'setup_threads=3'
  printf 'disk_reserve_gib=%s\n' "$DISK_RESERVE_GIB"
  echo 'build_max_parallel_actions=2'
  printf 'build_compiler_arguments=%s\n' "$BUILD_COMPILER_ARGUMENTS"
  printf 'fbx_redblacktree_patch=%s\n' "$fbx_redblacktree_patch"
  printf 'reserve_allocation_seconds=%s\n' "$reserve_seconds"
  printf 'setup_seconds=%s\n' "$setup_seconds"
  printf 'generate_seconds=%s\n' "$generate_seconds"
  printf 'build_seconds=%s\n' "$build_seconds"
  printf 'workspace_count=%s\n' "$workspace_count"
  printf 'editor_arch=%s\n' "$editor_arch"
  printf 'shader_worker_arch=%s\n' "$shader_worker_arch"
  printf 'editor_binary_bytes=%s\n' "$editor_binary_bytes"
  printf 'tracked_changes_after=%s\n' "$tracked_changes_after"
} > "$audit_file"

{
  echo '## UE 5.5.4 hosted macOS source bootstrap'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  printf '| Stage | `%s` |\n' "$BOOTSTRAP_STAGE"
  printf '| Exact source | `UE %s` at `%s` |\n' "$UE5_VERSION" "$source_sha"
  printf '| Host / Xcode / iPhoneOS SDK | `%s` / `%s %s (%s)` / `%s` |\n' \
    "$host_arch" "$xcode_version" "$xcode_build" "$XCODE_APP" "$iphoneos_sdk"
  printf '| Source size checkout / post-setup / final | `%s MiB` / `%s MiB` / `%s MiB` |\n' \
    "$source_checkout_mib" "$source_after_setup_mib" "$source_final_mib"
  printf '| Setup / project generation | `%s s` / `%s s` |\n' "$setup_seconds" "$generate_seconds"
  printf '| Setup exclusions | `%s` |\n' "$SETUP_EXCLUDES"
  echo '| GitDependencies cache / threads | `disabled` / `3` |'
  printf '| Editor build / max parallel actions | `%s s` / `2` |\n' "$build_seconds"
  printf '| Compiler compatibility arguments | `%s` |\n' "$BUILD_COMPILER_ARGUMENTS"
  printf '| FBX red-black tree compatibility patch | `%s` |\n' "$fbx_redblacktree_patch"
  printf '| Editor / ShaderCompileWorker | `%s` / `%s`, `%s bytes` |\n' \
    "$editor_arch" "$shader_worker_arch" "$editor_binary_bytes"
  printf '| Emergency disk reserve | `%s GiB` |\n' "$DISK_RESERVE_GIB"
  printf '| Generated Xcode workspaces | `%s` |\n' "$workspace_count"
  printf '| Free disk before / after | `%s GiB` / `%s GiB` |\n' "$disk_before_gib" "$disk_after_gib"
  printf '| Tracked source changes after bootstrap | `%s` |\n' "$tracked_changes_after"
  echo '| Licensed source artifact upload | `disabled` |'
} >> "$GITHUB_STEP_SUMMARY"

printf 'UE %s hosted macOS source bootstrap completed at stage %s.\n' "$UE5_VERSION" "$BOOTSTRAP_STAGE"
