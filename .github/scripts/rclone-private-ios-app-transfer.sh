#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo 'Usage: rclone-private-ios-app-transfer.sh <upload|download> <local-dir> <stage> <transfer-key>' >&2
  exit 2
}

fail() {
  {
    echo 'RCLONE_PRIVATE_IOS_APP_TRANSFER_FAILED'
    printf 'direction=%s\n' "${direction:-unknown}"
    printf 'stage=%s\n' "${stage:-unknown}"
    printf 'transfer_key=%s\n' "${transfer_key:-unknown}"
    printf 'error=%s\n' "$*"
  } > "$audit_file"
  echo "Private iOS app transfer error: $*" >&2
  exit 1
}

[[ "$#" == 4 ]] || usage
direction="$1"
local_dir="$2"
stage="$3"
transfer_key="$4"

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${RCLONE_BIN:?RCLONE_BIN is required}"
: "${RCLONE_CONFIG_CONTENT:?RCLONE_CONFIG_CONTENT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

[[ "$direction" == upload || "$direction" == download ]] || usage
audit_file="$RUNNER_TEMP/ue5-ios-app-private-transfer.txt"
[[ "$stage" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || fail 'The stage name is unsafe.'
[[ "$transfer_key" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || fail 'The transfer key is unsafe.'
test -x "$RCLONE_BIN" || fail 'RCLONE_BIN is not executable.'

config_dir="$(mktemp -d "$RUNNER_TEMP/rclone-ios-app.XXXXXX")"
config_file="$config_dir/rclone.conf"
transfer_log="$config_dir/transfer.log"
archive="$config_dir/ios-app.tar"
download_archive="$config_dir/ios-app.download.tar"
verify_archive="$config_dir/ios-app.verify.tar"
verify_manifest="$config_dir/checkpoint.manifest.verify.txt"
cleanup() {
  if [[ -f "$config_file" ]]; then
    shred --remove "$config_file" 2>/dev/null || rm -f "$config_file"
  fi
  rm -f "$transfer_log" "$archive" "$download_archive" "$verify_archive" "$verify_manifest" \
    "$config_dir/checkpoint.manifest.txt" "$config_dir/archive-listing.txt"
  rmdir "$config_dir" 2>/dev/null || true
}
trap cleanup EXIT

umask 077
printf '%s' "$RCLONE_CONFIG_CONTENT" > "$config_file"
remote_count="$("$RCLONE_BIN" listremotes --config "$config_file" | awk 'NF { count++ } END { print count + 0 }')"
test "$remote_count" = 1 || fail "RCLONE_CONFIG must define exactly one remote; found ${remote_count}."
remote_name="$("$RCLONE_BIN" listremotes --config "$config_file" | awk 'NF { print; exit }')"
[[ "$remote_name" =~ ^[a-zA-Z0-9._-]+:$ ]] || fail 'The configured rclone remote name is invalid.'
remote_dir="${remote_name}ZEN/intermediate/v1/${stage}/${transfer_key}"
archive_remote="$remote_dir/ios-app.tar"
manifest_remote="$remote_dir/checkpoint.manifest.txt"
rclone_args=(
  --config "$config_file"
  --retries 3
  --low-level-retries 10
  --stats 30s
  --log-file "$transfer_log"
  --log-level INFO
)

app_name=''
app_bytes=''
app_sha256=''
manifest_target="$RUNNER_TEMP/ue5-ios-app-checkpoint.manifest.txt"
if [[ "$direction" == upload ]]; then
  test -d "$local_dir" || fail 'The local app directory does not exist.'
  test ! -L "$local_dir" || fail 'The local app directory must not be a symlink.'
  [[ "$local_dir" == "$RUNNER_TEMP/"* ]] || fail 'The local app directory must be under RUNNER_TEMP.'
  app_count="$(find "$local_dir" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print | awk 'END { print NR + 0 }')"
  test "$app_count" = 1 || fail "The local app directory must contain exactly one .app; found ${app_count}."
  app="$(find "$local_dir" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
  test -z "$(find "$app" -type l -print -quit)" || fail 'The app bundle must not contain symbolic links.'
  app_name="$(basename "$app")"
  [[ "$app_name" =~ ^[A-Za-z0-9._-]+\.app$ ]] || fail 'The app bundle name is unsafe.'
  find "$app" -type f -print -quit | grep -q . || fail 'The app bundle is empty.'
  app_bytes="$(cd "$app" && find . -type f -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }')"
  app_sha256="$(cd "$app" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{ print $1 }')"
  manifest_source="${IOS_APP_MANIFEST:-$RUNNER_TEMP/ue5-ios-a8a9-app-manifest.txt}"
  test -f "$manifest_source" || fail 'The producer app manifest is missing.'
  grep -Fqx 'UE5_IOS_UNSIGNED_APP_SUCCESS' "$manifest_source" ||
    fail 'The producer app manifest does not contain the unsigned app success marker.'
  grep -Fqx 'checkpoint_schema=zen-ios-app-v2' "$manifest_source" ||
    fail 'The producer app manifest does not use the Intel checkpoint schema.'
  grep -Fqx 'code_signing=disabled' "$manifest_source" ||
    fail 'The producer app manifest does not confirm signing is disabled.'
  grep -Fqx 'embedded_mobileprovision=absent' "$manifest_source" ||
    fail 'The producer app manifest does not confirm provisioning is absent.'
  grep -Fqx 'ipa_merge=deferred' "$manifest_source" ||
    fail 'The producer app manifest does not confirm IPA merge is deferred.'
  expected_version="${EXPECTED_UE5_VERSION:-${UE5_VERSION:-}}"
  if [[ -n "$expected_version" ]]; then
    grep -Fqx "ue5_version=$expected_version" "$manifest_source" ||
      fail 'The producer app manifest UE version does not match the producer expectation.'
  fi
  for manifest_key in checkpoint_schema ue5_version host_arch xcode_version xcode_build iphoneos_sdk app_platform app_sdk_name app_name app_executable app_architectures app_bytes app_sha256; do
    manifest_key_count="$(awk -F= -v key="$manifest_key" '$1 == key { count++ } END { print count + 0 }' "$manifest_source")"
    test "$manifest_key_count" = 1 ||
      fail "The producer app manifest must contain exactly one ${manifest_key} field."
  done
  grep -Fqx "app_name=$app_name" "$manifest_source" ||
    fail 'The producer app manifest name does not match the app bundle.'
  grep -Fqx "app_bytes=$app_bytes" "$manifest_source" ||
    fail 'The producer app manifest byte count does not match the app bundle.'
  grep -Fqx "app_sha256=$app_sha256" "$manifest_source" ||
    fail 'The producer app manifest hash does not match the app bundle.'
  expected_host_arch="${EXPECTED_PRODUCER_HOST_ARCH:-x86_64}"
  expected_xcode_version="${EXPECTED_PRODUCER_XCODE_VERSION:-16.4}"
  expected_xcode_build="${EXPECTED_PRODUCER_XCODE_BUILD:-16F6}"
  expected_iphoneos_sdk="${EXPECTED_PRODUCER_IPHONEOS_SDK:-18.5}"
  test "$(uname -m)" = "$expected_host_arch" || fail 'The producer runner architecture is unexpected.'
  grep -Fqx "host_arch=$expected_host_arch" "$manifest_source" ||
    fail 'The producer app manifest host architecture is unexpected.'
  grep -Fqx "xcode_version=$expected_xcode_version" "$manifest_source" ||
    fail 'The producer app manifest Xcode version is unexpected.'
  grep -Fqx "xcode_build=$expected_xcode_build" "$manifest_source" ||
    fail 'The producer app manifest Xcode build is unexpected.'
  grep -Fqx "iphoneos_sdk=$expected_iphoneos_sdk" "$manifest_source" ||
    fail 'The producer app manifest iPhoneOS SDK is unexpected.'
  grep -Fqx 'app_platform=iphoneos' "$manifest_source" ||
    fail 'The producer app manifest does not identify an iPhoneOS app.'
  grep -Fqx 'app_architectures=arm64' "$manifest_source" ||
    fail 'The producer app manifest does not identify a thin arm64 app.'
  if grep -Eq '^(producer_commit|producer_host_arch|archive_sha256)=' "$manifest_source"; then
    fail 'The producer app manifest already contains checkpoint transport fields.'
  fi
  checkpoint_manifest="$config_dir/checkpoint.manifest.txt"
  cp "$manifest_source" "$checkpoint_manifest"
  printf 'producer_commit=%s\n' "${GITHUB_SHA:-unknown}" >> "$checkpoint_manifest"
  printf 'producer_host_arch=%s\n' "$(uname -m)" >> "$checkpoint_manifest"
  tar -C "$local_dir" -cf "$archive" "$app_name"
  archive_sha256="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
  printf 'archive_sha256=%s\n' "$archive_sha256" >> "$checkpoint_manifest"
  "$RCLONE_BIN" copyto "$archive" "$archive_remote" "${rclone_args[@]}" --immutable ||
    fail 'The private iOS app archive upload failed; the remote name is intentionally suppressed.'
  "$RCLONE_BIN" copyto "$archive_remote" "$verify_archive" "${rclone_args[@]}" ||
    fail 'The uploaded iOS app archive could not be read back for verification.'
  test "$archive_sha256" = "$(shasum -a 256 "$verify_archive" | awk '{ print $1 }')" ||
    fail 'The uploaded iOS app archive failed byte-for-byte verification.'
  "$RCLONE_BIN" copyto "$checkpoint_manifest" "$manifest_remote" "${rclone_args[@]}" --immutable ||
    fail 'The iOS app checkpoint manifest upload failed.'
  "$RCLONE_BIN" copyto "$manifest_remote" "$verify_manifest" "${rclone_args[@]}" ||
    fail 'The uploaded iOS app checkpoint manifest could not be read back for verification.'
  cmp -s "$checkpoint_manifest" "$verify_manifest" ||
    fail 'The uploaded iOS app checkpoint manifest failed byte-for-byte verification.'
else
  if [[ -e "$local_dir" && ! -d "$local_dir" ]]; then
    fail 'The download destination exists and is not a directory.'
  fi
  if [[ -d "$local_dir" && -n "$(find "$local_dir" -mindepth 1 -print -quit)" ]]; then
    fail 'The download destination must be empty.'
  fi
  mkdir -p "$local_dir"
  "$RCLONE_BIN" copyto "$manifest_remote" "$manifest_target" "${rclone_args[@]}" ||
    fail 'The iOS app checkpoint manifest download failed.'
  test -s "$manifest_target" || fail 'The downloaded iOS app checkpoint manifest is empty.'
  for manifest_key in checkpoint_schema ue5_version host_arch xcode_version xcode_build iphoneos_sdk app_platform app_sdk_name app_name app_executable app_architectures app_bytes app_sha256 producer_commit producer_host_arch archive_sha256; do
    manifest_key_count="$(awk -F= -v key="$manifest_key" '$1 == key { count++ } END { print count + 0 }' "$manifest_target")"
    test "$manifest_key_count" = 1 ||
      fail "The checkpoint manifest must contain exactly one ${manifest_key} field."
  done
  expected_version="${EXPECTED_UE5_VERSION:-}"
  expected_commit="${EXPECTED_PRODUCER_COMMIT:-}"
  grep -Fqx 'checkpoint_schema=zen-ios-app-v2' "$manifest_target" ||
    fail 'The iOS app checkpoint does not use the Intel checkpoint schema.'
  if [[ -n "$expected_version" ]]; then
    grep -Fqx "ue5_version=$expected_version" "$manifest_target" ||
      fail 'The iOS app checkpoint UE version does not match the consumer expectation.'
  fi
  if [[ -n "$expected_commit" ]]; then
    grep -Fqx "producer_commit=$expected_commit" "$manifest_target" ||
      fail 'The iOS app checkpoint producer commit does not match the consumer expectation.'
  fi
  expected_producer_host_arch="${EXPECTED_PRODUCER_HOST_ARCH:-x86_64}"
  expected_consumer_host_arch="${EXPECTED_CONSUMER_HOST_ARCH:-x86_64}"
  expected_xcode_version="${EXPECTED_PRODUCER_XCODE_VERSION:-16.4}"
  expected_xcode_build="${EXPECTED_PRODUCER_XCODE_BUILD:-16F6}"
  expected_iphoneos_sdk="${EXPECTED_PRODUCER_IPHONEOS_SDK:-18.5}"
  grep -Fqx "host_arch=$expected_producer_host_arch" "$manifest_target" ||
    fail 'The iOS app checkpoint was not produced on the required Intel host.'
  producer_host_arch="$(awk -F= '$1 == "producer_host_arch" { print $2; exit }' "$manifest_target")"
  test "$producer_host_arch" = "$expected_producer_host_arch" ||
    fail 'The checkpoint producer host architecture does not match its app manifest.'
  grep -Fqx "xcode_version=$expected_xcode_version" "$manifest_target" ||
    fail 'The iOS app checkpoint Xcode version is unexpected.'
  grep -Fqx "xcode_build=$expected_xcode_build" "$manifest_target" ||
    fail 'The iOS app checkpoint Xcode build is unexpected.'
  grep -Fqx "iphoneos_sdk=$expected_iphoneos_sdk" "$manifest_target" ||
    fail 'The iOS app checkpoint iPhoneOS SDK is unexpected.'
  grep -Fqx 'app_platform=iphoneos' "$manifest_target" ||
    fail 'The iOS app checkpoint is not an iPhoneOS app.'
  grep -Fqx 'app_architectures=arm64' "$manifest_target" ||
    fail 'The iOS app checkpoint is not a thin arm64 app.'
  consumer_host_arch="$(uname -m)"
  test "$consumer_host_arch" = "$expected_consumer_host_arch" ||
    fail 'The consumer host architecture is unexpected.'
  "$RCLONE_BIN" copyto "$archive_remote" "$download_archive" "${rclone_args[@]}" ||
    fail 'The private iOS app archive download failed; the remote name is intentionally suppressed.'
  archive_listing="$config_dir/archive-listing.txt"
  tar -tf "$download_archive" > "$archive_listing"
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "$archive_listing"; then
    fail 'The downloaded archive contains an unsafe path.'
  fi
  archive_root_count="$(awk -F/ 'NF { print $1 }' "$archive_listing" | sort -u | awk 'END { print NR + 0 }')"
  test "$archive_root_count" = 1 || fail 'The downloaded archive must contain exactly one root.'
  archive_name="$(awk -F/ 'NF { print $1; exit }' "$archive_listing")"
  [[ "$archive_name" =~ ^[A-Za-z0-9._-]+\.app$ ]] || fail 'The downloaded archive has an unsafe app root.'
  archive_sha256="$(shasum -a 256 "$download_archive" | awk '{ print $1 }')"
  manifest_archive_sha256="$(awk -F= '$1 == "archive_sha256" { print $2; exit }' "$manifest_target")"
  test "$archive_sha256" = "$manifest_archive_sha256" || fail 'The downloaded archive differs from its checkpoint manifest.'
  tar -C "$local_dir" -xf "$download_archive"
  app="$local_dir/$archive_name"
  test -d "$app" || fail 'The downloaded archive did not produce an app bundle.'
  test -z "$(find "$local_dir" -type l -print -quit)" ||
    fail 'The downloaded app checkpoint contains symbolic links.'
  app_name="$archive_name"
  app_bytes="$(cd "$app" && find . -type f -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }')"
  app_sha256="$(cd "$app" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{ print $1 }')"
  manifest_app_name="$(awk -F= '$1 == "app_name" { print $2; exit }' "$manifest_target")"
  manifest_app_bytes="$(awk -F= '$1 == "app_bytes" { print $2; exit }' "$manifest_target")"
  manifest_app_sha256="$(awk -F= '$1 == "app_sha256" { print $2; exit }' "$manifest_target")"
  test "$app_name" = "$manifest_app_name" || fail 'The downloaded app name differs from its checkpoint manifest.'
  test "$app_bytes" = "$manifest_app_bytes" || fail 'The downloaded app byte count differs from its checkpoint manifest.'
  test "$app_sha256" = "$manifest_app_sha256" || fail 'The downloaded app hash differs from its checkpoint manifest.'
fi

{
  echo 'RCLONE_PRIVATE_IOS_APP_TRANSFER_SUCCESS'
  printf 'direction=%s\n' "$direction"
  printf 'stage=%s\n' "$stage"
  printf 'transfer_key=%s\n' "$transfer_key"
  printf 'app_name=%s\n' "$app_name"
  printf 'app_bytes=%s\n' "$app_bytes"
  printf 'app_sha256=%s\n' "$app_sha256"
  printf 'host_arch=%s\n' "$(uname -m)"
  echo 'app_platform=iphoneos'
  echo 'app_architectures=arm64'
  echo 'verification=byte-for-byte-download'
  echo 'public_binary_artifact=disabled'
} > "$audit_file"

printf 'IOS_APP_TRANSFER_STAGE=%s\n' "$stage" >> "$GITHUB_ENV"
printf 'IOS_APP_TRANSFER_KEY=%s\n' "$transfer_key" >> "$GITHUB_ENV"
printf 'IOS_APP_TRANSFER_DIR=%s\n' "$local_dir" >> "$GITHUB_ENV"
{
  echo
  echo '## Private unsigned iOS app checkpoint'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  printf '| Direction / key | `%s` / `%s` |\n' "$direction" "$transfer_key"
  printf '| App | `%s`, `%s bytes`, manifest SHA-256 `%s` |\n' "$app_name" "$app_bytes" "$app_sha256"
  printf '| Host / payload architecture | `%s` / `iphoneos arm64` |\n' "$(uname -m)"
  echo '| Verification | `byte-for-byte rclone download check` |'
  echo '| IPA merge | `deferred to consumer workflow` |'
} >> "$GITHUB_STEP_SUMMARY"
