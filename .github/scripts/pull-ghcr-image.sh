#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 IMAGE" >&2
  exit 64
fi

image="$1"
max_attempts=3
attempt=1

while (( attempt <= max_attempts )); do
  pull_log="${RUNNER_TEMP:?RUNNER_TEMP must be set}/ghcr-pull-attempt-${attempt}.log"

  set +e
  docker pull "$image" 2>&1 | tee "$pull_log"
  pull_pipeline_status=("${PIPESTATUS[@]}")
  set -e

  docker_status="${pull_pipeline_status[0]}"
  tee_status="${pull_pipeline_status[1]}"
  if [[ "$tee_status" != 0 ]]; then
    echo "Failed to capture the docker pull log (tee status $tee_status)." >&2
    exit "$tee_status"
  fi
  if [[ "$docker_status" == 0 ]]; then
    exit 0
  fi
  if ! grep -Fqi "secondary rate limit" "$pull_log"; then
    exit "$docker_status"
  fi
  if (( attempt == max_attempts )); then
    echo "GHCR secondary rate limit persisted for $max_attempts attempts." >&2
    exit "$docker_status"
  fi

  wait_seconds=$((60 * (2 ** (attempt - 1))))
  echo "::warning::GHCR secondary rate limit while pulling $image; retrying in ${wait_seconds}s."
  sleep "$wait_seconds"
  attempt=$((attempt + 1))
done

exit 1
