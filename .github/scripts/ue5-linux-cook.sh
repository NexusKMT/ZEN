#!/usr/bin/env bash

set -euo pipefail

: "${UE5_VERSION:?UE5_VERSION is required}"

readonly_root=/workspace/EpicZenGarden
output_root=/workspace/output
cook_root="$output_root/EpicZenGarden-ue5-cook"
manifest="$output_root/ue5-linux-cook-manifest.txt"

test -r "$readonly_root/EpicZenGarden.uproject"
test -d "$readonly_root/Content"
if touch "$readonly_root/.ue5-cook-write-probe" 2>/dev/null; then
  echo "The bridge output unexpectedly accepted a write." >&2
  exit 1
fi

rm -rf "$cook_root"
mkdir -p "$cook_root"
cp "$readonly_root/EpicZenGarden.uproject" "$cook_root/"
if [[ -d "$readonly_root/Config" ]]; then
  cp -a "$readonly_root/Config" "$cook_root/"
fi
ln -s "$readonly_root/Content" "$cook_root/Content"
for extra in Plugins Binaries Source Build; do
  if [[ -e "$readonly_root/$extra" ]]; then
    ln -s "$readonly_root/$extra" "$cook_root/$extra"
  fi
done

runtime_dir="$output_root/ue5-cook-runtime"
ddc_dir="$output_root/ue5-cook-ddc"
mkdir -p "$runtime_dir" "$ddc_dir"
chmod 0700 "$runtime_dir"
export XDG_RUNTIME_DIR="$runtime_dir"

echo "ZEN_UE5_COOK_BEGIN version=$UE5_VERSION platform=Linux"
env \
  "UE-LocalDataCachePath=$ddc_dir" \
  /home/ue4/UnrealEngine/Engine/Binaries/Linux/UnrealEditor-Cmd \
  "$cook_root/EpicZenGarden.uproject" \
  -run=Cook \
  -TargetPlatform=Linux \
  -Map=/Game/Maps/Zen_Movie+/Game/Maps/Zen_P \
  -unattended -BuildMachine -NullRHI -NoSound -NoSplash -NoP4 \
  -CrashForUAT -stdout -FullStdOutLogOutput -UTF8Output
echo "ZEN_UE5_COOK_COMMANDLET_SUCCESS"

cooked_root="$cook_root/Saved/Cooked"
test -d "$cooked_root"
find "$cooked_root" -type f -printf '%P\n' | LC_ALL=C sort > "$manifest"
test -s "$manifest"

require_cooked_asset() {
  local asset_type="$1"
  local filename="$2"
  local pattern="(^|/)Content/Maps/${filename}$"
  local match_count

  match_count="$(grep -Ec "$pattern" "$manifest" || true)"
  if [[ "$match_count" != 1 ]]; then
    echo "Expected exactly one cooked ${asset_type} named ${filename}; found ${match_count}." >&2
    grep -E "(^|/)${filename}$" "$manifest" || true
    exit 1
  fi

  echo "ZEN_UE5_COOK_ASSET type=${asset_type} file=${filename}"
}

require_cooked_asset map Zen_Movie.umap
require_cooked_asset map Zen_P.umap
require_cooked_asset sequence MatineeActor_MovieLevelSequence.uasset
require_cooked_asset sequence MatineeActorLevelSequence.uasset
require_cooked_asset sequence MatineeActor3LevelSequence.uasset

cooked_file_count="$(wc -l < "$manifest" | tr -d '[:space:]')"
if [[ "$cooked_file_count" -lt 5 ]]; then
  echo "Cook manifest is unexpectedly small: ${cooked_file_count} files." >&2
  exit 1
fi

echo "ZEN_UE5_COOK_SUCCESS files=$cooked_file_count"
