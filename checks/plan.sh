#!/usr/bin/env bash
# Targets: bash 5.3 on ubuntu-26.04. Resolves the platforms a pull request's run of checks.yml
# checks its project on, from projects.json and platforms.json in <gate>, public-crates at the
# checks' own commit, never from the project's tree. Writes matrix to GITHUB_OUTPUT, and to the
# run's summary the checks' workflow and commit beside the project's.
#   plan.sh <gate>
# Reads, as checks.yml's plan job sets them: REPOSITORY, REPOSITORY_ID and SHA (the run's own),
# WORKFLOW_REF, WORKFLOW_SHA, GITHUB_OUTPUT and GITHUB_STEP_SUMMARY. Exits 1 on a run it refuses,
# 2 on a bad invocation.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

refuse() {
  printf 'plan: %s\n' "$1" >&2
  printf 'plan: %s\n' "$1" >>"${GITHUB_STEP_SUMMARY:?}"
  exit 1
}

main() {
  local gate=${1:-} repository=${REPOSITORY:-} entries count matrix platforms
  [[ -n "${gate}" && -f "${gate}/projects.json" && -f "${gate}/platforms.json" ]] || {
    printf 'usage: plan.sh <gate>, a checkout of public-crates holding projects.json and platforms.json\n' >&2
    exit 2
  }
  : "${REPOSITORY:?}" "${REPOSITORY_ID:?}" "${SHA:?}"
  : "${WORKFLOW_REF:?}" "${WORKFLOW_SHA:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"

  [[ "${WORKFLOW_REF}" == shuwariafrica/public-crates/.github/workflows/* ]] ||
    refuse "these checks run from public-crates' workflows alone, and this run's is ${WORKFLOW_REF}"
  [[ "${WORKFLOW_SHA}" =~ ^[0-9a-f]{40}$ ]] || refuse "the checks' commit is not a full commit: ${WORKFLOW_SHA}"

  entries=$(jq -c --arg repository "${repository}" \
    '[.projects | to_entries[] | select(.value.repository == $repository)]' "${gate}/projects.json")
  count=$(jq 'length' <<<"${entries}")
  [[ "${count}" == 1 ]] || refuse "${repository} is not one project of projects.json at ${WORKFLOW_SHA} (${count} match)"
  jq -e --arg repository "${repository}" '.[0].key == ($repository | split("/") | .[1])' <<<"${entries}" >/dev/null ||
    refuse "projects.json keys ${repository} by another name than its own"
  jq -e '.[0].value.repository_id != null' <<<"${entries}" >/dev/null ||
    refuse "projects.json's repository_id for ${repository} is null: it is set once the repository exists"
  jq -e --argjson id "${REPOSITORY_ID}" '.[0].value.repository_id == $id' <<<"${entries}" >/dev/null ||
    refuse "${repository} is repository ${REPOSITORY_ID}, which projects.json does not name"

  matrix=$(jq -c --slurpfile platforms "${gate}/platforms.json" \
    '[.[0].value.platforms[] as $p | {platform: $p, runner: ($platforms[0][$p].runner // error("platforms.json has no platform \($p)"))}]' \
    <<<"${entries}") || refuse "${repository} names a platform platforms.json does not hold"
  platforms=$(jq -r '[.[].platform] | join(", ")' <<<"${matrix}")

  printf 'matrix=%s\n' "${matrix}" >>"${GITHUB_OUTPUT}"
  {
    printf 'checks: %s at %s\n\n' "${WORKFLOW_REF}" "${WORKFLOW_SHA}"
    printf 'project: %s at %s, on %s\n' "${repository}" "${SHA}" "${platforms}"
  } >>"${GITHUB_STEP_SUMMARY}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
