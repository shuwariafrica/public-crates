#!/usr/bin/env bash
# Targets: bash 5.3 on ubuntu-26.04 and Git Bash on windows-2025-vs2026, run in a project's
# workspace with cargo and jq. Fails unless every crate of the workspace carries one licence, by
# its manifest's `license`, that licence is Apache-2.0 or MPL-2.0 and, where given, the one
# projects.json names, and the workspace root's LICENSE holds that licence's text. Prints each
# fault; exits 1 on any.
#   own-licence.sh [<licence projects.json names>]
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

# A line of each admitted licence's own text that no other licence's text holds; nothing for any
# other licence.
heading() {
  case $1 in
    Apache-2.0) printf 'Version 2.0, January 2004\n' ;;
    MPL-2.0) printf 'Mozilla Public License Version 2.0\n' ;;
    *) ;;
  esac
}

main() {
  local expected=${1:-} metadata licences distinct root licence text
  metadata=$(cargo metadata --no-deps --format-version 1)
  # -b: a Windows jq ends each line with CRLF otherwise, and the CR stays in the value it reads.
  root=$(jq -b -r '.workspace_root' <<<"${metadata}")
  licences=$(jq -b -r '.workspace_members as $members | [.packages[] | select(.id as $id | $members | index($id))
    | "\(.name)\t\(.license // "none")"] | .[]' <<<"${metadata}")
  distinct=$(cut -f2 <<<"${licences}" | sort -u | wc -l)
  if [[ "${distinct}" != 1 ]]; then
    printf 'own-licence: the workspace'"'"'s crates carry more than one licence:\n%s\n' "${licences}" >&2
    return 1
  fi
  licence=$(head -n 1 <<<"${licences}" | cut -f2)
  text=$(heading "${licence}")
  [[ -n "${text}" ]] || {
    printf 'own-licence: the crates are under %s; a public project is under Apache-2.0 or MPL-2.0\n' "${licence}" >&2
    return 1
  }
  [[ -z "${expected}" || "${licence}" == "${expected}" ]] || {
    printf 'own-licence: the crates are under %s; projects.json names %s\n' "${licence}" "${expected}" >&2
    return 1
  }
  [[ -f "${root}/LICENSE" ]] || {
    printf 'own-licence: the workspace root holds no LICENSE\n' >&2
    return 1
  }
  grep -q -F -- "${text}" "${root}/LICENSE" || {
    printf 'own-licence: LICENSE is not the text of %s, which the crates name\n' "${licence}" >&2
    return 1
  }
  printf 'own-licence: %s, its text in LICENSE\n' "${licence}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
