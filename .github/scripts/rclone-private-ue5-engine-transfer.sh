#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo 'Usage: rclone-private-ue5-engine-transfer.sh <probe|upload|download> <source-dir|-> <stage> <transfer-key>' >&2
  exit 2
}

[[ "$#" == 4 ]] || usage
direction="$1"
source_dir="$2"
stage="$3"
transfer_key="$4"

[[ "$direction" == probe || "$direction" == upload || "$direction" == download ]] || usage
[[ "$stage" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || {
  echo 'The Engine checkpoint stage is unsafe.' >&2
  exit 1
}
[[ "$transfer_key" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || {
  echo 'The Engine checkpoint key is unsafe.' >&2
  exit 1
}

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${RCLONE_BIN:?RCLONE_BIN is required}"
: "${RCLONE_CONFIG_CONTENT:?RCLONE_CONFIG_CONTENT is required}"
: "${UE5_VERSION:?UE5_VERSION is required}"
: "${UE5_SOURCE_SHA:?UE5_SOURCE_SHA is required}"
: "${ENGINE_BOOTSTRAP_RECIPE_SHA256:?ENGINE_BOOTSTRAP_RECIPE_SHA256 is required}"
: "${EXPECTED_HOST_ARCH:?EXPECTED_HOST_ARCH is required}"
: "${EXPECTED_RUNNER_ARCH:?EXPECTED_RUNNER_ARCH is required}"
: "${EXPECTED_XCODE_VERSION:?EXPECTED_XCODE_VERSION is required}"
: "${EXPECTED_XCODE_BUILD:?EXPECTED_XCODE_BUILD is required}"
: "${EXPECTED_IPHONEOS_SDK:?EXPECTED_IPHONEOS_SDK is required}"

EXPECTED_MACOS_MAJOR="${EXPECTED_MACOS_MAJOR:-15}"
SETUP_EXCLUDES="${SETUP_EXCLUDES:-Android,Linux,LinuxArm64,Win32,Win64,HoloLens,TVOS}"
audit_file="$RUNNER_TEMP/ue5-macos-engine-checkpoint-transfer.txt"
config_dir="$(mktemp -d "$RUNNER_TEMP/rclone-ue5-engine.XXXXXX")"
config_file="$config_dir/rclone.conf"
transfer_log="$config_dir/transfer.log"
remote_listing="$config_dir/remote-listing.txt"
probe_error="$config_dir/probe-error.txt"
manifest_file="$config_dir/checkpoint.manifest.txt"
verify_manifest="$config_dir/checkpoint.manifest.verify.txt"
archive="$config_dir/ue5-source.tar.gz"
extract_dir="$config_dir/extract"
smoke_log="$config_dir/smoke.log"
remote_ready=false
uploaded_archive=false
uploaded_manifest=false
upload_complete=false

cleanup() {
  if test "$direction" = upload && test "$remote_ready" = true && test "$upload_complete" != true; then
    if test "$uploaded_manifest" = true; then
      "$RCLONE_BIN" deletefile "$manifest_remote" --config "$config_file" --retries 1 --low-level-retries 1 >/dev/null 2>&1 || true
    fi
    if test "$uploaded_archive" = true; then
      "$RCLONE_BIN" deletefile "$archive_remote" --config "$config_file" --retries 1 --low-level-retries 1 >/dev/null 2>&1 || true
    fi
  fi
  if [[ -f "$config_file" ]]; then
    shred --remove "$config_file" 2>/dev/null || rm -f "$config_file"
  fi
  rm -f "$transfer_log" "$remote_listing" "$probe_error" "$manifest_file" "$verify_manifest" "$archive" "$smoke_log"
  if [[ -d "$extract_dir" ]]; then
    rm -rf -- "$extract_dir"
  fi
  rmdir "$config_dir" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  {
    echo 'RCLONE_PRIVATE_UE5_ENGINE_TRANSFER_FAILED'
    printf 'direction=%s\n' "$direction"
    printf 'stage=%s\n' "$stage"
    printf 'transfer_key=%s\n' "$transfer_key"
    printf 'error=%s\n' "$*"
  } > "$audit_file"
  echo "::error::$*"
  exit 1
}

manifest_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '$1 == key { print substr($0, length($1) + 2); exit }' "$file"
}

require_manifest_field() {
  local key="$1"
  local file="$2"
  local count
  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$file")"
  test "$count" = 1 || fail "The Engine checkpoint manifest must contain exactly one ${key} field."
}

validate_current_host() {
  test "$(uname -s)" = Darwin || fail 'The UE Engine checkpoint requires Darwin.'
  test "$(uname -m)" = "$EXPECTED_HOST_ARCH" || fail 'The UE Engine checkpoint requires the expected Intel host architecture.'
  if [[ -n "${RUNNER_ARCH:-}" ]]; then
    test "$RUNNER_ARCH" = "$EXPECTED_RUNNER_ARCH" || fail 'The GitHub runner architecture does not match the Engine checkpoint.'
  fi
  test "$(sw_vers -productVersion | awk -F. '{ print $1 }')" = "$EXPECTED_MACOS_MAJOR" ||
    fail 'The macOS major version does not match the Engine checkpoint.'
  test "$(xcodebuild -version | awk 'NR == 1 { print $2 }')" = "$EXPECTED_XCODE_VERSION" ||
    fail 'The Xcode version does not match the Engine checkpoint.'
  test "$(xcodebuild -version | awk 'NR == 2 { print $3 }')" = "$EXPECTED_XCODE_BUILD" ||
    fail 'The Xcode build does not match the Engine checkpoint.'
  test "$(xcrun --sdk iphoneos --show-sdk-version)" = "$EXPECTED_IPHONEOS_SDK" ||
    fail 'The iPhoneOS SDK does not match the Engine checkpoint.'
  current_clang_version_sha256="$(xcrun --sdk macosx clang --version | sed -n '1p' | shasum -a 256 | awk '{ print $1 }')"
}

validate_symlinks() {
  local root="$1"
  python3 - "$root" <<'PY'
import os
import sys

root = os.path.realpath(sys.argv[1])
for directory, directory_names, file_names in os.walk(root, followlinks=False):
    for name in directory_names + file_names:
        path = os.path.join(directory, name)
        if not os.path.islink(path):
            continue
        target = os.readlink(path)
        if os.path.isabs(target):
            raise SystemExit(f"absolute symlink is not allowed: {path}")
        resolved = os.path.realpath(path)
        if resolved != root and not resolved.startswith(root + os.sep):
            raise SystemExit(f"escaping symlink is not allowed: {path}")
PY
}

scan_archive() {
  local archive_path="$1"
  python3 - "$archive_path" <<'PY'
import pathlib
import posixpath
import sys
import tarfile

archive = sys.argv[1]
count = 0
with tarfile.open(archive, mode="r:gz") as stream:
    for member in stream:
        count += 1
        name = member.name.rstrip("/")
        parts = pathlib.PurePosixPath(name).parts
        if not parts or parts[0] != "ue5-source" or name.startswith("/") or ".." in parts:
            raise SystemExit(f"unsafe archive path: {member.name}")
        if member.issym() or member.islnk():
            target = member.linkname
            if not target or target.startswith("/"):
                raise SystemExit(f"unsafe archive link: {member.name}")
            if target == "ue5-source" or target.startswith("ue5-source/"):
                resolved = posixpath.normpath(target)
            else:
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            if resolved != "ue5-source" and not resolved.startswith("ue5-source/"):
                raise SystemExit(f"escaping archive link: {member.name}")
print(count)
PY
}

validate_build_version() {
  local file="$1"
  jq --exit-status --arg version "$UE5_VERSION" '
    ($version | split(".") | map(tonumber)) as $expected |
    ($expected | length) == 3 and
    .MajorVersion == $expected[0] and
    .MinorVersion == $expected[1] and
    .PatchVersion == $expected[2]
  ' "$file" >/dev/null || fail "The restored Engine is not UE ${UE5_VERSION}."
}

validate_engine_tree() {
  local root="$1"
  local source_sha

  test -d "$root" || fail 'The prepared UE source root is missing.'
  test ! -L "$root" || fail 'The prepared UE source root must not be a symbolic link.'
  test -d "$root/.git" || fail 'The prepared UE source checkpoint is missing Git provenance.'
  build_version_file="$root/Engine/Build/Build.version"
  run_uat="$root/Engine/Build/BatchFiles/RunUAT.sh"
  build_sh="$root/Engine/Build/BatchFiles/Mac/Build.sh"
  editor_binary="$root/Engine/Binaries/Mac/UnrealEditor.app/Contents/MacOS/UnrealEditor"
  shader_worker="$root/Engine/Binaries/Mac/ShaderCompileWorker"
  test -f "$build_version_file" || fail 'The prepared Engine has no Build.version.'
  validate_build_version "$build_version_file"
  for executable in "$run_uat" "$build_sh" "$editor_binary" "$shader_worker"; do
    test -x "$executable" || fail 'The prepared Engine is missing a required executable.'
  done
  source_sha="$(git -C "$root" rev-parse HEAD)"
  test "$source_sha" = "$UE5_SOURCE_SHA" || fail 'The prepared Engine source SHA is unexpected.'
  test -z "$(git -C "$root" status --short --untracked-files=no)" ||
    fail 'The prepared Engine has tracked source modifications.'
  editor_arch="$(/usr/bin/lipo -archs "$editor_binary" 2>/dev/null)" ||
    fail 'The UnrealEditor architecture could not be inspected.'
  shader_worker_arch="$(/usr/bin/lipo -archs "$shader_worker" 2>/dev/null)" ||
    fail 'The ShaderCompileWorker architecture could not be inspected.'
  test "$editor_arch" = "$EXPECTED_HOST_ARCH" || fail 'The prepared UnrealEditor is not a native Intel binary.'
  test "$shader_worker_arch" = "$EXPECTED_HOST_ARCH" || fail 'The prepared ShaderCompileWorker is not a native Intel binary.'

  editor_bytes="$(stat -f '%z' "$editor_binary")"
  shader_worker_bytes="$(stat -f '%z' "$shader_worker")"
  editor_sha256="$(shasum -a 256 "$editor_binary" | awk '{ print $1 }')"
  shader_worker_sha256="$(shasum -a 256 "$shader_worker" | awk '{ print $1 }')"
  run_uat_sha256="$(shasum -a 256 "$run_uat" | awk '{ print $1 }')"
  build_sh_sha256="$(shasum -a 256 "$build_sh" | awk '{ print $1 }')"
  editor_mode="$(stat -f '%Lp' "$editor_binary")"
  shader_worker_mode="$(stat -f '%Lp' "$shader_worker")"
  run_uat_mode="$(stat -f '%Lp' "$run_uat")"
  build_sh_mode="$(stat -f '%Lp' "$build_sh")"
}

validate_manifest() {
  local file="$1"
  local required_fields
  required_fields='checkpoint_schema checkpoint_key ue5_version source_sha host_os macos_version macos_major host_arch runner_arch xcode_version xcode_build iphoneos_sdk setup_excludes bootstrap_recipe_sha256 archive_format archive_name archive_bytes archive_sha256 archive_entry_count regular_file_count symlink_count source_tree_mib source_root_name tracked_source_changes editor_arch editor_bytes editor_sha256 editor_mode shader_worker_arch shader_worker_bytes shader_worker_sha256 shader_worker_mode run_uat_sha256 run_uat_mode build_sh_sha256 build_sh_mode clang_version_sha256 producer_commit producer_run_id producer_run_attempt'
  for key in $required_fields; do
    require_manifest_field "$key" "$file"
  done

  grep -Fqx 'checkpoint_schema=zen-ue5-macos-engine-v1' "$file" || fail 'The Engine checkpoint schema is unsupported.'
  grep -Fqx "checkpoint_key=$transfer_key" "$file" || fail 'The Engine checkpoint key does not match its manifest.'
  grep -Fqx "ue5_version=$UE5_VERSION" "$file" || fail 'The Engine checkpoint UE version is unexpected.'
  grep -Fqx "source_sha=$UE5_SOURCE_SHA" "$file" || fail 'The Engine checkpoint source SHA is unexpected.'
  grep -Fqx 'host_os=Darwin' "$file" || fail 'The Engine checkpoint host OS is unexpected.'
  grep -Fqx "macos_major=$EXPECTED_MACOS_MAJOR" "$file" || fail 'The Engine checkpoint macOS major version is unexpected.'
  grep -Fqx "host_arch=$EXPECTED_HOST_ARCH" "$file" || fail 'The Engine checkpoint host architecture is unexpected.'
  grep -Fqx "runner_arch=$EXPECTED_RUNNER_ARCH" "$file" || fail 'The Engine checkpoint runner architecture is unexpected.'
  grep -Fqx "xcode_version=$EXPECTED_XCODE_VERSION" "$file" || fail 'The Engine checkpoint Xcode version is unexpected.'
  grep -Fqx "xcode_build=$EXPECTED_XCODE_BUILD" "$file" || fail 'The Engine checkpoint Xcode build is unexpected.'
  grep -Fqx "iphoneos_sdk=$EXPECTED_IPHONEOS_SDK" "$file" || fail 'The Engine checkpoint iPhoneOS SDK is unexpected.'
  grep -Fqx "setup_excludes=$SETUP_EXCLUDES" "$file" || fail 'The Engine checkpoint setup exclusions are unexpected.'
  grep -Fqx "bootstrap_recipe_sha256=$ENGINE_BOOTSTRAP_RECIPE_SHA256" "$file" || fail 'The Engine checkpoint bootstrap recipe is unexpected.'
  grep -Fqx 'archive_format=tar+gzip-v1' "$file" || fail 'The Engine checkpoint archive format is unsupported.'
  grep -Fqx 'archive_name=ue5-source.tar.gz' "$file" || fail 'The Engine checkpoint archive name is unexpected.'
  grep -Fqx 'source_root_name=ue5-source' "$file" || fail 'The Engine checkpoint source root is unexpected.'
  grep -Fqx 'tracked_source_changes=false' "$file" || fail 'The Engine checkpoint contains tracked source changes.'
  grep -Fqx "editor_arch=$EXPECTED_HOST_ARCH" "$file" || fail 'The Engine checkpoint editor architecture is unexpected.'
  grep -Fqx "shader_worker_arch=$EXPECTED_HOST_ARCH" "$file" || fail 'The Engine checkpoint ShaderCompileWorker architecture is unexpected.'
  grep -Fqx "clang_version_sha256=$current_clang_version_sha256" "$file" || fail 'The Engine checkpoint compiler identity is unexpected.'

  for numeric_key in archive_bytes archive_entry_count regular_file_count symlink_count source_tree_mib editor_bytes shader_worker_bytes producer_run_id producer_run_attempt; do
    [[ "$(manifest_value "$numeric_key" "$file")" =~ ^[0-9]+$ ]] || fail "The Engine checkpoint ${numeric_key} field is invalid."
  done
  for positive_key in archive_bytes archive_entry_count regular_file_count source_tree_mib editor_bytes shader_worker_bytes; do
    test "$(manifest_value "$positive_key" "$file")" -gt 0 || fail "The Engine checkpoint ${positive_key} field must be positive."
  done
  for hash_key in archive_sha256 editor_sha256 shader_worker_sha256 run_uat_sha256 build_sh_sha256 clang_version_sha256; do
    [[ "$(manifest_value "$hash_key" "$file")" =~ ^[0-9a-f]{64}$ ]] || fail "The Engine checkpoint ${hash_key} field is invalid."
  done
  for mode_key in editor_mode shader_worker_mode run_uat_mode build_sh_mode; do
    [[ "$(manifest_value "$mode_key" "$file")" =~ ^[0-7]{3,4}$ ]] || fail "The Engine checkpoint ${mode_key} field is invalid."
  done
  [[ "$(manifest_value macos_version "$file")" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail 'The Engine checkpoint macOS version is invalid.'
  [[ "$(manifest_value producer_commit "$file")" =~ ^[0-9a-f]{40}$ ]] || fail 'The Engine checkpoint producer commit is invalid.'
}

smoke_test_engine() {
  python3 - "$editor_binary" "$run_uat" "$smoke_log" <<'PY'
import subprocess
import sys

editor, run_uat, log_path = sys.argv[1:]
with open(log_path, "wb") as log:
    subprocess.run(
        [editor, "-version", "-unattended", "-nop4", "-nosplash", "-nullrhi"],
        stdout=log,
        stderr=subprocess.STDOUT,
        check=True,
        timeout=180,
    )
    subprocess.run(
        ["bash", run_uat, "-List"],
        stdout=log,
        stderr=subprocess.STDOUT,
        check=True,
        timeout=180,
    )
PY
}

write_audit() {
  local result="$1"
  local archive_bytes_value="${2:-0}"
  local archive_sha_value="${3:-not-applicable}"
  {
    echo 'RCLONE_PRIVATE_UE5_ENGINE_TRANSFER_SUCCESS'
    printf 'direction=%s\n' "$direction"
    printf 'result=%s\n' "$result"
    printf 'stage=%s\n' "$stage"
    printf 'transfer_key=%s\n' "$transfer_key"
    printf 'ue5_version=%s\n' "$UE5_VERSION"
    printf 'source_sha=%s\n' "$UE5_SOURCE_SHA"
    printf 'host_arch=%s\n' "$(uname -m)"
    printf 'xcode_version=%s\n' "$EXPECTED_XCODE_VERSION"
    printf 'xcode_build=%s\n' "$EXPECTED_XCODE_BUILD"
    printf 'iphoneos_sdk=%s\n' "$EXPECTED_IPHONEOS_SDK"
    printf 'archive_bytes=%s\n' "$archive_bytes_value"
    printf 'archive_sha256=%s\n' "$archive_sha_value"
    echo 'verification=immutable-private-readback'
    echo 'public_engine_artifact=disabled'
  } > "$audit_file"
}

command -v git >/dev/null || fail 'git is unavailable.'
command -v gzip >/dev/null || fail 'gzip is unavailable.'
command -v jq >/dev/null || fail 'jq is unavailable.'
command -v python3 >/dev/null || fail 'python3 is unavailable.'
command -v shasum >/dev/null || fail 'shasum is unavailable.'
command -v sw_vers >/dev/null || fail 'sw_vers is unavailable.'
command -v xcodebuild >/dev/null || fail 'xcodebuild is unavailable.'
command -v xcrun >/dev/null || fail 'xcrun is unavailable.'
test -x "$RCLONE_BIN" || fail 'RCLONE_BIN is not executable.'
test "$transfer_key" = "${ENGINE_CHECKPOINT_KEY:-}" || fail 'The requested Engine checkpoint key is not the generated content key.'
validate_current_host

umask 077
printf '%s' "$RCLONE_CONFIG_CONTENT" > "$config_file"
remote_count="$("$RCLONE_BIN" listremotes --config "$config_file" | awk 'NF { count++ } END { print count + 0 }')"
test "$remote_count" = 1 || fail "RCLONE_CONFIG must define exactly one remote; found ${remote_count}."
remote_name="$("$RCLONE_BIN" listremotes --config "$config_file" | awk 'NF { print; exit }')"
[[ "$remote_name" =~ ^[a-zA-Z0-9._-]+:$ ]] || fail 'The configured rclone remote name is invalid.'
remote_dir="${remote_name}ZEN/engine/v1/${stage}/${transfer_key}"
archive_remote="$remote_dir/ue5-source.tar.gz"
manifest_remote="$remote_dir/checkpoint.manifest.txt"
remote_ready=true
rclone_args=(
  --config "$config_file"
  --retries 3
  --low-level-retries 10
  --transfers 2
  --checkers 2
  --stats 30s
  --log-file "$transfer_log"
  --log-level INFO
)

remote_state=miss
set +e
"$RCLONE_BIN" lsf "$remote_dir" "${rclone_args[@]}" --files-only --max-depth 1 > "$remote_listing" 2> "$probe_error"
probe_status=$?
set -e
if test "$probe_status" != 0; then
  if grep -Eiq 'directory not found|object not found|file not found|path not found' "$probe_error" "$transfer_log" 2>/dev/null; then
    : > "$remote_listing"
  else
    fail 'The private Engine checkpoint namespace could not be inspected.'
  fi
fi
remote_file_count="$(awk 'NF { count++ } END { print count + 0 }' "$remote_listing")"
if test "$remote_file_count" != 0; then
  test "$remote_file_count" = 2 || fail 'The immutable Engine checkpoint namespace is partial or contains unexpected files.'
  grep -Fqx 'checkpoint.manifest.txt' "$remote_listing" || fail 'The immutable Engine checkpoint manifest is missing.'
  grep -Fqx 'ue5-source.tar.gz' "$remote_listing" || fail 'The immutable Engine checkpoint archive is missing.'
  "$RCLONE_BIN" copyto "$manifest_remote" "$manifest_file" "${rclone_args[@]}" ||
    fail 'The private Engine checkpoint manifest could not be downloaded.'
  validate_manifest "$manifest_file"
  remote_state=hit
fi

if test "$direction" = probe; then
  if test "$remote_state" = hit; then
    printf 'ENGINE_CHECKPOINT_HIT=true\n' >> "$GITHUB_ENV"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      printf 'hit=true\n' >> "$GITHUB_OUTPUT"
    fi
    write_audit hit "$(manifest_value archive_bytes "$manifest_file")" "$(manifest_value archive_sha256 "$manifest_file")"
    echo 'A matching immutable private UE Engine checkpoint already exists.'
  else
    printf 'ENGINE_CHECKPOINT_HIT=false\n' >> "$GITHUB_ENV"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      printf 'hit=false\n' >> "$GITHUB_OUTPUT"
    fi
    write_audit miss
    echo 'No matching immutable private UE Engine checkpoint exists; the seed workflow will build it once.'
  fi
  exit 0
fi

expected_source_dir="$GITHUB_WORKSPACE/ue5-source"
test "$source_dir" = "$expected_source_dir" || fail 'The Engine checkpoint source directory must use the stable workspace path.'

if test "$direction" = upload; then
  test "$remote_state" = miss || fail 'Refusing to overwrite an existing immutable Engine checkpoint.'
  validate_engine_tree "$source_dir"
  validate_symlinks "$source_dir" || fail 'The prepared Engine contains an unsafe symbolic link.'

  source_tree_mib="$(du -sk "$source_dir" | awk '{ print int(($1 + 1023) / 1024) }')"
  regular_file_count="$(find "$source_dir" -type f | awk 'END { print NR + 0 }')"
  symlink_count="$(find "$source_dir" -type l | awk 'END { print NR + 0 }')"
  source_entry_count="$(find "$source_dir" -mindepth 1 -print | awk 'END { print NR + 0 }')"
  archive_entry_count="$((source_entry_count + 1))"
  macos_version="$(sw_vers -productVersion)"
  clang_version_sha256="$current_clang_version_sha256"

  archive_parent="$(dirname "$source_dir")"
  archive_root="$(basename "$source_dir")"
  set +e
  COPYFILE_DISABLE=1 /usr/bin/tar -C "$archive_parent" -cf - "$archive_root" |
    /usr/bin/gzip -1 > "$archive"
  archive_pipeline_status=("${PIPESTATUS[@]}")
  set -e
  test "${archive_pipeline_status[0]}" = 0 || fail 'The prepared Engine tar stream failed.'
  test "${archive_pipeline_status[1]}" = 0 || fail 'The prepared Engine gzip stream failed.'
  /usr/bin/gzip -t "$archive" || fail 'The prepared Engine archive failed gzip validation.'
  archive_bytes="$(stat -f '%z' "$archive")"
  archive_sha256="$(shasum -a 256 "$archive" | awk '{ print $1 }')"

  {
    echo 'checkpoint_schema=zen-ue5-macos-engine-v1'
    printf 'checkpoint_key=%s\n' "$transfer_key"
    printf 'ue5_version=%s\n' "$UE5_VERSION"
    printf 'source_sha=%s\n' "$UE5_SOURCE_SHA"
    echo 'host_os=Darwin'
    printf 'macos_version=%s\n' "$macos_version"
    printf 'macos_major=%s\n' "$EXPECTED_MACOS_MAJOR"
    printf 'host_arch=%s\n' "$EXPECTED_HOST_ARCH"
    printf 'runner_arch=%s\n' "$EXPECTED_RUNNER_ARCH"
    printf 'xcode_version=%s\n' "$EXPECTED_XCODE_VERSION"
    printf 'xcode_build=%s\n' "$EXPECTED_XCODE_BUILD"
    printf 'iphoneos_sdk=%s\n' "$EXPECTED_IPHONEOS_SDK"
    printf 'setup_excludes=%s\n' "$SETUP_EXCLUDES"
    printf 'bootstrap_recipe_sha256=%s\n' "$ENGINE_BOOTSTRAP_RECIPE_SHA256"
    echo 'archive_format=tar+gzip-v1'
    echo 'archive_name=ue5-source.tar.gz'
    printf 'archive_bytes=%s\n' "$archive_bytes"
    printf 'archive_sha256=%s\n' "$archive_sha256"
    printf 'archive_entry_count=%s\n' "$archive_entry_count"
    printf 'regular_file_count=%s\n' "$regular_file_count"
    printf 'symlink_count=%s\n' "$symlink_count"
    printf 'source_tree_mib=%s\n' "$source_tree_mib"
    echo 'source_root_name=ue5-source'
    echo 'tracked_source_changes=false'
    printf 'editor_arch=%s\n' "$editor_arch"
    printf 'editor_bytes=%s\n' "$editor_bytes"
    printf 'editor_sha256=%s\n' "$editor_sha256"
    printf 'editor_mode=%s\n' "$editor_mode"
    printf 'shader_worker_arch=%s\n' "$shader_worker_arch"
    printf 'shader_worker_bytes=%s\n' "$shader_worker_bytes"
    printf 'shader_worker_sha256=%s\n' "$shader_worker_sha256"
    printf 'shader_worker_mode=%s\n' "$shader_worker_mode"
    printf 'run_uat_sha256=%s\n' "$run_uat_sha256"
    printf 'run_uat_mode=%s\n' "$run_uat_mode"
    printf 'build_sh_sha256=%s\n' "$build_sh_sha256"
    printf 'build_sh_mode=%s\n' "$build_sh_mode"
    printf 'clang_version_sha256=%s\n' "$clang_version_sha256"
    printf 'producer_commit=%s\n' "${GITHUB_SHA:-unknown}"
    printf 'producer_run_id=%s\n' "${GITHUB_RUN_ID:-0}"
    printf 'producer_run_attempt=%s\n' "${GITHUB_RUN_ATTEMPT:-0}"
  } > "$manifest_file"
  validate_manifest "$manifest_file"

  "$RCLONE_BIN" copyto "$archive" "$archive_remote" "${rclone_args[@]}" --immutable ||
    fail 'The private immutable Engine archive upload failed; the remote name is intentionally suppressed.'
  uploaded_archive=true
  remote_archive_sha256="$("$RCLONE_BIN" cat "$archive_remote" "${rclone_args[@]}" | shasum -a 256 | awk '{ print $1 }')" ||
    fail 'The uploaded Engine archive could not be read back.'
  test "$remote_archive_sha256" = "$archive_sha256" || fail 'The uploaded Engine archive failed byte-for-byte read-back verification.'
  "$RCLONE_BIN" copyto "$manifest_file" "$manifest_remote" "${rclone_args[@]}" --immutable ||
    fail 'The private immutable Engine manifest upload failed.'
  uploaded_manifest=true
  "$RCLONE_BIN" cat "$manifest_remote" "${rclone_args[@]}" > "$verify_manifest" ||
    fail 'The uploaded Engine manifest could not be read back.'
  cmp -s "$manifest_file" "$verify_manifest" || fail 'The uploaded Engine manifest failed byte-for-byte read-back verification.'
  upload_complete=true

  write_audit uploaded "$archive_bytes" "$archive_sha256"
  echo 'Uploaded and byte-verified the immutable private UE Engine checkpoint.'
else
  test "$remote_state" = hit || fail "The required private UE Engine checkpoint is missing. Run ue5-macos-source-bootstrap.yml with bootstrap_stage=build and publish_engine_checkpoint=true before starting the iOS producer. Expected key: ${transfer_key}"
  archive_bytes="$(manifest_value archive_bytes "$manifest_file")"
  archive_sha256="$(manifest_value archive_sha256 "$manifest_file")"
  "$RCLONE_BIN" copyto "$archive_remote" "$archive" "${rclone_args[@]}" ||
    fail 'The private Engine checkpoint archive could not be downloaded.'
  test "$(stat -f '%z' "$archive")" = "$archive_bytes" || fail 'The downloaded Engine archive byte count is unexpected.'
  test "$(shasum -a 256 "$archive" | awk '{ print $1 }')" = "$archive_sha256" || fail 'The downloaded Engine archive hash is unexpected.'
  /usr/bin/gzip -t "$archive" || fail 'The downloaded Engine archive failed gzip validation.'
  scanned_entry_count="$(scan_archive "$archive")" || fail 'The downloaded Engine archive contains an unsafe path or link.'
  test "$scanned_entry_count" = "$(manifest_value archive_entry_count "$manifest_file")" ||
    fail 'The downloaded Engine archive entry count is unexpected.'

  test ! -e "$source_dir" || fail 'The stable Engine restore destination already exists.'
  mkdir -p "$extract_dir"
  COPYFILE_DISABLE=1 /usr/bin/tar -C "$extract_dir" -xpzf "$archive" || fail 'The private Engine checkpoint could not be extracted.'
  restored_source="$extract_dir/ue5-source"
  test -d "$restored_source" || fail 'The Engine checkpoint did not contain the expected source root.'
  validate_symlinks "$restored_source" || fail 'The restored Engine contains an unsafe symbolic link.'
  restored_entry_count="$(( $(find "$restored_source" -mindepth 1 -print | awk 'END { print NR + 0 }') + 1 ))"
  test "$restored_entry_count" = "$scanned_entry_count" || fail 'The restored Engine tree entry count is unexpected.'
  test "$(find "$restored_source" -type f | awk 'END { print NR + 0 }')" = "$(manifest_value regular_file_count "$manifest_file")" ||
    fail 'The restored Engine regular file count is unexpected.'
  test "$(find "$restored_source" -type l | awk 'END { print NR + 0 }')" = "$(manifest_value symlink_count "$manifest_file")" ||
    fail 'The restored Engine symbolic link count is unexpected.'
  validate_engine_tree "$restored_source"
  test "$editor_bytes" = "$(manifest_value editor_bytes "$manifest_file")" || fail 'The restored UnrealEditor byte count is unexpected.'
  test "$shader_worker_bytes" = "$(manifest_value shader_worker_bytes "$manifest_file")" || fail 'The restored ShaderCompileWorker byte count is unexpected.'
  test "$editor_sha256" = "$(manifest_value editor_sha256 "$manifest_file")" || fail 'The restored UnrealEditor hash is unexpected.'
  test "$shader_worker_sha256" = "$(manifest_value shader_worker_sha256 "$manifest_file")" || fail 'The restored ShaderCompileWorker hash is unexpected.'
  test "$run_uat_sha256" = "$(manifest_value run_uat_sha256 "$manifest_file")" || fail 'The restored RunUAT hash is unexpected.'
  test "$build_sh_sha256" = "$(manifest_value build_sh_sha256 "$manifest_file")" || fail 'The restored Build.sh hash is unexpected.'
  test "$editor_mode" = "$(manifest_value editor_mode "$manifest_file")" || fail 'The restored UnrealEditor executable mode is unexpected.'
  test "$shader_worker_mode" = "$(manifest_value shader_worker_mode "$manifest_file")" || fail 'The restored ShaderCompileWorker executable mode is unexpected.'
  test "$run_uat_mode" = "$(manifest_value run_uat_mode "$manifest_file")" || fail 'The restored RunUAT executable mode is unexpected.'
  test "$build_sh_mode" = "$(manifest_value build_sh_mode "$manifest_file")" || fail 'The restored Build.sh executable mode is unexpected.'
  smoke_test_engine || fail 'The restored UnrealEditor or RunUAT smoke test failed.'

  mkdir -p "$(dirname "$source_dir")"
  mv "$restored_source" "$source_dir"
  write_audit restored "$archive_bytes" "$archive_sha256"
  echo 'Restored and smoke-tested the immutable private UE Engine checkpoint.'
fi

{
  echo
  echo '## Private UE 5.5.4 Engine checkpoint'
  echo
  echo '| Check | Result |'
  echo '| --- | --- |'
  printf '| Direction / key | `%s` / `%s` |\n' "$direction" "$transfer_key"
  printf '| UE source | `%s` at `%s` |\n' "$UE5_VERSION" "$UE5_SOURCE_SHA"
  printf '| Host / Xcode / iPhoneOS SDK | `%s` / `%s (%s)` / `%s` |\n' \
    "$EXPECTED_HOST_ARCH" "$EXPECTED_XCODE_VERSION" "$EXPECTED_XCODE_BUILD" "$EXPECTED_IPHONEOS_SDK"
  echo '| Artifact | `complete prepared Engine source tree; private immutable rclone checkpoint` |'
  echo '| Integrity | `archive SHA-256 plus byte-for-byte remote read-back` |'
  echo '| Public Engine artifact | `disabled` |'
} >> "$GITHUB_STEP_SUMMARY"
