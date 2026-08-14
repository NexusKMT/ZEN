#!/usr/bin/env bash

set -euo pipefail

: "${GHCR_TOKEN:?GHCR_TOKEN is required}"
: "${GHCR_USERNAME:?GHCR_USERNAME is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

UE5_VERSION="${UE5_VERSION:-5.5.4}"
UE5_IMAGE="${UE5_IMAGE:-ghcr.io/epicgames/unreal-engine:dev-${UE5_VERSION}}"
XCODE_APP="${XCODE_APP:-/Applications/Xcode_15.4.app}"
RECLAIM_XCODE_SPACE="${RECLAIM_XCODE_SPACE:-true}"
PROBE_GHCR_IMAGE="${PROBE_GHCR_IMAGE:-true}"
SOURCE_BUILD_MIN_CPU="${SOURCE_BUILD_MIN_CPU:-4}"
SOURCE_BUILD_MIN_MEMORY_GIB="${SOURCE_BUILD_MIN_MEMORY_GIB:-16}"
SOURCE_BUILD_MIN_DISK_GIB="${SOURCE_BUILD_MIN_DISK_GIB:-150}"

audit_file="$RUNNER_TEMP/ue5-macos-hosted-probe.txt"
ghcr_netrc="$RUNNER_TEMP/ue5-macos-ghcr.netrc"
ghcr_token_response="$RUNNER_TEMP/ue5-macos-ghcr-token.json"
registry_curl_config="$RUNNER_TEMP/ue5-macos-registry.curlrc"
manifest_file="$RUNNER_TEMP/ue5-macos-manifest.json"
config_file="$RUNNER_TEMP/ue5-macos-image-config.json"
platforms_file="$RUNNER_TEMP/ue5-macos-platforms.txt"
github_curl_config="$RUNNER_TEMP/ue5-macos-github.curlrc"
github_response="$RUNNER_TEMP/ue5-macos-github-response.json"

cleanup() {
  rm -f \
    "$ghcr_netrc" \
    "$ghcr_token_response" \
    "$registry_curl_config" \
    "$manifest_file" \
    "$config_file" \
    "$platforms_file" \
    "$github_curl_config" \
    "$github_response"
}
trap cleanup EXIT

fail() {
  {
    echo 'UE5_MACOS_HOSTED_PROBE_FAILED'
    printf 'error=%s\n' "$*"
  } >> "$audit_file"
  echo "::error::$*"
  exit 1
}

disk_free_kib() {
  df -Pk / | awk 'NR == 2 { print $4 }'
}

join_lines() {
  awk 'NF { if (result != "") result = result ", "; result = result $0 } END { print result }' "$1"
}

umask 077
: > "$audit_file"

test "$(uname -s)" = Darwin || fail 'This probe must run on macOS.'
command -v curl >/dev/null || fail 'curl is unavailable.'
command -v jq >/dev/null || fail 'jq is unavailable.'
command -v xcodebuild >/dev/null || fail 'xcodebuild is unavailable.'
command -v xcrun >/dev/null || fail 'xcrun is unavailable.'
[[ "$UE5_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'UE5_VERSION must be an exact patch version.'
[[ "$RECLAIM_XCODE_SPACE" = true || "$RECLAIM_XCODE_SPACE" = false ]] ||
  fail 'RECLAIM_XCODE_SPACE must be true or false.'
[[ "$PROBE_GHCR_IMAGE" = true || "$PROBE_GHCR_IMAGE" = false ]] ||
  fail 'PROBE_GHCR_IMAGE must be true or false.'

target_xcode_parent="$(cd "$(dirname "$XCODE_APP")" && pwd -P)"
target_xcode_name="$(basename "$XCODE_APP")"
test "$target_xcode_parent" = /Applications || fail 'XCODE_APP must be directly below /Applications.'
[[ "$target_xcode_name" =~ ^Xcode_[0-9]+(\.[0-9]+)*\.app$ ]] ||
  fail 'XCODE_APP must be a versioned Xcode application path.'
test ! -L "$XCODE_APP" || fail 'XCODE_APP must not be a symbolic link.'
test -d "$XCODE_APP/Contents/Developer" || fail "Required Xcode is missing: ${XCODE_APP}"

runner_arch="$(uname -m)"
runner_cpu="$(sysctl -n hw.ncpu)"
runner_memory_bytes="$(sysctl -n hw.memsize)"
runner_memory_gib="$((runner_memory_bytes / 1024 / 1024 / 1024))"
disk_before_kib="$(disk_free_kib)"
disk_before_gib="$((disk_before_kib / 1024 / 1024))"

sudo xcode-select --switch "$XCODE_APP/Contents/Developer" ||
  fail 'Could not select the required Xcode developer directory.'
selected_developer_dir="$(xcode-select -p)"
test "$selected_developer_dir" = "$XCODE_APP/Contents/Developer" ||
  fail 'xcode-select did not retain the requested developer directory.'

xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
xcode_build="$(xcodebuild -version | awk 'NR == 2 { print $3 }')"
iphoneos_sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
iphoneos_clang="$(xcrun --sdk iphoneos --find clang)"
test -x "$iphoneos_clang" || fail 'The selected iPhoneOS clang is not executable.'

removed_xcode_count=0
if test "$RECLAIM_XCODE_SPACE" = true; then
  for app in /Applications/Xcode_*.app; do
    test -e "$app" || continue
    test "$app" != "$XCODE_APP" || continue
    test ! -L "$app" || continue

    app_parent="$(cd "$(dirname "$app")" && pwd -P)"
    app_name="$(basename "$app")"
    test "$app_parent" = /Applications || fail "Refusing to remove Xcode outside /Applications: ${app}"
    [[ "$app_name" =~ ^Xcode_[0-9]+(\.[0-9]+)*\.app$ ]] ||
      fail "Refusing to remove an unexpected application path: ${app}"
    test -d "$app/Contents/Developer" ||
      fail "Refusing to remove a directory that is not a complete Xcode application: ${app}"

    echo "Removing unused hosted-runner Xcode: ${app_name}"
    sudo rm -rf -- "$app" || fail "Could not remove unused Xcode: ${app}"
    test ! -e "$app" || fail "Could not remove unused Xcode: ${app}"
    removed_xcode_count=$((removed_xcode_count + 1))
  done
fi

test -d "$XCODE_APP/Contents/Developer" || fail 'The selected Xcode was removed unexpectedly.'
test "$(xcode-select -p)" = "$XCODE_APP/Contents/Developer" ||
  fail 'The selected developer directory changed during space reclamation.'
disk_after_kib="$(disk_free_kib)"
disk_after_gib="$((disk_after_kib / 1024 / 1024))"

ghcr_platforms=not-probed
ghcr_has_darwin=false
if test "$PROBE_GHCR_IMAGE" = true; then
  printf 'machine ghcr.io\nlogin %s\npassword %s\n' "$GHCR_USERNAME" "$GHCR_TOKEN" > "$ghcr_netrc"
  chmod 600 "$ghcr_netrc"

  if ! ghcr_token_http="$(
    curl --silent --show-error \
      --netrc-file "$ghcr_netrc" \
      --get \
      --data-urlencode 'service=ghcr.io' \
      --data-urlencode 'scope=repository:epicgames/unreal-engine:pull' \
      --output "$ghcr_token_response" \
      --write-out '%{http_code}' \
      'https://ghcr.io/token'
  )"; then
    fail 'GHCR token exchange encountered a transport error.'
  fi
  test "$ghcr_token_http" = 200 || fail "GHCR token exchange failed with HTTP ${ghcr_token_http}."
  registry_token="$(jq -er '.token // .access_token' "$ghcr_token_response")" ||
    fail 'GHCR token exchange did not return a registry token.'

  {
    printf 'silent\n'
    printf 'show-error\n'
    printf 'location\n'
    printf 'header = "Authorization: Bearer %s"\n' "$registry_token"
    printf 'header = "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"\n'
  } > "$registry_curl_config"
  chmod 600 "$registry_curl_config"
  unset registry_token

  image_path="${UE5_IMAGE#ghcr.io/}"
  image_repository="${image_path%:*}"
  image_tag="${image_path##*:}"
  test "$image_repository" != "$image_path" || fail 'UE5_IMAGE must include an explicit tag.'
  [[ "$image_repository" =~ ^[a-z0-9._/-]+$ ]] || fail 'UE5_IMAGE contains an invalid repository path.'
  [[ "$image_tag" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'UE5_IMAGE contains an invalid tag.'

  if ! manifest_http="$(
    curl --config "$registry_curl_config" \
      --output "$manifest_file" \
      --write-out '%{http_code}' \
      "https://ghcr.io/v2/${image_repository}/manifests/${image_tag}"
  )"; then
    fail 'GHCR manifest lookup encountered a transport error.'
  fi
  test "$manifest_http" = 200 || fail "GHCR manifest lookup failed with HTTP ${manifest_http}."
  jq -e 'type == "object"' "$manifest_file" >/dev/null || fail 'GHCR returned an invalid image manifest.'

  if jq -e '.manifests | type == "array"' "$manifest_file" >/dev/null 2>&1; then
    jq -r '
      .manifests[]?.platform |
      select(.os != null and .architecture != null and .os != "unknown") |
      if (.variant // "") == "" then
        "\(.os)/\(.architecture)"
      else
        "\(.os)/\(.architecture)/\(.variant)"
      end
    ' "$manifest_file" | sort -u > "$platforms_file"
  else
    config_digest="$(jq -er '.config.digest' "$manifest_file")" ||
      fail 'The single-platform manifest did not contain an image config digest.'
    [[ "$config_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'The image config digest is invalid.'
    if ! config_http="$(
      curl --config "$registry_curl_config" \
        --output "$config_file" \
        --write-out '%{http_code}' \
        "https://ghcr.io/v2/${image_repository}/blobs/${config_digest}"
    )"; then
      fail 'GHCR image config lookup encountered a transport error.'
    fi
    test "$config_http" = 200 || fail "GHCR image config lookup failed with HTTP ${config_http}."
    jq -r '
      if (.os != null and .architecture != null) then
        if (.variant // "") == "" then
          "\(.os)/\(.architecture)"
        else
          "\(.os)/\(.architecture)/\(.variant)"
        end
      else
        empty
      end
    ' "$config_file" > "$platforms_file"
  fi
  test -s "$platforms_file" || fail 'No concrete platform was found in the GHCR image manifest.'
  ghcr_platforms="$(join_lines "$platforms_file")"
  if awk -F/ '$1 == "darwin" { found = 1 } END { exit !found }' "$platforms_file"; then
    ghcr_has_darwin=true
  fi
fi

{
  printf 'silent\n'
  printf 'show-error\n'
  printf 'header = "Accept: application/vnd.github+json"\n'
  printf 'header = "Authorization: Bearer %s"\n' "$GHCR_TOKEN"
  printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
} > "$github_curl_config"
chmod 600 "$github_curl_config"

if ! source_repo_http="$(
  curl --config "$github_curl_config" \
    --output "$github_response" \
    --write-out '%{http_code}' \
    'https://api.github.com/repos/EpicGames/UnrealEngine'
)"; then
  fail 'Epic source repository lookup encountered a transport error.'
fi
source_repo_access=false
source_tag_http=not-queried
source_tag_access=false
if test "$source_repo_http" = 200; then
  source_repo_access=true
  if ! source_tag_http="$(
    curl --config "$github_curl_config" \
      --output "$github_response" \
      --write-out '%{http_code}' \
      "https://api.github.com/repos/EpicGames/UnrealEngine/git/ref/tags/${UE5_VERSION}-release"
  )"; then
    fail 'Epic source tag lookup encountered a transport error.'
  fi
  if test "$source_tag_http" = 200; then
    source_tag_access=true
  fi
fi

capacity_sufficient=true
if (( runner_cpu < SOURCE_BUILD_MIN_CPU )); then
  capacity_sufficient=false
fi
if (( runner_memory_gib < SOURCE_BUILD_MIN_MEMORY_GIB )); then
  capacity_sufficient=false
fi
if (( disk_after_gib < SOURCE_BUILD_MIN_DISK_GIB )); then
  capacity_sufficient=false
fi

if test "$ghcr_has_darwin" = true; then
  next_route=darwin-container-candidate
elif test "$source_repo_access" = true && test "$source_tag_access" = true; then
  if test "$capacity_sufficient" = true; then
    next_route=source-build-experiment-candidate
  else
    next_route=macos-engine-runner-required
  fi
else
  next_route=epic-source-access-or-prebuilt-engine-required
fi

{
  echo 'UE5_MACOS_HOSTED_PROBE_SUCCESS'
  printf 'ue5_version=%s\n' "$UE5_VERSION"
  printf 'runner_arch=%s\n' "$runner_arch"
  printf 'runner_cpu=%s\n' "$runner_cpu"
  printf 'runner_memory_gib=%s\n' "$runner_memory_gib"
  printf 'disk_free_before_gib=%s\n' "$disk_before_gib"
  printf 'disk_free_after_gib=%s\n' "$disk_after_gib"
  printf 'removed_xcode_count=%s\n' "$removed_xcode_count"
  printf 'xcode_version=%s\n' "$xcode_version"
  printf 'xcode_build=%s\n' "$xcode_build"
  printf 'iphoneos_sdk=%s\n' "$iphoneos_sdk"
  printf 'ghcr_platforms=%s\n' "$ghcr_platforms"
  printf 'ghcr_has_darwin=%s\n' "$ghcr_has_darwin"
  printf 'source_repo_http=%s\n' "$source_repo_http"
  printf 'source_repo_access=%s\n' "$source_repo_access"
  printf 'source_tag_http=%s\n' "$source_tag_http"
  printf 'source_tag_access=%s\n' "$source_tag_access"
  printf 'source_build_capacity_sufficient=%s\n' "$capacity_sufficient"
  printf 'next_route=%s\n' "$next_route"
} > "$audit_file"

{
  echo '## UE 5.5.4 hosted macOS feasibility'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  printf '| Runner | `%s`, `%s` CPUs, `%s` GiB RAM |\n' "$runner_arch" "$runner_cpu" "$runner_memory_gib"
  printf '| Xcode / iPhoneOS SDK | `%s (%s)` / `%s` |\n' "$xcode_version" "$xcode_build" "$iphoneos_sdk"
  printf '| Free disk before / after cleanup | `%s GiB` / `%s GiB` |\n' "$disk_before_gib" "$disk_after_gib"
  printf '| Removed unused Xcodes | `%s` |\n' "$removed_xcode_count"
  printf '| `%s` platforms | `%s` |\n' "$UE5_IMAGE" "$ghcr_platforms"
  printf '| GHCR Darwin image | `%s` |\n' "$ghcr_has_darwin"
  printf '| Epic source repository access | `%s` (HTTP `%s`) |\n' "$source_repo_access" "$source_repo_http"
  printf '| `%s-release` tag access | `%s` (HTTP `%s`) |\n' "$UE5_VERSION" "$source_tag_access" "$source_tag_http"
  printf '| Source-build capacity threshold | `%s` (CPU >= %s, RAM >= %s GiB, disk >= %s GiB) |\n' \
    "$capacity_sufficient" "$SOURCE_BUILD_MIN_CPU" "$SOURCE_BUILD_MIN_MEMORY_GIB" "$SOURCE_BUILD_MIN_DISK_GIB"
  printf '| Next route | `%s` |\n' "$next_route"
} >> "$GITHUB_STEP_SUMMARY"

printf 'Hosted macOS feasibility probe completed: %s\n' "$next_route"
