#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${UE427_PROJECT_DIR:?UE427_PROJECT_DIR is required}"

SOURCE_DIR="${SOURCE_DIR:-$GITHUB_WORKSPACE/ue5-source}"
project_file="$UE427_PROJECT_DIR/EpicZenGarden.uproject"
build_command="$SOURCE_DIR/Engine/Build/BatchFiles/Mac/Build.sh"
original_project="$RUNNER_TEMP/EpicZenGarden.original.uproject"
generic_actions="$RUNNER_TEMP/ue5-macos-generic-actions.json"
trimmed_actions="$RUNNER_TEMP/ue5-macos-trimmed-actions.json"
audit_file="$RUNNER_TEMP/ue5-macos-editor-action-plan.txt"

restore_project() {
  if test -f "$original_project"; then
    cp "$original_project" "$project_file"
  fi
}
trap restore_project EXIT

fail() {
  {
    echo 'UE5_MACOS_EDITOR_ACTION_PLAN_FAILED'
    printf 'error=%s\n' "$*"
  } > "$audit_file"
  echo "::error::$*"
  exit 1
}

run_action_plan() {
  local output_file="$1"

  (
    cd "$SOURCE_DIR"
    "$build_command" UnrealEditor Mac Development \
      "-Project=$project_file" \
      -buildscw \
      "-WriteOutdatedActions=$output_file" \
      -NoUBTMakefiles \
      -NoUBA \
      -NoUBALocal \
      -NoXGE \
      -NoFASTBuild \
      -NoSNDBS \
      -NoArtifactReads \
      -NoArtifactWrites
  ) || fail 'UnrealBuildTool could not export the action graph.'
  test -s "$output_file" || fail 'UnrealBuildTool did not write an action graph.'
  jq --exit-status '.Actions | type == "array" and length > 0' "$output_file" >/dev/null ||
    fail 'The exported action graph has no Actions array.'
}

test "$(uname -s)" = Darwin || fail 'This action plan must run on macOS.'
command -v jq >/dev/null || fail 'jq is unavailable.'
test -x "$build_command" || fail 'The UE Mac Build.sh is unavailable.'
test -f "$project_file" || fail 'The EpicZenGarden project descriptor is unavailable.'
jq --exit-status 'type == "object"' "$project_file" >/dev/null || fail 'The project descriptor is not JSON.'

cp "$project_file" "$original_project"
original_disable_default="$(jq -r '(.DisableEnginePluginsByDefault // false) | tostring' "$project_file")"
project_plugin_references="$(jq -r '(.Plugins // []) | length' "$project_file")"
[[ "$project_plugin_references" =~ ^[0-9]+$ ]] || fail 'Could not count project plugin references.'

run_action_plan "$generic_actions"
generic_action_count="$(jq -r '.Actions | length' "$generic_actions")"

trimmed_descriptor="$RUNNER_TEMP/EpicZenGarden.trimmed.uproject"
jq '.DisableEnginePluginsByDefault = true' "$project_file" > "$trimmed_descriptor"
mv "$trimmed_descriptor" "$project_file"
jq --exit-status '.DisableEnginePluginsByDefault == true' "$project_file" >/dev/null ||
  fail 'Could not enable project-scoped engine plugins.'

run_action_plan "$trimmed_actions"
trimmed_action_count="$(jq -r '.Actions | length' "$trimmed_actions")"
[[ "$generic_action_count" =~ ^[0-9]+$ ]] || fail 'The generic action count is invalid.'
[[ "$trimmed_action_count" =~ ^[0-9]+$ ]] || fail 'The trimmed action count is invalid.'
(( trimmed_action_count < generic_action_count )) ||
  fail "Project-scoped plugins did not reduce the action graph (${generic_action_count} versus ${trimmed_action_count})."

reduced_actions="$((generic_action_count - trimmed_action_count))"
reduction_percent="$(awk -v reduced="$reduced_actions" -v total="$generic_action_count" 'BEGIN { printf "%.1f", (reduced * 100) / total }')"
{
  echo 'UE5_MACOS_EDITOR_ACTION_PLAN_SUCCESS'
  printf 'original_disable_engine_plugins_by_default=%s\n' "$original_disable_default"
  printf 'project_plugin_reference_count=%s\n' "$project_plugin_references"
  printf 'generic_action_count=%s\n' "$generic_action_count"
  printf 'project_scoped_action_count=%s\n' "$trimmed_action_count"
  printf 'reduced_actions=%s\n' "$reduced_actions"
  printf 'reduction_percent=%s\n' "$reduction_percent"
  echo 'action_graph_upload=disabled'
  echo 'project_descriptor_upload=disabled'
} > "$audit_file"

{
  echo
  echo '## UE 5.5.4 project-scoped editor action plan'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  printf '| Original DisableEnginePluginsByDefault | `%s` |\n' "$original_disable_default"
  printf '| Explicit project plugin references | `%s` |\n' "$project_plugin_references"
  printf '| Generic / project-scoped actions | `%s` / `%s` |\n' "$generic_action_count" "$trimmed_action_count"
  printf '| Reduction | `%s actions` (`%s%%`) |\n' "$reduced_actions" "$reduction_percent"
  echo '| Build execution | `disabled; action graph export only` |'
  echo '| Licensed graph/project upload | `disabled` |'
} >> "$GITHUB_STEP_SUMMARY"

printf 'Project-scoped editor action graph reduced from %s to %s actions.\n' \
  "$generic_action_count" "$trimmed_action_count"
