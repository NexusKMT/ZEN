#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${UE427_PROJECT_DIR:?UE427_PROJECT_DIR is required}"
: "${UE5_ROOT:?UE5_ROOT must point to the UE 5.5.4 Engine directory}"
: "${UE5_VERSION:?UE5_VERSION is required}"

project_file="$UE427_PROJECT_DIR/EpicZenGarden.uproject"
build_version_file="$UE5_ROOT/Build/Build.version"
uat="$UE5_ROOT/Build/BatchFiles/RunUAT.sh"
archive_root="$RUNNER_TEMP/ue5-ios-a8a9-archive"
uat_log="$RUNNER_TEMP/ue5-ios-a8a9-uat.log"
manifest="$RUNNER_TEMP/ue5-ios-a8a9-manifest.txt"

test "$UE5_VERSION" = "5.5.4"
test -f "$project_file"
test -f "$build_version_file"
test -x "$uat"
command -v jq >/dev/null

build_version="$(cat "$build_version_file")"
printf '%s\n' "$build_version" | jq --exit-status '
  .MajorVersion == 5 and .MinorVersion == 5 and .PatchVersion == 4
' >/dev/null || {
  echo "UE5_ROOT does not contain UE 5.5.4: $UE5_ROOT" >&2
  printf '%s\n' "$build_version" >&2
  exit 1
}

xcodebuild -version
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
test -n "$sdk_version"
xcrun --sdk iphoneos --find clang >/dev/null

chmod -R u+rwX "$UE427_PROJECT_DIR"
bash "$GITHUB_WORKSPACE/.github/scripts/apply-ue5-ios-a8a9-config.sh" "$UE427_PROJECT_DIR"

rm -rf "$archive_root"
mkdir -p "$archive_root"

uat_args=(
  BuildCookRun
  "-project=$project_file"
  -noP4
  -unattended
  -utf8output
  -nodebuginfo
  -platform=IOS
  -clientconfig=Development
  -build
  -cook
  -stage
  -package
  -pak
  -archive
  "-archivedirectory=$archive_root"
  -map=/Game/Maps/Zen_Movie+/Game/Maps/Zen_P
)

if [[ -n "${IOS_CODE_SIGN_IDENTITY:-}" ]]; then
  uat_args+=("-CodeSignIdentity=$IOS_CODE_SIGN_IDENTITY")
fi
if [[ -n "${IOS_MOBILE_PROVISION:-}" ]]; then
  uat_args+=("-MobileProvision=$IOS_MOBILE_PROVISION")
fi

echo "ZEN_UE5_IOS_PACKAGE_BEGIN version=$UE5_VERSION sdk=$sdk_version target=A8/A8X/A9"
set +e
"$uat" "${uat_args[@]}" 2>&1 | tee "$uat_log"
uat_pipeline_status=("${PIPESTATUS[@]}")
set -e

uat_status="${uat_pipeline_status[0]}"
tee_status="${uat_pipeline_status[1]}"
test "$tee_status" = 0 || {
  echo "Failed to capture the UE iOS UAT log (tee status $tee_status)." >&2
  exit "$tee_status"
}
test "$uat_status" = 0 || {
  echo "UE $UE5_VERSION iOS BuildCookRun failed with process status $uat_status." >&2
  exit "$uat_status"
}

if grep -Eiq \
  '(^|])Log[A-Za-z0-9_]+: Error:|Exiting abnormally|Fatal error|Critical error|Assertion failed|Unhandled Exception|Segmentation fault|Cook failed|Unknown Cook Failure' \
  "$uat_log"
then
  echo 'The UE iOS UAT log contains an engine error, abnormal exit, or fatal marker.' >&2
  exit 1
fi

test -d "$archive_root"
find "$archive_root" -type f -print 2>/dev/null | sed "s#^$archive_root/##" | LC_ALL=C sort > "$manifest"
test -s "$manifest"

ipa_files=()
while IFS= read -r ipa_file; do
  ipa_files+=("$ipa_file")
done < <(find "$archive_root" -type f -name '*.ipa' -print | LC_ALL=C sort)
if [[ "${#ipa_files[@]}" != 1 ]]; then
  echo "Expected exactly one iOS IPA in the archive; found ${#ipa_files[@]}." >&2
  printf '%s\n' "${ipa_files[@]}" >&2
  exit 1
fi
ipa="${ipa_files[0]}"
unzip -l "$ipa" | grep -Eq 'Payload/[^/]+\.app/Info\.plist$'
app_binary_count="$(unzip -Z1 "$ipa" | awk -F/ '$1 == "Payload" && $3 != "" && $3 !~ /\.app$/ { count++ } END { print count + 0 }')"
test "$app_binary_count" -gt 0

echo "ZEN_UE5_IOS_PACKAGE_SUCCESS ipa=$ipa sdk=$sdk_version"
{
  echo
  echo '## UE5.5.4 iOS A8/A9 package'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  echo '| Engine | `UE 5.5.4` |'
  printf '| iPhoneOS SDK | `%s` |\n' "$sdk_version"
  echo '| Target | `A8 / A8X / A9, arm64` |'
  echo '| Compatibility profile | `bSupportAppleA8=True, iOS 15, Metal 2.4` |'
  printf '| IPA | `%s` (runner-local) |\n' "$ipa"
  echo '| Public artifact upload | `disabled; licensed app content stays on the runner` |'
} >> "$GITHUB_STEP_SUMMARY"
