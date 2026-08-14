#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${IOS_APP_TRANSFER_DIR:?IOS_APP_TRANSFER_DIR is required}"
: "${UE5_VERSION:?UE5_VERSION is required}"

unsigned_root="$RUNNER_TEMP/ue5-ios-a8a9-unsigned"
output_root="$RUNNER_TEMP/ue5-ios-a8a9-output"
manifest="$RUNNER_TEMP/ue5-ios-a8a9-merge-manifest.txt"

test "$UE5_VERSION" = "5.5.4"
test -d "$IOS_APP_TRANSFER_DIR"
test ! -L "$IOS_APP_TRANSFER_DIR"
app_count="$(find "$IOS_APP_TRANSFER_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print | awk 'END { print NR + 0 }')"
test "$app_count" = 1 || {
  echo "Expected exactly one transferred .app; found ${app_count}." >&2
  exit 1
}
app="$(find "$IOS_APP_TRANSFER_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
info_plist="$app/Info.plist"
test -f "$info_plist"
app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
[[ "$app_executable" =~ ^[A-Za-z0-9._-]+$ ]]
app_binary="$app/$app_executable"
test -x "$app_binary"
printf '%s\n' "$(/usr/bin/lipo -archs "$app_binary")" | grep -Eq '(^|[[:space:]])arm64($|[[:space:]])'
test ! -e "$app/embedded.mobileprovision"
test ! -e "$app/_CodeSignature"
if /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
  echo 'The transferred app bundle is signed; refusing to merge it as unsigned.' >&2
  exit 1
fi

for reset_dir in "$unsigned_root" "$output_root"; do
  [[ "$reset_dir" == "$RUNNER_TEMP/"* ]]
  test "$reset_dir" != "$RUNNER_TEMP"
  test ! -L "$reset_dir"
  rm -rf -- "$reset_dir"
done
mkdir -p "$unsigned_root/Payload" "$output_root"

payload_app="$unsigned_root/Payload/$(basename "$app")"
/usr/bin/ditto "$app" "$payload_app"
ipa="$output_root/EpicZenGarden-UE${UE5_VERSION}-unsigned.ipa"
(
  cd "$unsigned_root"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$ipa"
)
test -s "$ipa"
zip_listing="$RUNNER_TEMP/ue5-ios-a8a9-merge-zip-list.txt"
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
  echo 'UE5_IOS_UNSIGNED_IPA_MERGE_SUCCESS'
  printf 'ue5_version=%s\n' "$UE5_VERSION"
  printf 'app_name=%s\n' "$(basename "$app")"
  printf 'app_executable=%s\n' "$app_executable"
  printf 'ipa_name=%s\n' "$(basename "$ipa")"
  printf 'ipa_bytes=%s\n' "$ipa_bytes"
  printf 'ipa_sha256=%s\n' "$ipa_sha256"
  echo 'code_signing=disabled'
  echo 'merge_only=true'
} > "$manifest"
printf 'UNSIGNED_IPA_PATH=%s\n' "$ipa" >> "$GITHUB_ENV"
printf 'UNSIGNED_IPA_SHA256=%s\n' "$ipa_sha256" >> "$GITHUB_ENV"

echo "ZEN_UE5_IOS_UNSIGNED_IPA_MERGE_SUCCESS ipa=$ipa sha256=$ipa_sha256"
{
  echo
  echo '## UE5.5.4 unsigned iOS IPA merge'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  printf '| Input app | `%s` |\n' "$(basename "$app")"
  printf '| IPA | `%s`, `%s bytes`, SHA-256 `%s` |\n' "$(basename "$ipa")" "$ipa_bytes" "$ipa_sha256"
  echo '| Operation | `Payload/.app merge only; no UE build, cook, stage, or package` |'
  echo '| Signing / provisioning | `disabled` / `absent` |'
} >> "$GITHUB_STEP_SUMMARY"
