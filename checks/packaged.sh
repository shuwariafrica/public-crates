#!/usr/bin/env bash
# Targets: bash 5.3 on ubuntu-26.04 and Git Bash on windows-2025-vs2026, run in a project's
# workspace with rustup, cargo and tar. A release's verify: builds each `.crate` in <packaged>
# (crate-package's files, named in its `order`) unpacked, as cargo's own verification of a package
# does, every other crate of the release standing in for its crates.io release by a patch to its
# unpacked copy. The toolchain is the workspace's, resolved here, since cargo runs outside it.
#   packaged.sh <packaged>
# Exits 0 when every crate builds, 1 when one does not, 2 on a bad invocation.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

# The one directory or file <pattern> matches in <directory>, printed; fails on none or several.
one() {
  local directory=$1 pattern=$2 found
  found=$(find "${directory}" -mindepth 1 -maxdepth 1 -name "${pattern}" -print)
  [[ -n "${found}" && "${found}" != *$'\n'* ]] || {
    printf 'packaged: not one %s in %s\n' "${pattern}" "${directory}" >&2
    return 1
  }
  printf '%s\n' "${found}"
}

main() {
  local packaged=${1:-} work toolchain name crate unpacked other active
  local -a names patches
  [[ -n "${packaged}" && -f "${packaged}/order" ]] || {
    printf 'usage: packaged.sh <packaged>, a directory holding crate-package'"'"'s order\n' >&2
    exit 2
  }
  active=$(rustup show active-toolchain)
  toolchain=${active%% *}
  work=$(mktemp -d)
  trap '((BASHPID == '"${BASHPID}"')) && rm -rf -- "'"${work}"'"' EXIT
  mapfile -t names <"${packaged}/order"
  for name in "${names[@]}"; do
    crate=$(one "${packaged}" "${name}-[0-9]*.crate")
    tar -xzf "${crate}" -C "${work}"
  done
  for name in "${names[@]}"; do
    patches=()
    for other in "${names[@]}"; do
      [[ "${other}" != "${name}" ]] || continue
      unpacked=$(one "${work}" "${other}-[0-9]*")
      patches+=(--config "patch.crates-io.${other}.path=\"${unpacked}\"")
    done
    unpacked=$(one "${work}" "${name}-[0-9]*")
    printf '+ cargo build, %s unpacked, on %s\n' "${unpacked##*/}" "${toolchain}"
    (cd -- "${work}" && RUSTUP_TOOLCHAIN=${toolchain} CARGO_TARGET_DIR=${work}/target \
      cargo build --manifest-path "${unpacked}/Cargo.toml" "${patches[@]}")
  done
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
