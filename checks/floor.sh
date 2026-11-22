#!/usr/bin/env bash
# Targets: bash 5.3 on ubuntu-26.04 and Git Bash on windows-2025-vs2026, run in a project's
# workspace with rustup, cargo and jq. Builds each publishable crate whose `rust-version` is below
# the release the workspace's toolchain names on the release it states: its library with default
# features, with all features and, where it declares defaults, with none. Such a crate with no
# library target fails unbuilt: a floor is built for a library alone. The builds run in a copy of
# the workspace under RUNNER_TEMP (or a temporary directory), with its own target directory and no
# Cargo.lock, so each release resolves afresh and the project's own lock stays as it is.
#   floor.sh
# Exits 0 when every build passes, 1 when one does not, 2 on a bad invocation.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

# Prints a rust-version as a release of three parts, absent parts 0, so "1.85" and "1.85.0" are
# one release: cargo reads "1.85" as 1.85.0, where rustup would install the latest 1.85.
release() {
  local -a parts
  IFS=. read -r -a parts <<<"$1"
  printf '%s.%s.%s\n' "${parts[0]}" "${parts[1]:-0}" "${parts[2]:-0}"
}

# Whether release <a> is below release <b>, each of three parts.
below() {
  local -a a b
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  ((a[0] < b[0] || (a[0] == b[0] && (a[1] < b[1] || (a[1] == b[1] && a[2] < b[2])))))
}

main() {
  local active toolchain channel metadata listed stated name defaults library floor sorted current="" base work copy entry features
  local status
  local -a builds=() flags failures=()
  [[ $# == 0 && -f Cargo.toml ]] || {
    printf 'usage: floor.sh, run in a workspace holding Cargo.toml\n' >&2
    exit 2
  }
  active=$(rustup show active-toolchain)
  toolchain=${active%% *}
  channel=${toolchain%%-*}
  [[ "${channel}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'floor: the toolchain %s is not one exact release; run after toolchain-file.py passes\n' "${toolchain}" >&2
    exit 2
  }
  metadata=$(cargo metadata --no-deps --format-version 1) || exit 2
  # -b: a Windows jq ends each line with CRLF otherwise, and the CR stays in the value it reads.
  listed=$(jq -b -r '.workspace_members as $members | .packages[]
    | select(.id as $id | $members | index($id)) | select(.publish != [] and .rust_version != null)
    | "\(.rust_version)\t\(.name)\t\(.features.default // [] | length > 0)\t\([.targets[].kind[]]
      | any(IN("lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro")))"' <<<"${metadata}")
  while IFS=$'\t' read -r stated name defaults library; do
    [[ -n "${stated}" ]] || continue
    floor=$(release "${stated}")
    # shellcheck disable=SC2310
    # below's status is its answer, and it runs nothing that can fail.
    if ! below "${floor}" "${channel}"; then
      continue
    elif [[ "${library}" == true ]]; then
      builds+=("${floor}"$'\t'"${name}"$'\t'"${defaults}")
    else
      failures+=("floor: ${name} states rust-version ${floor} and has no library target; a floor below the toolchain's release is built for a library alone, so ${name} states ${channel}")
    fi
  done <<<"${listed}"
  if ((${#builds[@]} == 0)); then
    if ((${#failures[@]} > 0)); then
      printf '%s\n' "${failures[@]}" >&2
      return 1
    fi
    printf 'floor: no publishable crate'"'"'s rust-version is below %s, the toolchain'"'"'s release; nothing to build\n' "${channel}"
    return 0
  fi
  sorted=$(printf '%s\n' "${builds[@]}" | sort -t $'\t' -k1,1V -k2,2)
  mapfile -t builds <<<"${sorted}"

  base=${RUNNER_TEMP:-}
  if [[ -n "${base}" ]]; then
    # A Windows runner names it in Windows' form (D:\a\_temp); the paths below are Git Bash's own.
    if command -v cygpath >/dev/null 2>&1; then
      base=$(cygpath -u "${base}")
    fi
    work=$(mktemp -d -p "${base}")
  else
    work=$(mktemp -d)
  fi
  trap '((BASHPID == '"${BASHPID}"')) && rm -rf -- "'"${work}"'"' EXIT
  copy=${work}/project
  mkdir -- "${copy}"
  shopt -s dotglob nullglob
  for entry in *; do
    # The project's own build output, which the copy's builds never read.
    [[ "${entry}" == target ]] || cp -R -- "${entry}" "${copy}/"
  done
  shopt -u dotglob nullglob

  for entry in "${builds[@]}"; do
    IFS=$'\t' read -r floor name defaults <<<"${entry}"
    if [[ "${floor}" != "${current}" ]]; then
      rustup toolchain install "${floor}" --profile minimal --no-self-update
      # The previous release's build wrote a lock, which an older cargo may not read and which
      # would hold this release to that resolution.
      rm -f -- "${copy}/Cargo.lock"
      current=${floor}
    fi
    if [[ "${defaults}" == true ]]; then
      printf '+ cargo +%s build --lib -p %s: default, all and no default features\n' "${floor}" "${name}"
    else
      printf '+ cargo +%s build --lib -p %s: default and all features; it declares no defaults\n' "${floor}" "${name}"
    fi
    for features in default all none; do
      case ${features} in
        default) flags=() ;;
        all) flags=(--all-features) ;;
        none)
          [[ "${defaults}" == true ]] || continue
          flags=(--no-default-features)
          ;;
        *) return 2 ;;
      esac
      status=0
      (cd -- "${copy}" && CARGO_TARGET_DIR=${work}/target cargo "+${floor}" build --lib -p "${name}" "${flags[@]}") || status=$?
      if ((status != 0)); then
        failures+=("floor: ${name} does not build on ${floor} with features: ${features}")
      fi
    done
  done
  if ((${#failures[@]} > 0)); then
    printf '%s\n' "${failures[@]}" >&2
    return 1
  fi
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
