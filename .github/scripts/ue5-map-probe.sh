#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${SOURCE_CLEANUP_REQUESTED:?SOURCE_CLEANUP_REQUESTED is required}"
: "${UE427_PROJECT_DIR:?UE427_PROJECT_DIR is required}"
: "${UE5_IMAGE:?UE5_IMAGE is required}"
: "${UE5_VERSION:?UE5_VERSION is required}"

probe_log="$RUNNER_TEMP/ue5-map-probe.log"
set +e
# Full project + map load is much heavier than a bare engine boot. GNU timeout
# needs -k so ignored SIGTERM cannot hang the step forever. Keep the licensed
# bridge output read-only and use a writable probe root that links to Content.
timeout -k 60s 600s docker run --rm \
  --mount "type=bind,src=${UE427_PROJECT_DIR},dst=/workspace/EpicZenGarden,readonly" \
  --mount "type=bind,src=${GITHUB_WORKSPACE}/.github/scripts/ue5-map-probe.py,dst=/workspace/ue5-map-probe.py,readonly" \
  --env "UE5_VERSION=$UE5_VERSION" \
  "$UE5_IMAGE" \
  bash -lc '
    set -euo pipefail
    ro_root=/workspace/EpicZenGarden
    test -r "$ro_root/EpicZenGarden.uproject"
    echo "Verified that the project descriptor is readable."
    test -d "$ro_root/Content"
    echo "Verified that the project Content directory exists."
    test -f "$ro_root/Content/Maps/Zen_Movie.umap"
    echo "Verified that Content/Maps/Zen_Movie.umap exists on the bridge output."
    test -f "$ro_root/Content/Maps/Zen_P.umap"
    echo "Verified that Content/Maps/Zen_P.umap exists on the bridge output."
    test -f "$ro_root/Content/Maps/MatineeActor_MovieLevelSequence.uasset"
    test -f "$ro_root/Content/Maps/MatineeActorLevelSequence.uasset"
    test -f "$ro_root/Content/Maps/MatineeActor3LevelSequence.uasset"
    echo "Verified that all three generated Level Sequence packages exist on the bridge output."
    if touch "$ro_root/.write-probe" 2>/dev/null; then
      echo "Project mount unexpectedly accepted a write." >&2
      exit 1
    fi
    echo "Verified that the read-only project mount rejected a write."

    probe_root=/tmp/EpicZenGarden-ue5-probe
    rm -rf "$probe_root"
    mkdir -p "$probe_root"
    cp "$ro_root/EpicZenGarden.uproject" "$probe_root/"
    if [[ -d "$ro_root/Config" ]]; then
      cp -a "$ro_root/Config" "$probe_root/"
    fi
    ln -s "$ro_root/Content" "$probe_root/Content"
    for extra in Plugins Binaries Source Build; do
      if [[ -e "$ro_root/$extra" ]]; then
        ln -s "$ro_root/$extra" "$probe_root/$extra"
      fi
    done
    echo "Prepared writable UE $UE5_VERSION probe root with read-only Content symlink."

    runtime_dir=/tmp/ue-runtime
    ddc_dir=/tmp/ue-ddc
    mkdir -p "$runtime_dir" "$ddc_dir"
    chmod 0700 "$runtime_dir"
    # Hyphenated UE env vars are not valid bash identifiers; pass via env(1).
    export XDG_RUNTIME_DIR="$runtime_dir"
    test -r /workspace/ue5-map-probe.py

    env \
      "UE-LocalDataCachePath=$ddc_dir" \
      /home/ue4/UnrealEngine/Engine/Binaries/Linux/UnrealEditor-Cmd \
      "$probe_root/EpicZenGarden.uproject" \
      -run=pythonscript \
      -script=/workspace/ue5-map-probe.py \
      -unattended -BuildMachine -NullRHI -NoSound -NoSplash -NoP4 \
      -stdout -FullStdOutLogOutput -UTF8Output
  ' > "$probe_log" 2>&1
probe_status="$?"
set -e

cat "$probe_log"
echo "UE ${UE5_VERSION} probe process status: $probe_status"

if [[ "$probe_status" = 124 ]]; then
  echo "::error::The UE ${UE5_VERSION} three-sequence probe timed out."
  exit 1
fi
if [[ "$probe_status" != 0 ]]; then
  echo "::error::The UE ${UE5_VERSION} three-sequence probe failed."
  exit "$probe_status"
fi

if grep -Eq 'LogBlueprint: (Error|Warning):|LogInit: Display: LogBlueprint: (Error|Warning):' "$probe_log"; then
  echo "::error::The UE ${UE5_VERSION} probe emitted a Blueprint compiler error or warning."
  grep -E 'LogBlueprint: (Error|Warning):|LogInit: Display: LogBlueprint: (Error|Warning):' "$probe_log" || true
  exit 1
fi

required_probe_lines=(
  'Verified that the project descriptor is readable.'
  'Verified that the project Content directory exists.'
  'Verified that Content/Maps/Zen_Movie.umap exists on the bridge output.'
  'Verified that Content/Maps/Zen_P.umap exists on the bridge output.'
  'Verified that all three generated Level Sequence packages exist on the bridge output.'
  'Verified that the read-only project mount rejected a write.'
  "Prepared writable UE ${UE5_VERSION} probe root with read-only Content symlink."
  "LogInit:  - we're running without rendering"
  'ZEN_UE5_PROBE_MAP_LOADED world=/Game/Maps/Zen_Movie.Zen_Movie'
  'ZEN_UE5_PROBE_SEQUENCE_LOADED asset=/Game/Maps/MatineeActor_MovieLevelSequence.MatineeActor_MovieLevelSequence class=LevelSequence'
  'ZEN_UE5_PROBE_MAP_LOADED world=/Game/Maps/Zen_P.Zen_P'
  'ZEN_UE5_PROBE_SEQUENCE_LOADED asset=/Game/Maps/MatineeActorLevelSequence.MatineeActorLevelSequence class=LevelSequence'
  'ZEN_UE5_PROBE_SEQUENCE_LOADED asset=/Game/Maps/MatineeActor3LevelSequence.MatineeActor3LevelSequence class=LevelSequence'
  'ZEN_UE5_PROBE_SUCCESS'
  'MapCheck: Map check complete: 0 Error(s), 0 Warning(s)'
  'Commandlet PythonScriptCommandlet_0 finished execution (result 0)'
  'LogExit: Exiting.'
)
for required_line in "${required_probe_lines[@]}"; do
  if ! grep -Fq -- "$required_line" "$probe_log"; then
    echo "::error::The UE ${UE5_VERSION} probe log is missing required success evidence: ${required_line}"
    exit 1
  fi
done

if ! grep -Fq "LogInit: Engine Version: ${UE5_VERSION}-" "$probe_log"; then
  echo "::error::The probe log does not identify the required UE ${UE5_VERSION} runtime."
  exit 1
fi

required_probe_regexes=(
  'Running engine for game: EpicZenGarden'
  '/Game/Maps/Zen_Movie'
  'Zen_Movie'
  '/Game/Maps/Zen_P'
  'MatineeActorLevelSequence'
  'MatineeActor3LevelSequence'
)
for required_regex in "${required_probe_regexes[@]}"; do
  if ! grep -Eq -- "$required_regex" "$probe_log"; then
    echo "::error::The UE ${UE5_VERSION} probe log is missing required load evidence matching: ${required_regex}"
    exit 1
  fi
done

# Prefer strong LoadMap evidence when present; fall back to package path hits.
for map_name in Zen_Movie Zen_P; do
  if ! grep -Eq "Cmd: MAP LOAD FILE=.*${map_name}\\.umap|LoadMap:.*${map_name}|Loading map.*${map_name}|LogLoad:.*${map_name}" "$probe_log"; then
    if ! grep -Eq "LogPackageName:.*${map_name}|LogEditorLoad:.*${map_name}|LogWorld:.*${map_name}" "$probe_log"; then
      echo "::error::The UE ${UE5_VERSION} probe log does not show ${map_name} map/package load evidence."
      exit 1
    fi
  fi
done

mapcheck_success_count="$(grep -Fc 'MapCheck: Map check complete: 0 Error(s), 0 Warning(s)' "$probe_log")"
if [[ "$mapcheck_success_count" != 2 ]]; then
  echo "::error::The UE ${UE5_VERSION} probe did not produce exactly two clean MapCheck results."
  exit 1
fi

# Clean transfers require no CreateExport warnings. Retained-source transfers
# remain diagnostic and require the exact transitional warning set.
expected_create_export_warnings=()
if [[ "$SOURCE_CLEANUP_REQUESTED" != "true" ]]; then
  expected_create_export_warnings+=(
    "CreateExport: Failed to load Outer for resource 'Sprite': MatineeActor /Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_3"
    "CreateExport: Failed to load Outer for resource 'InterpCurveEdSetup_0': InterpData /Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_3.InterpData_0"
    "CreateExport: Failed to load Outer for resource 'SceneComp': MatineeActor /Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_3"
    "CreateExport: Failed to load Outer for resource 'Sprite': MatineeActor /Game/Maps/Zen_Movie.Zen_Movie:PersistentLevel.MatineeActor_Movie"
    "CreateExport: Failed to load Outer for resource 'InterpCurveEdSetup_0': InterpData /Game/Maps/Zen_Movie.Zen_Movie:PersistentLevel.MatineeActor_Movie.InterpData_0"
    "CreateExport: Failed to load Outer for resource 'SceneComp': MatineeActor /Game/Maps/Zen_Movie.Zen_Movie:PersistentLevel.MatineeActor_Movie"
    "CreateExport: Failed to load Outer for resource 'Sprite': MatineeActor /Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_0"
    "CreateExport: Failed to load Outer for resource 'InterpCurveEdSetup_0': InterpData /Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_0.InterpData_0"
    "CreateExport: Failed to load Outer for resource 'SceneComp': MatineeActor /Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_0"
  )
fi
if grep -F 'CreateExport:' "$probe_log" |
  grep -Fvq 'LoadErrors: Warning: CreateExport:'
then
  echo "::error::The UE ${UE5_VERSION} probe produced a CreateExport line outside the audited warning format."
  grep -F 'CreateExport:' "$probe_log" |
    grep -Fv 'LoadErrors: Warning: CreateExport:' || true
  exit 1
fi
observed_create_export_warnings=()
while IFS= read -r warning_line; do
  warning="${warning_line#*LoadErrors: Warning: }"
  warning_already_observed=false
  if [[ "${#observed_create_export_warnings[@]}" -gt 0 ]]; then
    for observed_warning in "${observed_create_export_warnings[@]}"; do
      if [[ "$observed_warning" == "$warning" ]]; then
        warning_already_observed=true
        break
      fi
    done
  fi
  if [[ "$warning_already_observed" != true ]]; then
    observed_create_export_warnings+=("$warning")
  fi
done < <(grep -F 'LoadErrors: Warning: CreateExport:' "$probe_log" || true)

if [[ "${#observed_create_export_warnings[@]}" != "${#expected_create_export_warnings[@]}" ]]; then
  echo "::error::The UE ${UE5_VERSION} probe produced an unexpected number of unique CreateExport warnings."
  if [[ "${#observed_create_export_warnings[@]}" -gt 0 ]]; then
    printf 'Observed: %s\n' "${observed_create_export_warnings[@]}"
  else
    echo 'Observed: none'
  fi
  exit 1
fi
for expected_warning in "${expected_create_export_warnings[@]}"; do
  warning_was_observed=false
  for observed_warning in "${observed_create_export_warnings[@]}"; do
    if [[ "$observed_warning" == "$expected_warning" ]]; then
      warning_was_observed=true
      break
    fi
  done
  if [[ "$warning_was_observed" != true ]]; then
    echo "::error::The UE ${UE5_VERSION} probe is missing the expected transitional warning: ${expected_warning}"
    exit 1
  fi
done
for observed_warning in "${observed_create_export_warnings[@]}"; do
  warning_is_expected=false
  for expected_warning in "${expected_create_export_warnings[@]}"; do
    if [[ "$observed_warning" == "$expected_warning" ]]; then
      warning_is_expected=true
      break
    fi
  done
  if [[ "$warning_is_expected" != true ]]; then
    echo "::error::The UE ${UE5_VERSION} probe produced an unexpected CreateExport warning: ${observed_warning}"
    exit 1
  fi
done

if grep -Eiq \
  'XDG_RUNTIME_DIR not set|Exiting abnormally|Fatal error|Critical error|Assertion failed|Unhandled Exception|Segmentation fault|LoadErrors: Error:|LoadPackage: SkipPackage: /Game/Maps/MatineeActor(3|_Movie)?LevelSequence' \
  "$probe_log"
then
  echo "::error::The UE ${UE5_VERSION} probe log contains a missing sequence, environment, abnormal-exit, or fatal marker."
  exit 1
fi

echo "UE ${UE5_VERSION} loaded Zen_Movie and Zen_P plus all three generated Level Sequences from the bridge output with project Content remaining read-only."

{
  echo
  echo '## UE container probe'
  echo
  printf 'Validated `%s` by loading `Zen_Movie`, `Zen_P`, and three generated Level Sequences from the UE 4.27 bridge output.\n' "$UE5_IMAGE"
  echo
  echo '- Bridge project mount: read-only'
  echo '- Probe project root: writable shell with Content symlink'
  echo '- Maps: `/Game/Maps/Zen_Movie`, `/Game/Maps/Zen_P`'
  echo '- Generated sequences loaded: `3`'
  printf '%s\n' \
    "- Transitional source Matinee export warnings: \`${#observed_create_export_warnings[@]}\` (exact set verified)"
} >> "$GITHUB_STEP_SUMMARY"
