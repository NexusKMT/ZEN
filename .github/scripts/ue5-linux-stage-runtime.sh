#!/usr/bin/env bash

set -euo pipefail

: "${UE5_VERSION:?UE5_VERSION is required}"

readonly_root=/workspace/EpicZenGarden
output_root=/workspace/output
stage_project_root="$output_root/EpicZenGarden-ue5-stage-project"
archive_root="$output_root/ue5-linux-stage-archive"
manifest="$output_root/ue5-linux-stage-manifest.txt"
project_name=EpicZenGarden

test -r "$readonly_root/${project_name}.uproject"
test -d "$readonly_root/Content"
if touch "$readonly_root/.ue5-stage-write-probe" 2>/dev/null; then
  echo "The bridge output unexpectedly accepted a write." >&2
  exit 1
fi

rm -rf "$stage_project_root" "$archive_root"
mkdir -p "$stage_project_root" "$archive_root"
cp "$readonly_root/${project_name}.uproject" "$stage_project_root/"
if [[ -d "$readonly_root/Config" ]]; then
  cp -a "$readonly_root/Config" "$stage_project_root/"
fi
ln -s "$readonly_root/Content" "$stage_project_root/Content"
for extra in Plugins Binaries Source; do
  if [[ -e "$readonly_root/$extra" ]]; then
    ln -s "$readonly_root/$extra" "$stage_project_root/$extra"
  fi
done
if [[ -d "$readonly_root/Build" ]]; then
  cp -a "$readonly_root/Build" "$stage_project_root/Build"
  chmod -R a+rwX "$stage_project_root/Build"
fi

runtime_dir="$output_root/ue5-stage-runtime"
ddc_dir="$output_root/ue5-stage-ddc"
uat_log="$output_root/ue5-linux-stage-uat.log"
mkdir -p "$runtime_dir" "$ddc_dir"
chmod 0700 "$runtime_dir"
export XDG_RUNTIME_DIR="$runtime_dir"

echo "ZEN_UE5_STAGE_BEGIN version=$UE5_VERSION platform=Linux"
set +e
env \
  "UE-LocalDataCachePath=$ddc_dir" \
  /home/ue4/UnrealEngine/Engine/Build/BatchFiles/RunUAT.sh \
  BuildCookRun \
  "-project=$stage_project_root/${project_name}.uproject" \
  -noP4 -unattended -utf8output -nodebuginfo \
  -platform=Linux -clientconfig=Development -serverconfig=Development \
  -build -cook -stage -package -pak -archive \
  "-archivedirectory=$archive_root" \
  -map=/Game/Maps/Zen_Movie+/Game/Maps/Zen_P 2>&1 | tee "$uat_log"
uat_pipeline_status=("${PIPESTATUS[@]}")
set -e

uat_status="${uat_pipeline_status[0]}"
tee_status="${uat_pipeline_status[1]}"
if [[ "$tee_status" != 0 ]]; then
  echo "Failed to capture the UE ${UE5_VERSION} stage UAT log (tee status ${tee_status})." >&2
  exit "$tee_status"
fi
if [[ "$uat_status" != 0 ]]; then
  echo "UE ${UE5_VERSION} BuildCookRun failed with process status ${uat_status}." >&2
  exit "$uat_status"
fi

# The constrained runner's three shader workers emit one fixed performance
# warning. Any other UE category diagnostic invalidates the staged package.
allowed_engine_warning='LogShaderCompilers: Warning: Only 3 SCWs will be spawned, which will result in longer shader compile times.'
unexpected_engine_diagnostics="$(grep -E \
  '(^|])([A-Za-z][A-Za-z0-9_]+): (Error|Warning):|LogInit: Display: ([A-Za-z][A-Za-z0-9_]+): (Error|Warning):' \
  "$uat_log" | grep -Fv -- "$allowed_engine_warning" || true)"
if [[ -n "$unexpected_engine_diagnostics" ]]; then
  echo "The UE ${UE5_VERSION} BuildCookRun log emitted an unexpected engine error or warning." >&2
  printf '%s\n' "$unexpected_engine_diagnostics" >&2
  exit 1
fi

if grep -Eiq \
  '(^|])Log[A-Za-z0-9_]+: Error:|Exiting abnormally|Fatal error|Critical error|Assertion failed|Unhandled Exception|Segmentation fault|Cook failed|Unknown Cook Failure' \
  "$uat_log"
then
  echo "The UE ${UE5_VERSION} BuildCookRun log contains an engine error, abnormal-exit, or fatal marker." >&2
  exit 1
fi

echo "ZEN_UE5_STAGE_UAT_SUCCESS"

test -d "$archive_root"
find "$archive_root" -type f -printf '%P\t%s\n' | LC_ALL=C sort > "$manifest"
test -s "$manifest"

pak_count="$(find "$archive_root" -type f -path '*/Content/Paks/*' -name '*.pak' -printf '\n' | wc -l | tr -d '[:space:]')"
if [[ "$pak_count" -lt 1 ]]; then
  echo "The staged package does not contain a Pak file." >&2
  exit 1
fi

if find "$archive_root" -type f \( -name '*.uasset' -o -name '*.umap' \) -print -quit | grep -q .; then
  echo "The staged package unexpectedly contains loose Unreal asset packages." >&2
  find "$archive_root" -type f \( -name '*.uasset' -o -name '*.umap' \) -print
  exit 1
fi

mapfile -t launchers < <(
  find "$archive_root" -type f -name "${project_name}.sh" -printf '%p\n' | LC_ALL=C sort
)
if [[ "${#launchers[@]}" != 1 ]]; then
  echo "Expected exactly one staged ${project_name}.sh launcher; found ${#launchers[@]}." >&2
  printf '%s\n' "${launchers[@]}" >&2
  exit 1
fi
launcher="${launchers[0]}"
test -x "$launcher"

elf_count="$(find "$archive_root" -type f -path '*/Binaries/Linux/*' -perm /111 -printf '\n' | wc -l | tr -d '[:space:]')"
if [[ "$elf_count" -lt 1 ]]; then
  echo "The staged package does not contain an executable Linux binary." >&2
  exit 1
fi

echo "ZEN_UE5_STAGE_PACKAGE_SUCCESS files=$(wc -l < "$manifest" | tr -d '[:space:]') pak_files=$pak_count linux_binaries=$elf_count"
echo "ZEN_UE5_STAGE_LAUNCHER path=${launcher#"$archive_root"/}"

require_runtime_evidence() {
  local map_name="$1"
  local runtime_log="$output_root/ue5-linux-runtime-${map_name}.log"
  local runtime_status
  local unexpected_engine_diagnostics

  set +e
  (
    cd "$(dirname "$launcher")"
    timeout -k 60s 300s \
      "$launcher" \
      "/Game/Maps/${map_name}" \
      -nullrhi -nosound -unattended -NoSplash -NoP4 \
      -stdout -FullStdOutLogOutput -UTF8Output \
      '-ExecCmds=obj list class=LevelSequence,quit'
  ) > "$runtime_log" 2>&1
  runtime_status="$?"
  set -e

  cat "$runtime_log"
  echo "UE ${UE5_VERSION} staged ${map_name} runtime process status: $runtime_status"

  if [[ "$runtime_status" = 124 ]]; then
    echo "The staged ${map_name} runtime timed out." >&2
    exit 1
  fi
  if [[ "$runtime_status" != 0 ]]; then
    echo "The staged ${map_name} runtime failed." >&2
    exit "$runtime_status"
  fi

  local required_lines=(
    "Running engine for game: ${project_name}"
    "LogInit: Command Line: /Game/Maps/${map_name}"
    'LogExit: Exiting.'
  )
  local required_line
  for required_line in "${required_lines[@]}"; do
    if ! grep -Fq -- "$required_line" "$runtime_log"; then
      echo "The staged ${map_name} runtime log is missing required evidence: ${required_line}" >&2
      exit 1
    fi
  done

  if ! grep -Eq "LoadMap:.*${map_name}|Bringing up level for play.*${map_name}|LogWorld:.*${map_name}|LogLoad:.*${map_name}" "$runtime_log"; then
    echo "The staged ${map_name} runtime log does not show map load evidence." >&2
    exit 1
  fi

  unexpected_engine_diagnostics="$(grep -E \
    '(^|])([A-Za-z][A-Za-z0-9_]+): (Error|Warning):|LogInit: Display: ([A-Za-z][A-Za-z0-9_]+): (Error|Warning):' \
    "$runtime_log" || true)"
  if [[ -n "$unexpected_engine_diagnostics" ]]; then
    echo "The staged ${map_name} runtime emitted an engine error or warning." >&2
    printf '%s\n' "$unexpected_engine_diagnostics" >&2
    exit 1
  fi

  if grep -Eiq \
    'XDG_RUNTIME_DIR not set|Exiting abnormally|Fatal error|Critical error|Assertion failed|Unhandled Exception|Segmentation fault|Failed to load package|Failed to load Outer|Failed to find object|Failed to open map' \
    "$runtime_log"
  then
    echo "The staged ${map_name} runtime log contains an environment, load, abnormal-exit, or fatal marker." >&2
    exit 1
  fi

  echo "ZEN_UE5_RUNTIME_MAP_SUCCESS map=${map_name}"
}

require_runtime_evidence Zen_Movie
require_runtime_evidence Zen_P

for sequence_name in \
  MatineeActor_MovieLevelSequence \
  MatineeActorLevelSequence \
  MatineeActor3LevelSequence
do
  if ! grep -Fq -- "$sequence_name" "$output_root/ue5-linux-runtime-Zen_Movie.log" \
    && ! grep -Fq -- "$sequence_name" "$output_root/ue5-linux-runtime-Zen_P.log"
  then
    echo "The staged runtime did not enumerate ${sequence_name}." >&2
    exit 1
  fi
  echo "ZEN_UE5_RUNTIME_SEQUENCE_LOADED asset=${sequence_name}"
done

echo "ZEN_UE5_STAGE_RUNTIME_SUCCESS"
