#!/usr/bin/env bash
# Targets: bash 5.3 on ubuntu-26.04 and Git Bash on windows-2025-vs2026, run in a project's
# workspace. Runs `cargo package --workspace --locked`, unless the project's `git_sources` in
# <projects.json> lists any source: a packaged crate resolves its dependencies from crates.io alone,
# where the release a listed source awaits is not yet, and no such project is published before it
# is. The skip names each awaited crate and version in the run's summary. Needs cargo and jq.
#   package.sh <projects.json> <repository, owner/name>
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

main() {
  local projects=${1:-} repository=${2:-} summary=${GITHUB_STEP_SUMMARY:-/dev/null} awaited
  [[ -f "${projects}" && -n "${repository}" ]] || {
    printf 'usage: package.sh <projects.json> <repository>\n' >&2
    exit 2
  }
  awaited=$(jq -r --arg repository "${repository}" \
    '[.projects[] | select(.repository == $repository) | .git_sources // [] | .[] | "\(.awaits.crate) \(.awaits.version)"] | join(", ")' \
    "${projects}")
  if [[ -n "${awaited}" ]]; then
    printf 'cargo package: skipped, the project takes git sources awaiting %s on crates.io\n' "${awaited}" | tee -a "${summary}"
    return 0
  fi
  printf '+ cargo package --workspace --locked\n'
  cargo package --workspace --locked
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
