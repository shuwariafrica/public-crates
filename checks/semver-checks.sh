#!/usr/bin/env bash
# Targets: bash 5.3 on ubuntu-26.04 and Git Bash on windows-2025-vs2026, run in a project's
# workspace. Runs `cargo semver-checks` over the workspace's publishable crates that crates.io
# holds a version of, the baseline it compares against, and names in the run's summary each crate
# it skips for having none. Needs cargo, jq and curl. Exits with cargo semver-checks' status, 1 when
# crates.io's index cannot be read.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

# The crate's file in crates.io's sparse index (cargo's registry index format).
index_path() {
  local name=${1,,}
  case ${#name} in
    1) printf '1/%s\n' "${name}" ;;
    2) printf '2/%s\n' "${name}" ;;
    3) printf '3/%s/%s\n' "${name:0:1}" "${name}" ;;
    *) printf '%s/%s/%s\n' "${name:0:2}" "${name:2:2}" "${name}" ;;
  esac
}

# Prints `published` or `unpublished`; any answer but 200 or 404 is an index not read.
on_crates_io() {
  local path status
  path=$(index_path "$1")
  status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "https://index.crates.io/${path}")
  case ${status} in
    200) printf 'published\n' ;;
    404) printf 'unpublished\n' ;;
    *)
      printf 'semver-checks: crates.io index answered %s for %s\n' "${status}" "$1" >&2
      return 1
      ;;
  esac
}

main() {
  local summary=${GITHUB_STEP_SUMMARY:-/dev/null} metadata names name state
  local -a crates=() args=()
  metadata=$(cargo metadata --no-deps --locked --format-version 1)
  # -b: a Windows jq ends each line with CRLF otherwise, and the CR stays in the value it reads.
  names=$(jq -b -r '.workspace_members as $members | .packages[]
    | select(.id as $id | $members | index($id))
    | select(.publish == null or (.publish | index("crates-io")))
    | .name' <<<"${metadata}")
  [[ -z "${names}" ]] || mapfile -t crates <<<"${names}"
  for name in "${crates[@]}"; do
    state=$(on_crates_io "${name}")
    if [[ "${state}" == published ]]; then
      args+=(--package "${name}")
    else
      printf 'cargo semver-checks: %s skipped, no version of it on crates.io\n' "${name}" | tee -a "${summary}"
    fi
  done
  if ((${#args[@]} == 0)); then
    printf 'cargo semver-checks: no crate of the workspace has a version on crates.io to compare with\n' | tee -a "${summary}"
    return 0
  fi
  printf '+ cargo semver-checks %s\n' "${args[*]}"
  cargo semver-checks "${args[@]}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
