#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo 'Usage: rclone-project-transfer.sh <upload|download> <project-dir> <stage> <transfer-key>' >&2
  exit 2
}

fail() {
  echo "rclone project transfer error: $*" >&2
  exit 1
}

[[ "$#" == 4 ]] || usage
direction="$1"
project_dir="$2"
stage="$3"
transfer_key="$4"

[[ "$direction" == upload || "$direction" == download ]] || usage
[[ "$stage" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || fail 'The stage name is unsafe.'
[[ "$transfer_key" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || fail 'The transfer key is unsafe.'
: "${RCLONE_BIN:?RCLONE_BIN is required}"
: "${RCLONE_CONFIG_CONTENT:?RCLONE_CONFIG_CONTENT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
[[ -x "$RCLONE_BIN" ]] || fail 'RCLONE_BIN is not executable.'

config_dir="$(mktemp -d "$RUNNER_TEMP/rclone-project.XXXXXX")"
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
[[ "$remote_count" == 1 ]] || fail "RCLONE_CONFIG must define exactly one remote; found $remote_count."
remote_name="$("$RCLONE_BIN" listremotes --config "$config_file" | awk 'NF { print; exit }')"
[[ "$remote_name" =~ ^[a-zA-Z0-9._-]+:$ ]] || fail 'The configured rclone remote name is invalid.'

remote_dir="${remote_name}ZEN/intermediate/v1/${stage}/${transfer_key}/project"
rclone_args=(
  --config "$config_file"
  --retries 3
  --low-level-retries 10
  --stats 30s
  --log-file "$transfer_log"
  --log-level INFO
)
project_filters=(
  --include '/*.uproject'
  --include '/Config/**'
  --include '/Content/**'
  --include '/Build/**'
  --include '/Plugins/**'
  --include '/Source/**'
  --include '/Binaries/**'
  --include '/Saved/ZenMigration/**'
  --exclude '*'
)

if [[ "$direction" == upload ]]; then
  [[ -d "$project_dir" ]] || fail "Project directory does not exist: $project_dir"
  find "$project_dir" -maxdepth 1 -type f -name '*.uproject' -print -quit | grep -q . ||
    fail 'The upload directory does not contain a project descriptor.'
  [[ -d "$project_dir/Content" ]] || fail 'The upload directory does not contain Content.'

  "$RCLONE_BIN" copy "$project_dir" "$remote_dir" \
    "${rclone_args[@]}" "${project_filters[@]}" --immutable ||
    fail 'The private project upload failed; the remote name is intentionally suppressed.'
  "$RCLONE_BIN" check "$project_dir" "$remote_dir" \
    "${rclone_args[@]}" "${project_filters[@]}" ||
    fail 'The uploaded project failed rclone verification.'
else
  if [[ -e "$project_dir" && ! -d "$project_dir" ]]; then
    fail 'The download destination exists and is not a directory.'
  fi
  if [[ -d "$project_dir" && -n "$(find "$project_dir" -mindepth 1 -print -quit)" ]]; then
    fail 'The download destination must be empty.'
  fi
  mkdir -p "$project_dir"

  "$RCLONE_BIN" copy "$remote_dir" "$project_dir" "${rclone_args[@]}" --immutable ||
    fail 'The private project download failed; the remote name is intentionally suppressed.'
  "$RCLONE_BIN" check "$remote_dir" "$project_dir" "${rclone_args[@]}" ||
    fail 'The downloaded project failed rclone verification.'
  find "$project_dir" -maxdepth 1 -type f -name '*.uproject' -print -quit | grep -q . ||
    fail 'The downloaded directory does not contain a project descriptor.'
  [[ -d "$project_dir/Content" ]] || fail 'The downloaded directory does not contain Content.'
fi

file_count="$(find "$project_dir" -type f | awk 'END { print NR + 0 }')"
printf '%s completed for %s/%s with %s local project files.\n' \
  "$direction" "$stage" "$transfer_key" "$file_count"
