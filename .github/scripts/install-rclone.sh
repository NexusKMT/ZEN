#!/usr/bin/env bash

set -euo pipefail

: "${RCLONE_RELEASE_INPUT:?RCLONE_RELEASE_INPUT is required}"
: "${RCLONE_BUNDLE_SHA256_INPUT:?RCLONE_BUNDLE_SHA256_INPUT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

if [[ ! "$RCLONE_RELEASE_INPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'The pinned rclone release must be a numeric semantic version.' >&2
  exit 1
fi
if [[ ! "$RCLONE_BUNDLE_SHA256_INPUT" =~ ^[0-9a-f]{64}$ ]]; then
  echo 'The pinned rclone bundle SHA-256 is invalid.' >&2
  exit 1
fi

tool_dir="$RUNNER_TEMP/rclone-tool-${RCLONE_RELEASE_INPUT}"
bundle="$tool_dir/rclone.zip"
bin_dir="$tool_dir/bin"
mkdir -p "$tool_dir" "$bin_dir"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'This pinned installer currently supports Linux AMD64 runners only.' >&2
  exit 1
fi

curl --fail --location --silent --show-error --retry 5 \
  --output "$bundle" \
  "https://downloads.rclone.org/v${RCLONE_RELEASE_INPUT}/rclone-v${RCLONE_RELEASE_INPUT}-linux-amd64.zip"
printf '%s  %s\n' "$RCLONE_BUNDLE_SHA256_INPUT" "$bundle" |
  sha256sum --check --status
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
printf 'Installed and verified %s.\n' "$version_line"
