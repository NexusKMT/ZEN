#!/usr/bin/env bash

set -euo pipefail

project_root="${1:-}"
if [[ -z "$project_root" ]]; then
  echo "Usage: $0 <project-root>" >&2
  exit 2
fi

project_file="$project_root/EpicZenGarden.uproject"
engine_config="$project_root/Config/DefaultEngine.ini"
test -f "$project_file" || {
  echo "UE project descriptor is missing: $project_file" >&2
  exit 1
}

mkdir -p "${engine_config%/*}"

marker="; ZEN UE5.5.4 A8/A9 compatibility profile"
if ! grep -Fqx "$marker" "$engine_config" 2>/dev/null; then
  cat >> "$engine_config" <<'EOF'

; ZEN UE5.5.4 A8/A9 compatibility profile
[/Script/IOSRuntimeSettings.IOSRuntimeSettings]
bSupportAppleA8=True
bSupportsMetal=True
bSupportsMetalMRT=False
MinimumiOSVersion=IOS_15

[SystemSettings]
r.Mobile.ShadingPath=0
r.MobileHDR=1
r.Nanite=0
r.VirtualTextures=0
r.Shadow.Virtual.Enable=0
r.Lumen.Reflections=0
r.Lumen.GlobalIllumination=0
EOF
fi

unsigned_marker="; ZEN UE5.5.4 unsigned Modern Xcode profile v2"
if ! grep -Fqx "$unsigned_marker" "$engine_config" 2>/dev/null; then
  cat >> "$engine_config" <<'EOF'

; ZEN UE5.5.4 unsigned Modern Xcode profile v2
[/Script/MacTargetPlatform.XcodeProjectSettings]
bUseModernXcode=True
bUseAutomaticCodeSigning=False
EOF
fi

required_settings=(
  'bSupportAppleA8=True'
  'bSupportsMetal=True'
  'bSupportsMetalMRT=False'
  'MinimumiOSVersion=IOS_15'
  'r.Mobile.ShadingPath=0'
  'r.MobileHDR=1'
  'r.Nanite=0'
  'r.VirtualTextures=0'
  'r.Shadow.Virtual.Enable=0'
  'r.Lumen.Reflections=0'
  'r.Lumen.GlobalIllumination=0'
  'bUseModernXcode=True'
  'bUseAutomaticCodeSigning=False'
)
for setting in "${required_settings[@]}"; do
  if ! grep -Fqx "$setting" "$engine_config"; then
    echo "Required UE5.5.4 A8/A9 setting is missing: $setting" >&2
    exit 1
  fi
done

echo "Applied and verified the UE5.5.4 A8/A9 iOS compatibility profile."
echo "  Project: $project_file"
echo "  Renderer: Metal 2.4 / traditional mobile"
echo "  Minimum iOS: 15"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo
    echo '## UE5.5.4 A8/A9 iOS compatibility profile'
    echo
    echo '| Setting | Value |'
    echo '| --- | --- |'
    echo '| Apple target | `A8 / A8X / A9` |'
    echo '| iOS minimum | `IOS_15` |'
    echo '| Renderer | `Metal 2.4, traditional Mobile Renderer` |'
    echo '| A8 support | `bSupportAppleA8=True` |'
    echo '| Xcode packaging | `Modern Xcode, code signing disabled` |'
    echo '| Modern renderer features | `Lumen/Nanite/Virtual Textures/Virtual Shadow Maps disabled` |'
  } >> "$GITHUB_STEP_SUMMARY"
fi
