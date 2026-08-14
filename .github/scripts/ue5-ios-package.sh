#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
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
zip_listing="$RUNNER_TEMP/ue5-ios-a8a9-zip-list.txt"
unsigned_root="$RUNNER_TEMP/ue5-ios-a8a9-unsigned"
output_root="$RUNNER_TEMP/ue5-ios-a8a9-output"

test "$UE5_VERSION" = "5.5.4"
test -f "$project_file"
test -f "$build_version_file"
test -x "$uat"
command -v jq >/dev/null
test "$(uname -s)" = Darwin
test -z "${IOS_CODE_SIGN_IDENTITY:-}" || {
  echo 'IOS_CODE_SIGN_IDENTITY must be empty for an unsigned package.' >&2
  exit 1
}
test -z "${IOS_MOBILE_PROVISION:-}" || {
  echo 'IOS_MOBILE_PROVISION must be empty for an unsigned package.' >&2
  exit 1
}

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

for reset_dir in "$archive_root" "$unsigned_root" "$output_root"; do
  [[ "$reset_dir" == "$RUNNER_TEMP/"* ]]
  test "$reset_dir" != "$RUNNER_TEMP"
  test ! -L "$reset_dir"
  rm -rf -- "$reset_dir"
done
mkdir -p "$archive_root" "$unsigned_root/Payload" "$output_root"

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
  -nocodesign
  "-ubtargs=-MaxParallelActions=2 -NoUBA -NoXGE"
  "-xcodebuildoptions=CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM="
)

echo "ZEN_UE5_IOS_UNSIGNED_PACKAGE_BEGIN version=$UE5_VERSION sdk=$sdk_version target=A8/A8X/A9"
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

app_bundles=()
while IFS= read -r app_bundle; do
  app_bundles+=("$app_bundle")
done < <(find "$archive_root" -type d -name '*.app' -prune -print | LC_ALL=C sort)
if [[ "${#app_bundles[@]}" != 1 ]]; then
  echo "Expected exactly one Modern Xcode iOS app bundle; found ${#app_bundles[@]}." >&2
  printf '%s\n' "${app_bundles[@]}" >&2
  exit 1
fi
app="${app_bundles[0]}"
info_plist="$app/Info.plist"
test -f "$info_plist"
app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
[[ "$app_executable" =~ ^[A-Za-z0-9._-]+$ ]]
app_binary="$app/$app_executable"
test -x "$app_binary"
app_architectures="$(/usr/bin/lipo -archs "$app_binary")"
printf '%s\n' "$app_architectures" | grep -Eq '(^|[[:space:]])arm64($|[[:space:]])'
test ! -e "$app/embedded.mobileprovision"
test ! -e "$app/_CodeSignature"
if /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
  echo 'The Modern Xcode app bundle is signed; refusing to label it unsigned.' >&2
  exit 1
fi

payload_app="$unsigned_root/Payload/$(basename "$app")"
/usr/bin/ditto "$app" "$payload_app"
ipa="$output_root/EpicZenGarden-UE${UE5_VERSION}-unsigned.ipa"
(
  cd "$unsigned_root"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$ipa"
)
test -s "$ipa"
unzip -Z1 "$ipa" > "$zip_listing"
grep -Eq 'Payload/[^/]+\.app/Info\.plist$' "$zip_listing"
grep -Fqx "Payload/$(basename "$app")/$app_executable" "$zip_listing"
if grep -Eq '(^|/)(_CodeSignature|embedded\.mobileprovision)(/|$)' "$zip_listing"; then
  echo 'The unsigned IPA unexpectedly contains signing material.' >&2
  exit 1
fi
rm -f "$zip_listing"

ipa_bytes="$(stat -f '%z' "$ipa")"
ipa_sha256="$(shasum -a 256 "$ipa" | awk '{ print $1 }')"
[[ "$ipa_bytes" =~ ^[0-9]+$ ]]
[[ "$ipa_sha256" =~ ^[0-9a-f]{64}$ ]]
{
  echo 'UE5_IOS_UNSIGNED_IPA_SUCCESS'
  printf 'ue5_version=%s\n' "$UE5_VERSION"
  printf 'sdk_version=%s\n' "$sdk_version"
  printf 'app_name=%s\n' "$(basename "$app")"
  printf 'app_executable=%s\n' "$app_executable"
  printf 'app_architectures=%s\n' "$app_architectures"
  printf 'ipa_name=%s\n' "$(basename "$ipa")"
  printf 'ipa_bytes=%s\n' "$ipa_bytes"
  printf 'ipa_sha256=%s\n' "$ipa_sha256"
  echo 'code_signing=disabled'
  echo 'embedded_mobileprovision=absent'
  echo 'public_binary_artifact=disabled'
  echo 'archive_files_begin'
  find "$archive_root" -type f -print 2>/dev/null | sed "s#^$archive_root/##" | LC_ALL=C sort
  echo 'archive_files_end'
} > "$manifest"
printf 'UNSIGNED_IPA_PATH=%s\n' "$ipa" >> "$GITHUB_ENV"
printf 'UNSIGNED_IPA_SHA256=%s\n' "$ipa_sha256" >> "$GITHUB_ENV"

echo "ZEN_UE5_IOS_UNSIGNED_PACKAGE_SUCCESS ipa=$ipa sdk=$sdk_version sha256=$ipa_sha256"
{
  echo
  echo '## UE5.5.4 unsigned iOS A8/A9 package'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  echo '| Engine | `UE 5.5.4` |'
  printf '| iPhoneOS SDK | `%s` |\n' "$sdk_version"
  echo '| Target | `A8 / A8X / A9, arm64` |'
  echo '| Compatibility profile | `bSupportAppleA8=True, iOS 15, Metal 2.4` |'
  echo '| Modern Xcode result | `self-contained .app` |'
  echo '| Signing / provisioning | `disabled` / `absent` |'
  printf '| Unsigned IPA | `%s`, `%s bytes`, SHA-256 `%s` |\n' "$(basename "$ipa")" "$ipa_bytes" "$ipa_sha256"
  echo '| Public artifact upload | `disabled; licensed app content stays on the runner` |'
} >> "$GITHUB_STEP_SUMMARY"
