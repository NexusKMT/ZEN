#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${UE427_PROJECT_DIR:?UE427_PROJECT_DIR is required}"
: "${UE5_IMAGE:?UE5_IMAGE is required}"
: "${UE5_VERSION:?UE5_VERSION is required}"

stage_log="$RUNNER_TEMP/ue5-linux-stage-runtime.log"
stage_output_dir="$RUNNER_TEMP/ue5-linux-stage-output"
stage_manifest="$stage_output_dir/ue5-linux-stage-manifest.txt"
mkdir -p "$stage_output_dir"
chmod 0777 "$stage_output_dir"

set +e
timeout -k 60s 5400s docker run --rm \
  --mount "type=bind,src=${UE427_PROJECT_DIR},dst=/workspace/EpicZenGarden,readonly" \
  --mount "type=bind,src=${stage_output_dir},dst=/workspace/output" \
  --mount "type=bind,src=${GITHUB_WORKSPACE}/.github/scripts/ue5-linux-stage-runtime.sh,dst=/workspace/ue5-linux-stage-runtime.sh,readonly" \
  --env "UE5_VERSION=$UE5_VERSION" \
  "$UE5_IMAGE" \
  bash /workspace/ue5-linux-stage-runtime.sh > "$stage_log" 2>&1
stage_status="$?"
set -e

cat "$stage_log"
echo "UE ${UE5_VERSION} Linux stage/runtime process status: $stage_status"

if [[ "$stage_status" = 124 ]]; then
  echo "::error::The UE ${UE5_VERSION} Linux stage/runtime validation timed out."
  exit 1
fi
if [[ "$stage_status" != 0 ]]; then
  echo "::error::The UE ${UE5_VERSION} Linux stage/runtime validation failed."
  exit "$stage_status"
fi

test -s "$stage_manifest"
required_stage_lines=(
  "ZEN_UE5_STAGE_BEGIN version=${UE5_VERSION} platform=Linux"
  'ZEN_UE5_STAGE_UAT_SUCCESS'
  'ZEN_UE5_STAGE_PACKAGE_SUCCESS files='
  'ZEN_UE5_STAGE_LAUNCHER path='
  'ZEN_UE5_RUNTIME_MAP_SUCCESS map=Zen_Movie'
  'ZEN_UE5_RUNTIME_MAP_SUCCESS map=Zen_P'
  'ZEN_UE5_RUNTIME_SEQUENCE_LOADED asset=MatineeActor_MovieLevelSequence'
  'ZEN_UE5_RUNTIME_SEQUENCE_LOADED asset=MatineeActorLevelSequence'
  'ZEN_UE5_RUNTIME_SEQUENCE_LOADED asset=MatineeActor3LevelSequence'
  'ZEN_UE5_STAGE_RUNTIME_SUCCESS'
)
for required_line in "${required_stage_lines[@]}"; do
  if ! grep -Fq -- "$required_line" "$stage_log"; then
    echo "::error::The UE ${UE5_VERSION} stage/runtime log is missing required evidence: ${required_line}"
    exit 1
  fi
done

staged_file_count="$(wc -l < "$stage_manifest" | tr -d '[:space:]')"
if [[ "$staged_file_count" -lt 5 ]]; then
  echo "::error::The UE ${UE5_VERSION} staged manifest is unexpectedly small: ${staged_file_count} files."
  exit 1
fi

echo "UE ${UE5_VERSION} staged and headlessly ran Zen_Movie and Zen_P from a Linux package across ${staged_file_count} files."
{
  echo
  echo '## UE Linux stage and runtime'
  echo
  printf 'Built, cooked, staged, packaged, archived, and headlessly launched `%s`.\n' "$UE5_IMAGE"
  echo
  echo '- Target platform: `Linux`'
  echo '- Build configuration: `Development`'
  echo '- Staged maps launched: `/Game/Maps/Zen_Movie`, `/Game/Maps/Zen_P`'
  echo '- Generated Level Sequences enumerated by the staged runtime: `3`'
  printf '%s\n' "- Staged files: \`${staged_file_count}\`"
  echo '- Staged licensed content remains runner-local; only text audits are uploaded'
} >> "$GITHUB_STEP_SUMMARY"
