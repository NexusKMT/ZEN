#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${UE5_VERSION:?UE5_VERSION is required}"
: "${UE5_SOURCE_SHA:?UE5_SOURCE_SHA is required}"
: "${EXPECTED_HOST_ARCH:?EXPECTED_HOST_ARCH is required}"
: "${EXPECTED_RUNNER_ARCH:?EXPECTED_RUNNER_ARCH is required}"
: "${EXPECTED_MACOS_MAJOR:?EXPECTED_MACOS_MAJOR is required}"
: "${EXPECTED_XCODE_VERSION:?EXPECTED_XCODE_VERSION is required}"
: "${EXPECTED_XCODE_BUILD:?EXPECTED_XCODE_BUILD is required}"
: "${EXPECTED_IPHONEOS_SDK:?EXPECTED_IPHONEOS_SDK is required}"

SETUP_EXCLUDES="${SETUP_EXCLUDES:-Android,Linux,LinuxArm64,Win32,Win64,HoloLens,TVOS}"
bootstrap_script="$GITHUB_WORKSPACE/.github/scripts/ue5-macos-source-bootstrap.sh"
test -f "$bootstrap_script" || {
  echo 'The UE source bootstrap script is missing.' >&2
  exit 1
}
[[ "$UE5_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'UE5_SOURCE_SHA must be a full lowercase Git SHA.' >&2
  exit 1
}

bootstrap_script_sha256="$(shasum -a 256 "$bootstrap_script" | awk '{ print $1 }')"
recipe_sha256="$({
  printf 'checkpoint_schema=zen-ue5-macos-engine-v1\n'
  printf 'checkpoint_format=tar+gzip-v1\n'
  printf 'ue5_version=%s\n' "$UE5_VERSION"
  printf 'source_sha=%s\n' "$UE5_SOURCE_SHA"
  printf 'macos_major=%s\n' "$EXPECTED_MACOS_MAJOR"
  printf 'host_arch=%s\n' "$EXPECTED_HOST_ARCH"
  printf 'runner_arch=%s\n' "$EXPECTED_RUNNER_ARCH"
  printf 'xcode_version=%s\n' "$EXPECTED_XCODE_VERSION"
  printf 'xcode_build=%s\n' "$EXPECTED_XCODE_BUILD"
  printf 'iphoneos_sdk=%s\n' "$EXPECTED_IPHONEOS_SDK"
  printf 'setup_excludes=%s\n' "$SETUP_EXCLUDES"
  printf 'bootstrap_script_sha256=%s\n' "$bootstrap_script_sha256"
  printf 'build_target=UnrealEditor Mac Development\n'
  printf 'build_flags=-buildscw -MaxParallelActions=2 -CompilerArguments=-Wno-shorten-64-to-32 -NoUBA -NoUBALocal -NoXGE -NoFASTBuild -NoSNDBS -NoArtifactReads -NoArtifactWrites\n'
} | shasum -a 256 | awk '{ print $1 }')"

xcode_build_lc="$(printf '%s' "$EXPECTED_XCODE_BUILD" | tr '[:upper:]' '[:lower:]')"
checkpoint_key="ue5-${UE5_VERSION}-${UE5_SOURCE_SHA:0:12}-macos${EXPECTED_MACOS_MAJOR}-${EXPECTED_HOST_ARCH}-xcode${EXPECTED_XCODE_VERSION}-${xcode_build_lc}-ios${EXPECTED_IPHONEOS_SDK}-${recipe_sha256:0:16}"
[[ "$checkpoint_key" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || {
  echo 'The generated Engine checkpoint key is unsafe.' >&2
  exit 1
}

printf 'ENGINE_BOOTSTRAP_RECIPE_SHA256=%s\n' "$recipe_sha256" >> "$GITHUB_ENV"
printf 'ENGINE_CHECKPOINT_KEY=%s\n' "$checkpoint_key" >> "$GITHUB_ENV"
printf 'engine-bootstrap-recipe-sha256=%s\n' "$recipe_sha256" >> "$GITHUB_OUTPUT"
printf 'engine-checkpoint-key=%s\n' "$checkpoint_key" >> "$GITHUB_OUTPUT"
printf 'Prepared immutable UE Engine checkpoint key %s.\n' "$checkpoint_key"
