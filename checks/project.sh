#!/usr/bin/env bash
# Targets: bash 5.3 on ubuntu-26.04 and Git Bash on windows-2025-vs2026. The checks action's first
# step: holds the run to the project it checks, from projects.json and platforms.json in <gate>,
# public-crates at the action's own commit, never from the project's tree. REPOSITORY, the run's
# own, is one project of projects.json keyed by its own name, with the id REPOSITORY_ID; PLATFORM
# is one of its platforms, and the runner (RUNNER_OS, RUNNER_ARCH) is that platform's; the checkout
# <project> is at SHA, the run's commit. Writes repository and licence to GITHUB_OUTPUT.
#   project.sh <gate> <project checkout>
# Exits 1 on a run it refuses, 2 on a bad invocation.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

refuse() {
  printf 'project: %s\n' "$1" >&2
  printf 'project: %s\n' "$1" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1
}

main() {
  local gate=${1:-} project=${2:-} entries count runner want head
  [[ -n "${gate}" && -f "${gate}/projects.json" && -f "${gate}/platforms.json" && -d "${project}" ]] || {
    printf 'usage: project.sh <gate> <project checkout>\n' >&2
    exit 2
  }
  : "${REPOSITORY:?}" "${REPOSITORY_ID:?}" "${SHA:?}" "${PLATFORM:?}" "${RUNNER_OS:?}" "${RUNNER_ARCH:?}" "${GITHUB_OUTPUT:?}"

  entries=$(jq -c --arg repository "${REPOSITORY}" \
    '[.projects | to_entries[] | select(.value.repository == $repository)]' "${gate}/projects.json")
  count=$(jq 'length' <<<"${entries}")
  [[ "${count}" == 1 ]] || refuse "${REPOSITORY} is not one project of projects.json (${count} match)"
  jq -e --arg repository "${REPOSITORY}" '.[0].key == ($repository | split("/") | .[1])' <<<"${entries}" >/dev/null ||
    refuse "projects.json keys ${REPOSITORY} by another name than its own"
  jq -e '.[0].value.repository_id != null' <<<"${entries}" >/dev/null ||
    refuse "projects.json's repository_id for ${REPOSITORY} is null: it is set once the repository exists"
  jq -e --argjson id "${REPOSITORY_ID}" '.[0].value.repository_id == $id' <<<"${entries}" >/dev/null ||
    refuse "${REPOSITORY} is repository ${REPOSITORY_ID}, which projects.json does not name"
  jq -e --arg platform "${PLATFORM}" '.[0].value.platforms | index($platform) != null' <<<"${entries}" >/dev/null ||
    refuse "${PLATFORM} is not one of ${REPOSITORY}'s platforms"
  runner=$(jq -r --arg platform "${PLATFORM}" '.[$platform].runner // empty' "${gate}/platforms.json")
  [[ -n "${runner}" ]] || refuse "platforms.json has no platform ${PLATFORM}"
  # The platform's name is its system and architecture, as the runner names them.
  case ${PLATFORM} in
    linux-x64) want='Linux X64' ;;
    linux-arm64) want='Linux ARM64' ;;
    windows-x64) want='Windows X64' ;;
    windows-arm64) want='Windows ARM64' ;;
    *) refuse "no runner is known for the platform ${PLATFORM}" ;;
  esac
  [[ "${RUNNER_OS} ${RUNNER_ARCH}" == "${want}" ]] ||
    refuse "the platform ${PLATFORM} runs on ${want}, and this runner is ${RUNNER_OS} ${RUNNER_ARCH}"
  head=$(git -C "${project}" rev-parse HEAD)
  [[ "${head}" == "${SHA}" ]] || refuse "the checkout is at ${head}, and the run's commit is ${SHA}"

  {
    printf 'repository=%s\n' "${REPOSITORY}"
    jq -r '"licence=\(.[0].value.license)"' <<<"${entries}"
  } >>"${GITHUB_OUTPUT}"
  printf 'project: %s at %s, on %s (%s)\n' "${REPOSITORY}" "${SHA}" "${PLATFORM}" "${runner}" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
