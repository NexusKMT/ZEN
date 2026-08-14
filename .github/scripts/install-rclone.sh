#!/usr/bin/env bash

set -euo pipefail

: "${RCLONE_RELEASE_INPUT:?RCLONE_RELEASE_INPUT is required}"
: "${RCLONE_BUNDLE_SHA256_INPUT:?RCLONE_BUNDLE_SHA256_INPUT is required}"
: "${RCLONE_OSX_AMD64_BUNDLE_SHA256_INPUT:=}"
: "${RCLONE_OSX_ARM64_BUNDLE_SHA256_INPUT:=}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

if [[ ! "$RCLONE_RELEASE_INPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'The pinned rclone release must be a numeric semantic version.' >&2
  exit 1
fi
case "$(uname -s):$(uname -m)" in
  Linux:x86_64)
    archive_platform=linux-amd64
    bundle_sha256="$RCLONE_BUNDLE_SHA256_INPUT"
    ;;
  Darwin:x86_64)
    archive_platform=osx-amd64
    bundle_sha256="$RCLONE_OSX_AMD64_BUNDLE_SHA256_INPUT"
    ;;
  Darwin:arm64)
    archive_platform=osx-arm64
    bundle_sha256="$RCLONE_OSX_ARM64_BUNDLE_SHA256_INPUT"
    ;;
  *)
    echo "Unsupported rclone runner platform: $(uname -s) $(uname -m)" >&2
    exit 1
    ;;
esac
if [[ ! "$bundle_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "The pinned rclone bundle SHA-256 is missing or invalid for ${archive_platform}." >&2
  exit 1
fi

tool_dir="$RUNNER_TEMP/rclone-tool-${RCLONE_RELEASE_INPUT}-${archive_platform}"
bundle="$tool_dir/rclone.zip"
bin_dir="$tool_dir/bin"
mkdir -p "$tool_dir" "$bin_dir"

curl --fail --location --silent --show-error --retry 5 \
  --output "$bundle" \
  "https://downloads.rclone.org/v${RCLONE_RELEASE_INPUT}/rclone-v${RCLONE_RELEASE_INPUT}-${archive_platform}.zip"
if command -v sha256sum >/dev/null; then
  actual_sha256="$(sha256sum "$bundle" | awk '{ print $1 }')"
elif command -v shasum >/dev/null; then
  actual_sha256="$(shasum -a 256 "$bundle" | awk '{ print $1 }')"
else
  echo 'No SHA-256 verification utility is available.' >&2
  exit 1
fi
if [[ "$actual_sha256" != "$bundle_sha256" ]]; then
  echo "The downloaded ${archive_platform} rclone bundle failed SHA-256 verification." >&2
  exit 1
fi
unzip -qo "$bundle" -d "$tool_dir/unpacked"

rclone_candidate_count="$(find "$tool_dir/unpacked" -type f -name rclone | awk 'END { print NR + 0 }')"
if [[ "$rclone_candidate_count" != 1 ]]; then
  echo "Expected one rclone binary in the verified bundle; found ${rclone_candidate_count}." >&2
  exit 1
fi
rclone_candidate="$(find "$tool_dir/unpacked" -type f -name rclone -print -quit)"

install -m 0755 "$rclone_candidate" "$bin_dir/rclone"
version_line="$("$bin_dir/rclone" version | sed -n '1p')"
if [[ "$version_line" != "rclone v${RCLONE_RELEASE_INPUT}" ]]; then
  echo "The installed rclone version is unexpected: ${version_line}" >&2
  exit 1
fi

printf '%s\n' "$bin_dir" >> "$GITHUB_PATH"
printf 'RCLONE_BIN=%s\n' "$bin_dir/rclone" >> "$GITHUB_ENV"
printf 'rclone-bin=%s\n' "$bin_dir/rclone" >> "$GITHUB_OUTPUT"
printf 'Installed and verified %s for %s.\n' "$version_line" "$archive_platform"
