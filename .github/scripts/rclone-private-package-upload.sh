#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo 'Usage: rclone-private-package-upload.sh <local-dir> <stage> <transfer-key>' >&2
  exit 2
}

fail() {
  {
    echo 'RCLONE_PRIVATE_PACKAGE_UPLOAD_FAILED'
    printf 'stage=%s\n' "${stage:-unknown}"
    printf 'transfer_key=%s\n' "${transfer_key:-unknown}"
    printf 'error=%s\n' "$*"
  } > "$audit_file"
  echo "Private package upload error: $*" >&2
  exit 1
}

[[ "$#" == 3 ]] || usage
local_dir="$1"
stage="$2"
transfer_key="$3"

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${RCLONE_BIN:?RCLONE_BIN is required}"
: "${RCLONE_CONFIG_CONTENT:?RCLONE_CONFIG_CONTENT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

audit_file="$RUNNER_TEMP/ue5-ios-private-upload.txt"
[[ "$stage" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || fail 'The stage name is unsafe.'
[[ "$transfer_key" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || fail 'The transfer key is unsafe.'
test -d "$local_dir" || fail 'The local package directory does not exist.'
test ! -L "$local_dir" || fail 'The local package directory must not be a symlink.'
[[ "$local_dir" == "$RUNNER_TEMP/"* ]] || fail 'The local package directory must be under RUNNER_TEMP.'
test -x "$RCLONE_BIN" || fail 'RCLONE_BIN is not executable.'

entry_count="$(find "$local_dir" -mindepth 1 -maxdepth 1 -print | awk 'END { print NR + 0 }')"
test "$entry_count" = 1 || fail "The local package directory must contain exactly one entry; found ${entry_count}."
ipa_count="$(find "$local_dir" -mindepth 1 -maxdepth 1 -type f -name '*.ipa' -print | awk 'END { print NR + 0 }')"
test "$ipa_count" = 1 || fail "The local package directory must contain exactly one IPA; found ${ipa_count}."
ipa="$(find "$local_dir" -mindepth 1 -maxdepth 1 -type f -name '*.ipa' -print -quit)"
ipa_name="$(basename "$ipa")"
[[ "$ipa_name" =~ ^[A-Za-z0-9._-]+\.ipa$ ]] || fail 'The IPA file name is unsafe.'

config_dir="$(mktemp -d "$RUNNER_TEMP/rclone-package.XXXXXX")"
config_file="$config_dir/rclone.conf"
transfer_log="$config_dir/transfer.log"

cleanup() {
  if [[ -f "$config_file" ]]; then
    shred --remove "$config_file" 2>/dev/null || rm -f "$config_file"
  fi
  rm -f "$transfer_log"
  rmdir "$config_dir" 2>/dev/null || true
}
trap cleanup EXIT

umask 077
printf '%s' "$RCLONE_CONFIG_CONTENT" > "$config_file"
remote_count="$("$RCLONE_BIN" listremotes --config "$config_file" | awk 'NF { count++ } END { print count + 0 }')"
test "$remote_count" = 1 || fail "RCLONE_CONFIG must define exactly one remote; found ${remote_count}."
remote_name="$("$RCLONE_BIN" listremotes --config "$config_file" | awk 'NF { print; exit }')"
[[ "$remote_name" =~ ^[a-zA-Z0-9._-]+:$ ]] || fail 'The configured rclone remote name is invalid.'
remote_dir="${remote_name}ZEN/output/v1/${stage}/${transfer_key}"
rclone_args=(
  --config "$config_file"
  --retries 3
  --low-level-retries 10
  --transfers 2
  --checkers 2
  --stats 30s
  --log-file "$transfer_log"
  --log-level INFO
)

"$RCLONE_BIN" copy "$local_dir" "$remote_dir" "${rclone_args[@]}" --immutable ||
  fail 'The private package upload failed; the remote name is intentionally suppressed.'
"$RCLONE_BIN" check "$local_dir" "$remote_dir" "${rclone_args[@]}" --download ||
  fail 'The private package failed byte-for-byte download verification.'

ipa_bytes="$(stat -f '%z' "$ipa")"
ipa_sha256="$(shasum -a 256 "$ipa" | awk '{ print $1 }')"
[[ "$ipa_bytes" =~ ^[0-9]+$ ]] || fail 'Could not measure the IPA.'
[[ "$ipa_sha256" =~ ^[0-9a-f]{64}$ ]] || fail 'Could not hash the IPA.'
{
  echo 'RCLONE_PRIVATE_PACKAGE_UPLOAD_SUCCESS'
  printf 'stage=%s\n' "$stage"
  printf 'transfer_key=%s\n' "$transfer_key"
  printf 'ipa_name=%s\n' "$ipa_name"
  printf 'ipa_bytes=%s\n' "$ipa_bytes"
  printf 'ipa_sha256=%s\n' "$ipa_sha256"
  echo 'verification=byte-for-byte-download'
  echo 'public_binary_artifact=disabled'
} > "$audit_file"

printf 'IOS_PRIVATE_OUTPUT_STAGE=%s\n' "$stage" >> "$GITHUB_ENV"
printf 'IOS_PRIVATE_OUTPUT_KEY=%s\n' "$transfer_key" >> "$GITHUB_ENV"
{
  echo
  echo '## Private unsigned iOS package checkpoint'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  printf '| Stage / key | `%s` / `%s` |\n' "$stage" "$transfer_key"
  printf '| IPA | `%s`, `%s bytes`, SHA-256 `%s` |\n' "$ipa_name" "$ipa_bytes" "$ipa_sha256"
  echo '| Verification | `byte-for-byte rclone download check` |'
  echo '| Public binary artifact | `disabled` |'
} >> "$GITHUB_STEP_SUMMARY"

printf 'Private unsigned IPA upload completed for %s/%s.\n' "$stage" "$transfer_key"
