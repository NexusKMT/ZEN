#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${UE427_PROJECT_DIR:?UE427_PROJECT_DIR is required}"
: "${UE5_IMAGE:?UE5_IMAGE is required}"
: "${UE5_VERSION:?UE5_VERSION is required}"

cook_log="$RUNNER_TEMP/ue5-linux-cook.log"
cook_output_dir="$RUNNER_TEMP/ue5-linux-cook-output"
cook_manifest="$cook_output_dir/ue5-linux-cook-manifest.txt"
mkdir -p "$cook_output_dir"
chmod 0777 "$cook_output_dir"

set +e
timeout -k 60s 3600s docker run --rm \
  --mount "type=bind,src=${UE427_PROJECT_DIR},dst=/workspace/EpicZenGarden,readonly" \
  --mount "type=bind,src=${cook_output_dir},dst=/workspace/output" \
  --mount "type=bind,src=${GITHUB_WORKSPACE}/.github/scripts/ue5-linux-cook.sh,dst=/workspace/ue5-linux-cook.sh,readonly" \
  --env "UE5_VERSION=$UE5_VERSION" \
  "$UE5_IMAGE" \
  bash /workspace/ue5-linux-cook.sh > "$cook_log" 2>&1
cook_status="$?"
set -e

cat "$cook_log"
echo "UE ${UE5_VERSION} Linux cook process status: $cook_status"

if [[ "$cook_status" = 124 ]]; then
  echo "::error::The UE ${UE5_VERSION} Linux cook timed out."
  exit 1
fi
if [[ "$cook_status" != 0 ]]; then
  echo "::error::The UE ${UE5_VERSION} Linux cook failed."
  exit "$cook_status"
fi

test -s "$cook_manifest"
required_cook_lines=(
  "ZEN_UE5_COOK_BEGIN version=${UE5_VERSION} platform=Linux"
  'ZEN_UE5_COOK_COMMANDLET_SUCCESS'
  'ZEN_UE5_COOK_ASSET type=map file=Zen_Movie.umap'
  'ZEN_UE5_COOK_ASSET type=map file=Zen_P.umap'
  'ZEN_UE5_COOK_ASSET type=sequence file=MatineeActor_MovieLevelSequence.uasset'
  'ZEN_UE5_COOK_ASSET type=sequence file=MatineeActorLevelSequence.uasset'
  'ZEN_UE5_COOK_ASSET type=sequence file=MatineeActor3LevelSequence.uasset'
  'ZEN_UE5_COOK_SUCCESS files='
)
for required_line in "${required_cook_lines[@]}"; do
  if ! grep -Fq -- "$required_line" "$cook_log"; then
    echo "::error::The UE ${UE5_VERSION} cook log is missing required evidence: ${required_line}"
    exit 1
  fi
done

# The runner's three shader workers emit one fixed performance warning. Every
# other UE category diagnostic is a cook failure.
allowed_engine_warning='LogShaderCompilers: Warning: Only 3 SCWs will be spawned, which will result in longer shader compile times.'
unexpected_engine_diagnostics="$(grep -E \
  '(^|])([A-Za-z][A-Za-z0-9_]+): (Error|Warning):|LogInit: Display: ([A-Za-z][A-Za-z0-9_]+): (Error|Warning):' \
  "$cook_log" | grep -Fv -- "$allowed_engine_warning" || true)"
if [[ -n "$unexpected_engine_diagnostics" ]]; then
  echo "::error::The UE ${UE5_VERSION} cook emitted an unexpected engine error/warning."
  printf '%s\n' "$unexpected_engine_diagnostics"
  exit 1
fi

if grep -Eiq \
  '(^|])Log[A-Za-z0-9_]+: Error:|Exiting abnormally|Fatal error|Critical error|Assertion failed|Unhandled Exception|Segmentation fault|Cook failed|Unknown Cook Failure|LoadPackage: SkipPackage: /Game/Maps/MatineeActor(3|_Movie)?LevelSequence' \
  "$cook_log"
then
  echo "::error::The UE ${UE5_VERSION} cook log contains an engine error, missing sequence, abnormal-exit, or fatal marker."
  grep -Ei \
    '(^|])Log[A-Za-z0-9_]+: Error:|Exiting abnormally|Fatal error|Critical error|Assertion failed|Unhandled Exception|Segmentation fault|Cook failed|Unknown Cook Failure|LoadPackage: SkipPackage: /Game/Maps/MatineeActor(3|_Movie)?LevelSequence' \
    "$cook_log" || true
  exit 1
fi

cooked_file_count="$(wc -l < "$cook_manifest" | tr -d '[:space:]')"
echo "UE ${UE5_VERSION} cooked Zen_Movie, Zen_P, and all three generated Level Sequences for Linux across ${cooked_file_count} files."
{
  echo
  echo '## UE Linux cook'
  echo
  printf 'Cooked both converted maps and their transitive dependencies with `%s`.\n' "$UE5_IMAGE"
  echo
  echo '- Target platform: `Linux`'
  echo '- Maps: `/Game/Maps/Zen_Movie`, `/Game/Maps/Zen_P`'
  echo '- Generated Level Sequences present in cooked output: `3`'
  printf '%s\n' "- Cooked files: \`${cooked_file_count}\`"
  echo '- Cooked content remains runner-local; only the text audit is uploaded'
} >> "$GITHUB_STEP_SUMMARY"
