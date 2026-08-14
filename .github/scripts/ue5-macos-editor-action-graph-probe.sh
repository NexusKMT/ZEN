#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${UE427_PROJECT_DIR:?UE427_PROJECT_DIR is required}"

SOURCE_DIR="${SOURCE_DIR:-$GITHUB_WORKSPACE/ue5-source}"
project_file="$UE427_PROJECT_DIR/EpicZenGarden.uproject"
build_command="$SOURCE_DIR/Engine/Build/BatchFiles/Mac/Build.sh"
output_file="$RUNNER_TEMP/ue5-macos-editor-action-graph.json"
audit_file="$RUNNER_TEMP/ue5-macos-editor-action-graph-probe.txt"

fail() {
  {
    echo 'UE5_MACOS_EDITOR_ACTION_GRAPH_PROBE_FAILED'
    echo 'buildscw=false'
    printf 'error=%s\n' "$*"
  } > "$audit_file"
  echo "::error::$*"
  exit 1
}

test "$(uname -s)" = Darwin || fail 'This action graph probe must run on macOS.'
command -v jq >/dev/null || fail 'jq is unavailable.'
test -x "$build_command" || fail 'The UE Mac Build.sh is unavailable.'
test -f "$project_file" || fail 'The EpicZenGarden project descriptor is unavailable.'
jq --exit-status 'type == "object"' "$project_file" >/dev/null ||
  fail 'The project descriptor is not JSON.'

start_seconds="$(date +%s)"
set +e
(
  cd "$SOURCE_DIR"
  "$build_command" UnrealEditor Mac Development \
    "-Project=$project_file" \
    "-WriteOutdatedActions=$output_file" \
    -NoUBTMakefiles \
    -NoUBA \
    -NoUBALocal \
    -NoXGE \
    -NoFASTBuild \
    -NoSNDBS \
    -NoArtifactReads \
    -NoArtifactWrites
)
command_status=$?
set -e
elapsed_seconds="$(( $(date +%s) - start_seconds ))"

test "$command_status" = 0 || fail "UnrealBuildTool action graph export failed (exit ${command_status})."
test -s "$output_file" || fail 'UnrealBuildTool did not write an action graph.'
jq --exit-status '.Actions | type == "array" and length > 0' "$output_file" >/dev/null ||
  fail 'The exported action graph has no Actions array.'

action_count="$(jq -r '.Actions | length' "$output_file")"
[[ "$action_count" =~ ^[0-9]+$ ]] || fail 'The exported action count is invalid.'

{
  echo 'UE5_MACOS_EDITOR_ACTION_GRAPH_PROBE_SUCCESS'
  echo 'buildscw=false'
  printf 'action_count=%s\n' "$action_count"
  printf 'export_seconds=%s\n' "$elapsed_seconds"
  echo 'graph_upload=disabled'
} > "$audit_file"

{
  echo '## UE 5.5.4 editor action-graph probe'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  echo '| ShaderCompileWorker prebuild | `disabled` |'
  printf '| Action graph actions | `%s` |\n' "$action_count"
  printf '| Export time | `%s s` |\n' "$elapsed_seconds"
  echo '| Build execution | `disabled; action graph export only` |'
  echo '| Licensed graph/project upload | `disabled` |'
} >> "$GITHUB_STEP_SUMMARY"

printf 'Exported %s editor actions without ShaderCompileWorker prebuild in %s seconds.\n' \
  "$action_count" "$elapsed_seconds"
