#!/usr/bin/env bash
# Targets: bash 5.3 on ubuntu-26.04 and a developer's Linux machine, with git, jq, cargo and
# python3 3.11 or later; given `windows`, also Git Bash on windows-2025-vs2026 with git, jq and
# cargo, where it runs the cases of the scripts a Windows job runs, and those alone. The cases of
# plan.sh, project.sh, gate-configuration.py, toolchain-file.py, rust-version.py, git-sources.py,
# own-licence.sh, package.sh, packaged.sh, floor.sh and semver-checks.sh, each over a fixture built
# in a temporary directory, which it removes. Prints one line per case and exits 1 when any fails.
#   checks/test.sh [windows]
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH
[[ "${BASH_SOURCE@a}" == *a* ]] || {
  printf '%s: BASH_SOURCE is set by the environment\n' "$0" >&2
  exit 2
}

failed=0

# expect <name> <status> <text> <command...>: the command exits with <status> and its output holds
# <text>.
expect() {
  local name=$1 want=$2 text=$3 output status=0
  shift 3
  output=$("$@" 2>&1) || status=$?
  if [[ "${status}" == "${want}" && "${output}" == *"${text}"* ]]; then
    printf 'ok   %s\n' "${name}"
  else
    printf 'FAIL %s: exit %s, want %s holding %q\n%s\n' "${name}" "${status}" "${want}" "${text}" "${output}"
    failed=$((failed + 1))
  fi
}

# run_in <dir> <command...>: the command, run in <dir>.
run_in() {
  local dir=$1
  shift
  (cd -- "${dir}" && "$@")
}

repository() {
  local dir=$1
  git -C "${dir}" init -q -b main
  git -C "${dir}" add -A
  git -C "${dir}" commit -q --no-gpg-sign -m base
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q --no-gpg-sign --allow-empty -m change
}

# A pull request's change in <dir>: <edit> runs there on a fresh copy of the base.
gate_configuration_case() {
  local name=$1 want=$2 text=$3 edit=$4 dir
  dir=$(mktemp -d -p "${WORK}")
  cp -r "${WORK}/base/." "${dir}"
  (cd -- "${dir}" && eval "${edit}")
  commit_all "${dir}"
  expect "gate-configuration: ${name}" "${want}" "${text}" \
    run_in "${dir}" python3 -I "${GATE}/checks/gate-configuration.py" HEAD^1 HEAD
}

gate_configuration_cases() {
  mkdir -p "${WORK}/base/crates/a/.cargo" "${WORK}/base/crates/b" "${WORK}/base/crates/d"
  # The root's package and d state floors below the toolchain's release.
  printf '[package]\nname = "root"\nversion = "0.1.0"\nrust-version = "1.85.0"\n\n[workspace]\nmembers = ["crates/a", "crates/b", "crates/d"]\n\n[workspace.package]\nrust-version = "1.100.0"\n\n[workspace.lints.clippy]\nall = "deny"\n' >"${WORK}/base/Cargo.toml"
  printf '[package]\nname = "a"\nversion = "0.1.0"\nrust-version.workspace = true\n\n[lints]\nworkspace = true\n' >"${WORK}/base/crates/a/Cargo.toml"
  printf '[package]\nname = "b"\nversion = "0.1.0"\nrust-version = "1.100.0"\n' >"${WORK}/base/crates/b/Cargo.toml"
  printf '[package]\nname = "d"\nversion = "0.1.0"\nrust-version = "1.90"\n' >"${WORK}/base/crates/d/Cargo.toml"
  printf '[toolchain]\nchannel = "1.100.0"\ncomponents = ["rustfmt", "clippy"]\n' >"${WORK}/base/rust-toolchain.toml"
  printf 'pub fn a() {}\n' >"${WORK}/base/crates/a/lib.rs"
  printf '[bans]\nwildcards = "deny"\n' >"${WORK}/base/deny.toml"
  # The first project's root holds both: holding them passes, changing either fails.
  printf 'max_width = 100\n' >"${WORK}/base/rustfmt.toml"
  printf 'avoid-breaking-exported-api = false\n' >"${WORK}/base/clippy.toml"
  repository "${WORK}/base"

  gate_configuration_case "a source change beside rustfmt.toml and clippy.toml passes" 0 "leaves what the checks check" "printf '// x\n' >>crates/a/lib.rs"
  gate_configuration_case "a version change passes" 0 "leaves" "sed -i 's/0.1.0/0.2.0/' crates/a/Cargo.toml"
  local file
  for file in .cargo/config.toml .cargo/config crates/a/.cargo/config.toml deny.toml clippy.toml .clippy.toml \
    rustfmt.toml .rustfmt.toml crates/a/rustfmt.toml rust-toolchain.toml rust-toolchain; do
    gate_configuration_case "writing ${file} fails" 1 "- ${file}" "mkdir -p \"\$(dirname ${file})\" && printf 'x = 1\n' >${file}"
  done
  gate_configuration_case "a workspace lint change fails" 1 "- Cargo.toml: its [lints]" "sed -i 's/all = \"deny\"/all = \"warn\"/' Cargo.toml"
  gate_configuration_case "a member's lints change fails" 1 "- crates/a/Cargo.toml: its [lints]" "printf '[lints.rust]\nunused = \"allow\"\n' >>crates/a/Cargo.toml && sed -i '/^\[lints\]$/,/^workspace = true$/d' crates/a/Cargo.toml"
  gate_configuration_case "a new manifest with lints fails" 1 "- crates/b/Cargo.toml: its [lints]" "mkdir -p crates/b && printf '[package]\nname = \"b\"\n\n[lints]\nworkspace = true\n' >crates/b/Cargo.toml"
  gate_configuration_case "an unreadable manifest fails" 1 "- Cargo.toml: its [lints]" "printf '[[[' >>Cargo.toml"
  gate_configuration_case "renaming deny.toml away fails" 1 "- deny.toml" "git mv deny.toml deny.toml.bak"
  gate_configuration_case "turning formatting off fails" 1 "- rustfmt.toml" "printf 'disable_all_formatting = true\n' >>rustfmt.toml"
  gate_configuration_case "adding a workflow fails" 1 "- .github/workflows/ci.yml" "mkdir -p .github/workflows && printf 'name: ci\n' >.github/workflows/ci.yml"
  gate_configuration_case "a Dependabot change fails" 1 "- .github/dependabot.yml" "mkdir -p .github && printf 'version: 2\n' >.github/dependabot.yml"
  toolchain_raise_cases
  expect "gate-configuration: an unknown commit is a bad invocation" 2 "" \
    run_in "${WORK}/base" python3 -I "${GATE}/checks/gate-configuration.py" HEAD nonexistent
}

# The routine toolchain raise, and every other change to rust-toolchain.toml or a rust-version,
# each over the base above.
toolchain_raise_cases() {
  local raise="sed -i 's/1.100.0/1.101.0/' rust-toolchain.toml Cargo.toml crates/b/Cargo.toml"
  gate_configuration_case "a routine raise moving the crates on the old release, each floor below it left, passes" 0 \
    "leaves what the checks check" "${raise}"
  gate_configuration_case "a raise that moves a crate's floor fails" 1 "- crates/d/Cargo.toml: its rust-version, outside a routine toolchain raise" \
    "${raise} && sed -i 's/1.90/1.91/' crates/d/Cargo.toml"
  gate_configuration_case "a raise that moves the root package's floor beside the workspace's fails" 1 "- Cargo.toml: its rust-version, outside a routine toolchain raise" \
    "${raise} && sed -i 's/1.85.0/1.101.0/' Cargo.toml"
  gate_configuration_case "a raise to a lower release fails" 1 "- rust-toolchain.toml" "sed -i 's/1.100.0/1.99.1/' rust-toolchain.toml Cargo.toml crates/b/Cargo.toml"
  gate_configuration_case "an equal release fails" 1 "- rust-toolchain.toml" "printf '# the same release\n' >>rust-toolchain.toml"
  local channel
  for channel in stable beta nightly nightly-2026-11-01 1.101; do
    gate_configuration_case "a raise to ${channel} fails" 1 "- rust-toolchain.toml" "sed -i 's/\"1.100.0\"/\"${channel}\"/' rust-toolchain.toml"
  done
  gate_configuration_case "an added component fails" 1 "- rust-toolchain.toml" "${raise} && sed -i 's/\"clippy\"\]/\"clippy\", \"rust-src\"]/' rust-toolchain.toml"
  gate_configuration_case "a removed component fails" 1 "- rust-toolchain.toml" "${raise} && sed -i 's/, \"clippy\"//' rust-toolchain.toml"
  gate_configuration_case "a target fails" 1 "- rust-toolchain.toml" "${raise} && printf 'targets = [\"wasm32-unknown-unknown\"]\n' >>rust-toolchain.toml"
  gate_configuration_case "a profile fails" 1 "- rust-toolchain.toml" "${raise} && printf 'profile = \"complete\"\n' >>rust-toolchain.toml"
  gate_configuration_case "a path fails" 1 "- rust-toolchain.toml" "${raise} && printf 'path = \"tools/rust\"\n' >>rust-toolchain.toml"
  gate_configuration_case "a second table fails" 1 "- rust-toolchain.toml" "${raise} && printf '[other]\nx = 1\n' >>rust-toolchain.toml"
  gate_configuration_case "a raise with a crate left behind fails" 1 "- crates/b/Cargo.toml: its rust-version 1.100.0 is left behind" "sed -i 's/1.100.0/1.101.0/' rust-toolchain.toml Cargo.toml"
  gate_configuration_case "a raise with the workspace left behind fails" 1 "- Cargo.toml: its rust-version 1.100.0 is left behind" "sed -i 's/1.100.0/1.101.0/' rust-toolchain.toml crates/b/Cargo.toml"
  gate_configuration_case "a new crate on the toolchain's release passes" 0 "leaves what the checks check" "mkdir -p crates/c && printf '[package]\nname = \"c\"\nversion = \"0.1.0\"\nrust-version = \"1.100.0\"\n' >crates/c/Cargo.toml"
  gate_configuration_case "a rust-version change alone fails" 1 "- crates/b/Cargo.toml: its rust-version, outside a routine toolchain raise" "sed -i 's/1.100.0/1.101.0/' crates/b/Cargo.toml"
  gate_configuration_case "a floor changed outside a raise fails" 1 "- crates/d/Cargo.toml: its rust-version, outside a routine toolchain raise" "sed -i 's/1.90/1.89/' crates/d/Cargo.toml"
}

toolchain_case() {
  local name=$1 want=$2 text=$3 setup=$4 dir
  dir=$(mktemp -d -p "${WORK}")
  (cd -- "${dir}" && eval "${setup}")
  expect "toolchain-file: ${name}" "${want}" "${text}" python3 -I "${GATE}/checks/toolchain-file.py" "${dir}"
}

toolchain_cases() {
  local exact='printf "[toolchain]\nchannel = \"1.100.0\"\ncomponents = [\"rustfmt\", \"clippy\"]\n" >rust-toolchain.toml'
  toolchain_case "one exact release passes" 0 "one exact release" "${exact}"
  toolchain_case "the template's file passes" 0 "one exact release" "cp '${GATE}/template/rust-toolchain.toml' ."
  toolchain_case "a rust-toolchain file fails" 1 "rust-toolchain exists" "${exact} && printf '1.100.0\n' >rust-toolchain"
  toolchain_case "a nested rust-toolchain file fails" 1 "crates/a/rust-toolchain exists" "${exact} && mkdir -p crates/a && printf 'stable\n' >crates/a/rust-toolchain"
  toolchain_case "a path key fails" 1 "by path" "printf '[toolchain]\nchannel = \"1.100.0\"\npath = \"tools/rust\"\n' >rust-toolchain.toml"
  toolchain_case "a channel name fails" 1 "'stable', not one exact release" "printf '[toolchain]\nchannel = \"stable\"\n' >rust-toolchain.toml"
  toolchain_case "a minor version alone fails" 1 "'1.100', not one exact release" "printf '[toolchain]\nchannel = \"1.100\"\n' >rust-toolchain.toml"
  toolchain_case "a dated nightly fails" 1 "not one exact release" "printf '[toolchain]\nchannel = \"nightly-2026-11-01\"\n' >rust-toolchain.toml"
  toolchain_case "no channel fails" 1 "None, not one exact release" "printf '[toolchain]\ncomponents = [\"rustfmt\"]\n' >rust-toolchain.toml"
  toolchain_case "another table fails" 1 "more than one [toolchain] table" "${exact} && printf '[other]\nx = 1\n' >>rust-toolchain.toml"
  toolchain_case "no toolchain file fails" 1 "rust-toolchain.toml is absent" ":"
  toolchain_case "a nested file of another release fails" 1 "crates/a/rust-toolchain.toml names channel 'beta'" "${exact} && mkdir -p crates/a && printf '[toolchain]\nchannel = \"beta\"\n' >crates/a/rust-toolchain.toml"
}

# plan <projects.json> [VAR=value...]: plan.sh over a gate holding that projects.json, with the
# pull request's environment unless a pair overrides it.
plan() {
  local projects=$1 gate
  shift
  gate=$(mktemp -d -p "${WORK}")
  printf '%s\n' "${projects}" >"${gate}/projects.json"
  cp "${GATE}/platforms.json" "${gate}/"
  : >"${gate}/output"
  : >"${gate}/summary"
  env REPOSITORY=shuwariafrica/crate-a REPOSITORY_ID=1001 \
    SHA=1111111111111111111111111111111111111111 \
    WORKFLOW_REF=shuwariafrica/public-crates/.github/workflows/checks.yml@refs/heads/main \
    WORKFLOW_SHA=2222222222222222222222222222222222222222 \
    GITHUB_OUTPUT="${gate}/output" GITHUB_STEP_SUMMARY="${gate}/summary" "$@" \
    bash "${GATE}/checks/plan.sh" "${gate}" || return $?
  cat "${gate}/output" "${gate}/summary"
}

plan_cases() {
  local one
  one='{"projects": {"crate-a": {"repository": "shuwariafrica/crate-a", "repository_id": 1001, "crates": ["crate-a"],
    "crates_io_owners": ["arashi01"], "tag_signers": ["20BBB4E4F90F3CE6F9BBFCDB78A12350D373DF6B"], "first_version": "0.1.0",
    "platforms": ["linux-x64", "windows-x64"], "license": "MPL-2.0"}}}'
  expect "plan: a project's pull request takes its platforms" 0 \
    'matrix=[{"platform":"linux-x64","runner":"ubuntu-26.04"},{"platform":"windows-x64","runner":"windows-2025-vs2026"}]' plan "${one}"
  expect "plan: the summary names the checks' commit" 0 "checks: shuwariafrica/public-crates/.github/workflows/checks.yml@refs/heads/main at 2222222222222222222222222222222222222222" plan "${one}"
  expect "plan: the summary names the pull request's commit" 0 "project: shuwariafrica/crate-a at 1111111111111111111111111111111111111111" plan "${one}"
  expect "plan: a repository outside projects.json is refused" 1 "is not one project of projects.json" \
    plan "${one}" REPOSITORY=shuwariafrica/crate-b
  expect "plan: another repository's id is refused" 1 "is repository 77, which projects.json does not name" \
    plan "${one}" REPOSITORY_ID=77
  expect "plan: a workflow outside public-crates is refused" 1 "run from public-crates' workflows alone" \
    plan "${one}" WORKFLOW_REF=shuwariafrica/crate-a/.github/workflows/checks.yml@refs/heads/main
  expect "plan: a platform outside platforms.json is refused" 1 "names a platform platforms.json does not hold" \
    plan "${one/\"windows-x64\"/\"macos-arm64\"}"
  expect "plan: a project not yet made is refused" 1 "repository_id for shuwariafrica/crate-a is null" \
    plan "${one/\"repository_id\": 1001/\"repository_id\": null}"
  expect "plan: a project keyed by another name is refused" 1 "by another name than its own" \
    plan "${one/\"crate-a\": \{/\"other\": \{}"
}

# project <projects.json> [VAR=value...]: project.sh over a gate holding that projects.json and a
# checkout at 1111..., on a Linux x64 runner for linux-x64, unless a pair overrides it.
project() {
  local projects=$1 dir sha
  shift
  dir=$(mktemp -d -p "${WORK}")
  mkdir -p "${dir}/gate" "${dir}/project"
  printf '%s\n' "${projects}" >"${dir}/gate/projects.json"
  cp "${GATE}/platforms.json" "${dir}/gate/"
  printf 'a project\n' >"${dir}/project/README.md"
  repository "${dir}/project"
  sha=$(git -C "${dir}/project" rev-parse HEAD)
  : >"${dir}/output"
  env REPOSITORY=shuwariafrica/crate-a REPOSITORY_ID=1001 SHA="${sha}" PLATFORM=linux-x64 \
    RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_OUTPUT="${dir}/output" GITHUB_STEP_SUMMARY="${dir}/summary" "$@" \
    bash "${GATE}/checks/project.sh" "${dir}/gate" "${dir}/project" || return $?
  cat "${dir}/output"
}

project_cases() {
  local one
  one='{"projects": {"crate-a": {"repository": "shuwariafrica/crate-a", "repository_id": 1001, "crates": ["crate-a"],
    "crates_io_owners": ["arashi01"], "tag_signers": ["20BBB4E4F90F3CE6F9BBFCDB78A12350D373DF6B"], "signing_key": null,
    "first_version": "0.1.0", "platforms": ["linux-x64", "windows-x64"], "license": "MPL-2.0"}}}'
  expect "project: the project, its platform and runner pass, its licence to the steps" 0 "licence=MPL-2.0" project "${one}"
  expect "project: the repository goes to the steps" 0 "repository=shuwariafrica/crate-a" project "${one}"
  expect "project: windows-x64 on a Windows x64 runner passes" 0 "licence=MPL-2.0" \
    project "${one}" PLATFORM=windows-x64 RUNNER_OS=Windows
  expect "project: a repository outside projects.json is refused" 1 "is not one project of projects.json" \
    project "${one}" REPOSITORY=shuwariafrica/crate-b
  expect "project: another repository's id is refused" 1 "is repository 77, which projects.json does not name" \
    project "${one}" REPOSITORY_ID=77
  expect "project: a project not yet made is refused" 1 "repository_id for shuwariafrica/crate-a is null" \
    project "${one/\"repository_id\": 1001/\"repository_id\": null}"
  expect "project: a platform not the project's is refused" 1 "linux-arm64 is not one of shuwariafrica/crate-a's platforms" \
    project "${one}" PLATFORM=linux-arm64
  expect "project: a platform on another runner is refused" 1 "the platform windows-x64 runs on Windows X64, and this runner is Linux X64" \
    project "${one}" PLATFORM=windows-x64
  expect "project: a checkout at another commit is refused" 1 "and the run's commit is 3333333333333333333333333333333333333333" \
    project "${one}" SHA=3333333333333333333333333333333333333333
}

# packaged_case <name> <status> <text> <crates> [<failing crate>]: packaged.sh over a release of
# those crates at 0.1.0, rustup and cargo stubs recording what they are asked; cargo fails for
# <failing crate>.
packaged_case() {
  local name=$1 status=$2 text=$3 crates=$4 failing=${5:-} dir crate
  dir=$(mktemp -d -p "${WORK}")
  mkdir -p "${dir}/bin" "${dir}/project" "${dir}/packaged" "${dir}/source"
  printf '#!/usr/bin/env bash\nprintf "%%s (overridden by %s/project/rust-toolchain.toml)\\n" 1.99.1-x86_64-unknown-linux-gnu\n' "${dir}" >"${dir}/bin/rustup"
  # shellcheck disable=SC2016
  # The stub's own script, expanded when it runs.
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s\\n" "$PWD" "$RUSTUP_TOOLCHAIN" "$*" >>"%s/record"\n[[ "$*" != *"/%s-0.1.0/Cargo.toml"* || -z "%s" ]]\n' \
    "${dir}" "${failing}" "${failing}" >"${dir}/bin/cargo"
  chmod +x "${dir}/bin/rustup" "${dir}/bin/cargo"
  : >"${dir}/record"
  for crate in ${crates}; do
    mkdir -p "${dir}/source/${crate}-0.1.0"
    printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "${crate}" >"${dir}/source/${crate}-0.1.0/Cargo.toml"
    tar -czf "${dir}/packaged/${crate}-0.1.0.crate" -C "${dir}/source" "${crate}-0.1.0"
    printf '%s\n' "${crate}" >>"${dir}/packaged/order"
  done
  expect "packaged: ${name}" "${status}" "${text}" \
    run_in "${dir}/project" env PATH="${dir}/bin:${PATH}" bash "${GATE}/checks/packaged.sh" "${dir}/packaged"
  PACKAGED_RECORD=$(<"${dir}/record")
  PACKAGED_PROJECT=${dir}/project
}

packaged_cases() {
  local line
  packaged_case "each crate builds unpacked" 0 "+ cargo build, crate-b-0.1.0 unpacked, on 1.99.1-x86_64-unknown-linux-gnu" "crate-a crate-b"
  line=$(grep -F '/crate-a-0.1.0/Cargo.toml' <<<"${PACKAGED_RECORD}")
  expect "packaged: a crate builds on the workspace's toolchain" 0 "|1.99.1-x86_64-unknown-linux-gnu|build --manifest-path" printf '%s\n' "${line}"
  expect "packaged: a crate builds with the other patched in from its unpacked copy" 0 "--config patch.crates-io.crate-b.path=" printf '%s\n' "${line}"
  expect "packaged: a crate builds outside the workspace" 1 "" grep -qF "${PACKAGED_PROJECT}|" <<<"${PACKAGED_RECORD}"
  packaged_case "a crate that does not build fails" 1 "crate-b-0.1.0 unpacked" "crate-a crate-b" crate-b
  packaged_case "a directory with no order is a bad invocation" 2 "usage: packaged.sh" ""
}

# floor_case <name> <status> <text> <packages> [<failing build> [<active toolchain> [windows]]]:
# floor.sh in a project on 1.100.0, with its own Cargo.lock and target directory, whose cargo
# metadata lists <packages> (each a member unless it says `"member": false`, and a library unless it
# names its targets; "-" for a manifest cargo cannot read), over rustup and cargo stubs recording what they are asked and jq as a Windows
# job runs it. cargo writes a lock where it builds, as cargo does, and fails the build whose
# arguments are <failing build>. Given `windows`, RUNNER_TEMP is D:\a\_temp, as a Windows runner
# names it, and a cygpath stub recording its call converts it to the case's own directory.
floor_case() {
  local name=$1 want=$2 text=$3 packages=$4 failing=${5:-} active=${6:-1.100.0-x86_64-unknown-linux-gnu} windows=${7:-}
  local dir native tool temp found
  local -a tools=(rustup cargo)
  dir=$(mktemp -d -p "${WORK}")
  mkdir -p "${dir}/bin" "${dir}/project/target" "${dir}/temp"
  native=$(native_path "${dir}/native")
  printf '[workspace]\n' >"${dir}/project/Cargo.toml"
  printf 'the project'"'"'s own lock\n' >"${dir}/project/Cargo.lock"
  : >"${dir}/project/target/built"
  [[ "${packages}" == - ]] || jq -n --argjson packages "${packages}" \
    '{workspace_members: [$packages[] | select(.member != false) | .id],
      packages: [$packages[] | del(.member) | if has("targets") then . else .targets = [{name: .name, kind: ["lib"]}] end]}' \
    >"${dir}/metadata.json"
  cat >"${dir}/bin/rustup" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "show active-toolchain") printf '%s (overridden by %s/rust-toolchain.toml)\n' "${ACTIVE:?}" "${PWD}" ;;
  "toolchain install") printf 'rustup %s\n' "$*" >>"${RECORD:?}" ;;
  *) exit 2 ;;
esac
STUB
  cat >"${dir}/bin/cargo" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  metadata) cat -- "${METADATA:?}" ;;
  +*)
    lock=absent target=absent
    [[ ! -e Cargo.lock ]] || lock=present
    [[ ! -e target ]] || target=present
    printf 'cargo %s|%s|%s|lock %s|target %s\n' "$*" "${PWD}" "${CARGO_TARGET_DIR:-}" "${lock}" "${target}" >>"${RECORD:?}"
    printf 'resolved by %s\n' "$1" >Cargo.lock
    [[ "$*" != "${FAILING}" ]]
    ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "${dir}/bin/rustup" "${dir}/bin/cargo"
  temp=${dir}/temp
  if [[ "${windows}" == windows ]]; then
    temp='D:\a\_temp'
    tools+=(cygpath)
    cat >"${dir}/bin/cygpath" <<'STUB'
#!/usr/bin/env bash
printf 'cygpath %s\n' "$*" >>"${RECORD:?}"
[[ "$1" == -u ]] || exit 1
if [[ "$2" == 'D:\a\_temp' ]]; then
  printf '%s\n' "${CONVERTED:?}"
else
  printf '%s\n' "$2"
fi
STUB
    chmod +x "${dir}/bin/cygpath"
  fi
  for tool in "${tools[@]}"; do
    found=$(PATH="${dir}/bin:${native}" type -P "${tool}")
    [[ "${found}" == "${dir}/bin/${tool}" ]]
  done
  : >"${dir}/record"
  expect "floor: ${name}" "${want}" "${text}" \
    run_in "${dir}/project" env PATH="${dir}/bin:${native}" RECORD="${dir}/record" METADATA="${dir}/metadata.json" \
    ACTIVE="${active}" FAILING="${failing}" RUNNER_TEMP="${temp}" CONVERTED="${dir}/temp" bash "${GATE}/checks/floor.sh"
  FLOOR_RECORD=$(<"${dir}/record")
  FLOOR_DIR=${dir}
  FLOOR_PATH=${dir}/bin:${native}
}

# equal <want> <got>: fails, printing <got>, unless the two are equal.
equal() {
  [[ "$1" == "$2" ]] || {
    printf 'got:\n%s\n' "$2"
    return 1
  }
}

# builds_hold <text>: fails, printing the line, unless every build floor_case recorded holds <text>.
builds_hold() {
  local line
  while IFS= read -r line; do
    [[ "${line}" != cargo* || "${line}" == *"$1"* ]] || {
      printf '%s\n' "${line}"
      return 1
    }
  done <<<"${FLOOR_RECORD}"
}

floor_cases() {
  local one want got copy lock left count features flags name
  floor_case "no crate below the toolchain's release passes, saying so" 0 \
    "floor: no publishable crate's rust-version is below 1.100.0, the toolchain's release; nothing to build" \
    '[{"id": "a", "name": "a", "rust_version": "1.100.0", "features": {"default": ["std"], "std": []}, "publish": null},
      {"id": "b", "name": "b", "rust_version": "1.100", "features": {}, "publish": null}]'
  expect "floor: no crate below the toolchain's release installs and builds nothing" 0 "" equal "" "${FLOOR_RECORD}"

  # a and b at one floor, written two ways; c on the toolchain's release, d unpublished, e stating
  # none, f above the release and g outside the workspace, none of them built.
  one='[{"id": "a", "name": "a", "rust_version": "1.85.0", "features": {"default": ["std"], "std": []}, "publish": null},
    {"id": "b", "name": "b", "rust_version": "1.85", "features": {"default": []}, "publish": ["crates-io"]},
    {"id": "c", "name": "c", "rust_version": "1.100.0", "features": {"default": ["std"], "std": []}, "publish": null},
    {"id": "d", "name": "d", "rust_version": "1.80.0", "features": {"default": ["std"], "std": []}, "publish": []},
    {"id": "e", "name": "e", "rust_version": null, "features": {}, "publish": null},
    {"id": "f", "name": "f", "rust_version": "1.101.0", "features": {}, "publish": null},
    {"id": "g", "name": "g", "rust_version": "1.70.0", "features": {}, "publish": null, "member": false}]'
  floor_case "a floor's crates build on it" 0 "+ cargo +1.85.0 build --lib -p a: default, all and no default features" "${one}"
  want='rustup toolchain install 1.85.0 --profile minimal --no-self-update
cargo +1.85.0 build --lib -p a|lock absent
cargo +1.85.0 build --lib -p a --all-features|lock present
cargo +1.85.0 build --lib -p a --no-default-features|lock present
cargo +1.85.0 build --lib -p b|lock present
cargo +1.85.0 build --lib -p b --all-features|lock present'
  got=$(cut -d '|' -f 1,4 <<<"${FLOOR_RECORD}")
  expect "floor: the floor is installed once, each crate on it built with default and all features, with none where it declares defaults, the first build with no lock" 0 "" \
    equal "${want}" "${got}"
  copy=$(awk -F '|' '/^cargo /{print $2; exit}' <<<"${FLOOR_RECORD}")
  expect "floor: the builds run in a copy under RUNNER_TEMP" 0 "${FLOOR_DIR}/temp/" printf '%s\n' "${copy}"
  expect "floor: every build runs in that copy, with its own target directory" 0 "" builds_hold "|${copy}|${copy%/project}/target|"
  expect "floor: the copy leaves out the project's target directory" 0 "" builds_hold "|target absent"
  lock=$(<"${FLOOR_DIR}/project/Cargo.lock")
  expect "floor: the project's own lock is left as it was" 0 "" equal "the project's own lock" "${lock}"
  left=$(find "${FLOOR_DIR}/temp" -mindepth 1)
  expect "floor: the copy is removed" 0 "" equal "" "${left}"

  # Listed out of order, so a floor's crates are built together.
  floor_case "each floor's crates build on it" 0 "+ cargo +1.90.0 build --lib -p b: default and all features; it declares no defaults" \
    '[{"id": "a", "name": "a", "rust_version": "1.85.0", "features": {}, "publish": null},
      {"id": "b", "name": "b", "rust_version": "1.90.0", "features": {}, "publish": null},
      {"id": "c", "name": "c", "rust_version": "1.85.0", "features": {}, "publish": null}]'
  want='rustup toolchain install 1.85.0 --profile minimal --no-self-update
cargo +1.85.0 build --lib -p a|lock absent
cargo +1.85.0 build --lib -p a --all-features|lock present
cargo +1.85.0 build --lib -p c|lock present
cargo +1.85.0 build --lib -p c --all-features|lock present
rustup toolchain install 1.90.0 --profile minimal --no-self-update
cargo +1.90.0 build --lib -p b|lock absent
cargo +1.90.0 build --lib -p b --all-features|lock present'
  got=$(cut -d '|' -f 1,4 <<<"${FLOOR_RECORD}")
  expect "floor: each floor is installed once and resolves afresh, its crates built together" 0 "" equal "${want}" "${got}"

  # b has a program alone; each other crate a library of one kind.
  floor_case "a crate below the toolchain's release with no library target fails unbuilt" 1 \
    "floor: b states rust-version 1.85.0 and has no library target; a floor below the toolchain's release is built for a library alone, so b states 1.100.0" \
    '[{"id": "b", "name": "b", "rust_version": "1.85.0", "features": {}, "publish": null, "targets": [{"name": "b", "kind": ["bin"]}]},
      {"id": "l", "name": "l", "rust_version": "1.85.0", "features": {}, "publish": null,
        "targets": [{"name": "l", "kind": ["lib"]}, {"name": "e", "kind": ["example"]}, {"name": "build-script-build", "kind": ["custom-build"]}]},
      {"id": "r", "name": "r", "rust_version": "1.85.0", "features": {}, "publish": null, "targets": [{"name": "r", "kind": ["rlib"]}]},
      {"id": "d", "name": "d", "rust_version": "1.85.0", "features": {}, "publish": null, "targets": [{"name": "d", "kind": ["dylib"]}]},
      {"id": "c", "name": "c", "rust_version": "1.85.0", "features": {}, "publish": null, "targets": [{"name": "c", "kind": ["cdylib"]}]},
      {"id": "s", "name": "s", "rust_version": "1.85.0", "features": {}, "publish": null, "targets": [{"name": "s", "kind": ["staticlib"]}]},
      {"id": "p", "name": "p", "rust_version": "1.85.0", "features": {}, "publish": null, "targets": [{"name": "p", "kind": ["proc-macro"]}]}]'
  expect "floor: a crate with no library target is not built" 1 "" grep -q -- '-p b' <<<"${FLOOR_RECORD}"
  for name in c:cdylib d:dylib l:lib p:proc-macro r:rlib s:staticlib; do
    expect "floor: a crate whose library is a ${name#*:} builds beside it" 0 "" grep -q -- "build --lib -p ${name%%:*}|" <<<"${FLOOR_RECORD}"
  done
  floor_case "a crate with no library target fails though nothing else builds" 1 "floor: b states rust-version 1.85.0 and has no library target" \
    '[{"id": "b", "name": "b", "rust_version": "1.85.0", "features": {}, "publish": null, "targets": [{"name": "b", "kind": ["bin"]}]}]'
  expect "floor: nothing is installed or built for a program alone" 0 "" equal "" "${FLOOR_RECORD}"

  floor_case "a Windows runner's RUNNER_TEMP is converted to a POSIX path" 0 "+ cargo +1.85.0 build --lib -p a" "${one}" "" "" windows
  expect "floor: the Windows form goes to cygpath -u" 0 'cygpath -u D:\a\_temp' printf '%s\n' "${FLOOR_RECORD}"
  copy=$(awk -F '|' '/^cargo /{print $2; exit}' <<<"${FLOOR_RECORD}")
  expect "floor: the copy lands under the converted directory" 0 "${FLOOR_DIR}/temp/" printf '%s\n' "${copy}"
  left=$(find "${FLOOR_DIR}/temp" -mindepth 1)
  expect "floor: the copy under the converted directory is removed" 0 "" equal "" "${left}"

  for features in default all none; do
    case ${features} in
      default) flags="" ;;
      all) flags=" --all-features" ;;
      none) flags=" --no-default-features" ;;
      *) return 1 ;;
    esac
    floor_case "a build that fails with features: ${features} exits 1, naming the crate, the floor and the features" 1 \
      "floor: a does not build on 1.85.0 with features: ${features}" "${one}" "+1.85.0 build --lib -p a${flags}"
    count=$(grep -c . <<<"${FLOOR_RECORD}")
    expect "floor: a build that fails with features: ${features} stops none of the others" 0 "" equal 6 "${count}"
  done
  floor_case "a toolchain that is not one release is a bad invocation" 2 \
    "floor: the toolchain stable-x86_64-unknown-linux-gnu is not one exact release" "${one}" "" stable-x86_64-unknown-linux-gnu
  floor_case "a manifest cargo cannot read is a bad invocation" 2 "" -
  # On the stubs alone, given nothing to answer with, so a run past the usage check fails.
  expect "floor: an argument is a bad invocation" 2 "usage: floor.sh" \
    run_in "${FLOOR_DIR}/project" env PATH="${FLOOR_PATH}" bash "${GATE}/checks/floor.sh" all
  expect "floor: a directory with no Cargo.toml is a bad invocation" 2 "usage: floor.sh" \
    run_in "${FLOOR_DIR}" env PATH="${FLOOR_PATH}" bash "${GATE}/checks/floor.sh"
}

# licence_case <name> <status> <text> <workspace licence> <member licence> <LICENSE line> [<named>]:
# a two-crate workspace under those licences, its LICENSE holding that line, or none for "-",
# checked against the licence projects.json names where one is given.
licence_case() {
  local name=$1 want=$2 text=$3 workspace=$4 member=$5 line=$6 named=${7:-} dir
  dir=$(mktemp -d -p "${WORK}")
  mkdir -p "${dir}/a/src" "${dir}/b/src"
  printf '[workspace]\nmembers = ["a", "b"]\nresolver = "3"\n\n[workspace.package]\nlicense = "%s"\n' "${workspace}" >"${dir}/Cargo.toml"
  printf '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2024"\nlicense.workspace = true\n' >"${dir}/a/Cargo.toml"
  printf '[package]\nname = "b"\nversion = "0.1.0"\nedition = "2024"\nlicense = "%s"\n' "${member}" >"${dir}/b/Cargo.toml"
  : >"${dir}/a/src/lib.rs"
  : >"${dir}/b/src/lib.rs"
  [[ "${line}" == - ]] || printf '%s\n\n(the licence text)\n' "${line}" >"${dir}/LICENSE"
  expect "own-licence: ${name}" "${want}" "${text}" run_in "${dir}" bash "${GATE}/checks/own-licence.sh" ${named:+"${named}"}
}

licence_cases() {
  local apache='                                 Apache License
                           Version 2.0, January 2004' mpl='Mozilla Public License Version 2.0'
  licence_case "Apache-2.0 with its text passes" 0 "Apache-2.0, its text in LICENSE" Apache-2.0 Apache-2.0 "${apache}"
  licence_case "MPL-2.0 with its text passes" 0 "MPL-2.0, its text in LICENSE" MPL-2.0 MPL-2.0 "${mpl}"
  licence_case "MIT fails" 1 "under MIT; a public project is under Apache-2.0 or MPL-2.0" MIT MIT "MIT License"
  licence_case "a dual licence fails" 1 "under MIT OR Apache-2.0" "MIT OR Apache-2.0" "MIT OR Apache-2.0" "${apache}"
  licence_case "GPL-3.0-only fails" 1 "under GPL-3.0-only" GPL-3.0-only GPL-3.0-only "GNU GENERAL PUBLIC LICENSE"
  licence_case "two licences in one workspace fail" 1 "carry more than one licence" Apache-2.0 MPL-2.0 "${apache}"
  licence_case "Apache-2.0 beside MPL-2.0's text fails" 1 "LICENSE is not the text of Apache-2.0" Apache-2.0 Apache-2.0 "${mpl}"
  licence_case "MPL-2.0 beside Apache-2.0's text fails" 1 "LICENSE is not the text of MPL-2.0" MPL-2.0 MPL-2.0 "${apache}"
  licence_case "no LICENSE fails" 1 "holds no LICENSE" Apache-2.0 Apache-2.0 -
  licence_case "the licence projects.json names passes" 0 "MPL-2.0, its text in LICENSE" MPL-2.0 MPL-2.0 "${mpl}" MPL-2.0
  licence_case "another licence than projects.json's fails" 1 "under Apache-2.0; projects.json names MPL-2.0" Apache-2.0 Apache-2.0 "${apache}" MPL-2.0
}

# version_case <name> <status> <text> <workspace rust-version> <a's> <a's publish line>: a
# two-crate workspace on 1.100.0, "-" for a line left out; b takes the workspace's.
version_case() {
  local name=$1 want=$2 text=$3 workspace=$4 a=$5 publish=$6 dir
  dir=$(mktemp -d -p "${WORK}")
  mkdir -p "${dir}/a/src" "${dir}/b/src"
  printf '[toolchain]\nchannel = "1.100.0"\n' >"${dir}/rust-toolchain.toml"
  printf '[workspace]\nmembers = ["a", "b"]\nresolver = "3"\n\n[workspace.package]\n' >"${dir}/Cargo.toml"
  [[ "${workspace}" == - ]] || printf 'rust-version = "%s"\n' "${workspace}" >>"${dir}/Cargo.toml"
  printf '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2024"\n' >"${dir}/a/Cargo.toml"
  [[ "${a}" == - ]] || printf 'rust-version = "%s"\n' "${a}" >>"${dir}/a/Cargo.toml"
  [[ "${publish}" == - ]] || printf '%s\n' "${publish}" >>"${dir}/a/Cargo.toml"
  printf '[package]\nname = "b"\nversion = "0.1.0"\nedition = "2024"\nrust-version.workspace = true\n' >"${dir}/b/Cargo.toml"
  : >"${dir}/a/src/lib.rs"
  : >"${dir}/b/src/lib.rs"
  expect "rust-version: ${name}" "${want}" "${text}" env RUSTUP_TOOLCHAIN="${RUST_VERSION_TOOLCHAIN:-stable}" \
    python3 -I "${GATE}/checks/rust-version.py" "${dir}"
}

version_cases() {
  version_case "every crate on the toolchain's release passes" 0 "is at most the toolchain's release" 1.100.0 1.100.0 -
  version_case "a release written without its patch passes" 0 "is at most the toolchain's release" 1.100 1.100 -
  version_case "a crate below the toolchain passes" 0 "is at most the toolchain's release" 1.100.0 1.85 -
  version_case "a workspace below the toolchain passes" 0 "is at most the toolchain's release" 1.85.0 1.100.0 -
  version_case "a crate above the toolchain fails" 1 "a's rust-version is 1.100.1, above rust-toolchain.toml's 1.100.0" 1.100.0 1.100.1 -
  version_case "a workspace above the toolchain fails" 1 "[workspace.package] rust-version is 1.101, above rust-toolchain.toml's 1.100.0" 1.101 1.100.0 -
  version_case "a crate stating none fails" 1 "a states no rust-version" 1.100.0 - -
  version_case "an unpublished crate above it passes" 0 "is at most the toolchain's release" 1.100.0 1.101.0 "publish = false"
}

# The upstream every git_source_case reads, as git reads github.com: master holds one, two and the
# merge of a pull request whose own commit is a second parent alone; feature holds a commit master
# never took.
git_source_upstream() {
  local upstream=${WORK}/upstream/microsoft/windows-rs
  mkdir -p "${upstream}"
  git -C "${upstream}" init -q -b master
  git -C "${upstream}" commit -q --no-gpg-sign --allow-empty -m one
  git -C "${upstream}" checkout -q -b feature
  git -C "${upstream}" commit -q --no-gpg-sign --allow-empty -m unmerged
  git -C "${upstream}" checkout -q -b landed master
  git -C "${upstream}" commit -q --no-gpg-sign --allow-empty -m landed
  git -C "${upstream}" checkout -q master
  git -C "${upstream}" commit -q --no-gpg-sign --allow-empty -m two
  git -C "${upstream}" merge -q --no-ff --no-gpg-sign -m merge landed
  # crates.io's API as a mirror would serve it: windows-reactor 0.101.0 once published.
  mkdir -p "${WORK}/api-published/crates/windows-reactor" "${WORK}/api-none/crates"
  printf '{}\n' >"${WORK}/api-published/crates/windows-reactor/0.101.0"
}

# git_source_case <name> <status> <text> <lock source line> [<api>]: a project listing windows-rs on
# master, awaiting windows-reactor 0.101.0, its lock taking one package from the source given ("-"
# for none); crates.io's API is the fixture's <api> (published or none).
git_source_case() {
  local name=$1 want=$2 text=$3 source=$4 api=${5:-none} dir
  dir=$(mktemp -d -p "${WORK}")
  printf '%s\n' '{"projects": {"crate-a": {"repository": "shuwariafrica/crate-a", "git_sources": [{"repository": "https://github.com/microsoft/windows-rs", "branch": "master", "awaits": {"crate": "windows-reactor", "version": "0.101.0"}}]}}}' >"${dir}/projects.json"
  printf 'version = 4\n\n[[package]]\nname = "crate-a"\nversion = "0.1.0"\n' >"${dir}/Cargo.lock"
  [[ "${source}" == - ]] || printf '\n[[package]]\nname = "windows-reactor"\nversion = "0.100.0"\nsource = "%s"\n' "${source}" >>"${dir}/Cargo.lock"
  expect "git-sources: ${name}" "${want}" "${text}" env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.${WORK}/upstream/.insteadOf" \
    GIT_CONFIG_VALUE_0=https://github.com/ CRATES_IO_API="file://${WORK}/api-${api}" \
    python3 -I "${GATE}/checks/git-sources.py" "${dir}" "${dir}/projects.json" shuwariafrica/crate-a "${dir}/work"
}

git_source_cases() {
  local upstream=${WORK}/upstream/microsoft/windows-rs merged merge second feature
  git_source_upstream
  merged=$(git -C "${upstream}" rev-parse master~1)
  merge=$(git -C "${upstream}" rev-parse master)
  second=$(git -C "${upstream}" rev-parse landed)
  feature=$(git -C "${upstream}" rev-parse feature)
  git_source_case "a lock from crates.io alone passes" 0 "every git source the lock takes is listed" -
  git_source_case "the listed source on its branch passes" 0 "every git source the lock takes is listed" "git+https://github.com/microsoft/windows-rs?branch=master#${merged}"
  git_source_case "the listed source at the branch's merge commit passes" 0 "every git source the lock takes is listed" "git+https://github.com/microsoft/windows-rs?rev=${merge}#${merge}"
  git_source_case "the listed source spelt with .git passes" 0 "every git source the lock takes is listed" "git+https://github.com/microsoft/windows-rs.git?rev=${merged}#${merged}"
  git_source_case "an unlisted source fails" 1 "takes https://github.com/example/fork at ${merged}, which projects.json's git_sources for shuwariafrica/crate-a does not list" "git+https://github.com/example/fork?rev=${merged}#${merged}"
  git_source_case "a revision on another branch alone fails" 1 "takes https://github.com/microsoft/windows-rs at ${feature}, which is not on the first-parent line of its master" "git+https://github.com/microsoft/windows-rs?rev=${feature}#${feature}"
  git_source_case "a merged pull request's own commit fails" 1 "at ${second}, which is not on the first-parent line" "git+https://github.com/microsoft/windows-rs?rev=${second}#${second}"
  git_source_case "the awaited release is a warning, and the verdict stands" 0 "::warning title=git-sources::windows-reactor 0.101.0 is on crates.io" "git+https://github.com/microsoft/windows-rs?branch=master#${merged}" published
  git_source_case "the awaited release beside a fault changes no verdict" 1 "windows-reactor 0.101.0 is on crates.io: take it from there, and drop https://github.com/microsoft/windows-rs from git_sources
git-sources: Cargo.lock takes https://github.com/microsoft/windows-rs at ${feature}, which is not on the first-parent line" "git+https://github.com/microsoft/windows-rs?rev=${feature}#${feature}" published
}

# package_case <name> <text> <git_sources JSON>: package.sh in a workspace whose cargo is a stub
# recording its arguments, for a project listing those sources.
package_case() {
  local name=$1 text=$2 sources=$3 dir found
  dir=$(mktemp -d -p "${WORK}")
  mkdir -p "${dir}/bin" "${dir}/project"
  printf '#!/usr/bin/env bash\nprintf "cargo %%s\\n" "$*" >>"%s/record"\n' "${dir}" >"${dir}/bin/cargo"
  chmod +x "${dir}/bin/cargo"
  found=$(PATH="${dir}/bin:${PATH}" type -P cargo)
  [[ "${found}" == "${dir}/bin/cargo" ]]
  : >"${dir}/record"
  jq -n --argjson sources "${sources}" '{projects: {"crate-a": {repository: "shuwariafrica/crate-a", git_sources: $sources}}}' >"${dir}/projects.json"
  expect "package: ${name}" 0 "${text}" \
    run_in "${dir}/project" env PATH="${dir}/bin:${PATH}" GITHUB_STEP_SUMMARY="${dir}/summary" bash "${GATE}/checks/package.sh" "${dir}/projects.json" shuwariafrica/crate-a
  PACKAGE_RECORD=$(<"${dir}/record")
  PACKAGE_SUMMARY=$(cat "${dir}/summary" 2>/dev/null || true) # absent where nothing was skipped
}

package_cases() {
  package_case "an empty list runs cargo package" "+ cargo package --workspace --locked" '[]'
  expect "package: an empty list ran cargo package --workspace --locked" 0 "cargo package --workspace --locked" printf '%s\n' "${PACKAGE_RECORD}"
  package_case "a listed git source skips it, naming the awaited release" \
    "cargo package: skipped, the project takes git sources awaiting windows-reactor 0.101.0 on crates.io" \
    '[{"repository": "https://github.com/microsoft/windows-rs", "branch": "master", "awaits": {"crate": "windows-reactor", "version": "0.101.0"}}]'
  expect "package: a skipped package runs no cargo" 0 "" test -z "${PACKAGE_RECORD}"
  expect "package: the skip is in the run's summary" 0 "awaiting windows-reactor 0.101.0" printf '%s\n' "${PACKAGE_SUMMARY}"
}

semver_cases() {
  # shellcheck source=checks/semver-checks.sh
  source "${GATE}/checks/semver-checks.sh"
  expect "semver-checks: a one-letter crate's index path" 0 "1/a" index_path a
  expect "semver-checks: a two-letter crate's index path" 0 "2/ab" index_path AB
  expect "semver-checks: a three-letter crate's index path" 0 "3/s/syn" index_path syn
  expect "semver-checks: a longer crate's index path" 0 "se/rd/serde_json" index_path Serde_json
}

# native_path <dir>: the PATH on which a Windows job's native programs run. Git Bash's own where this
# is Git Bash; elsewhere, a stand-in jq in <dir> comes first and ends each line with CRLF unless given
# -b, as jq's manual says a Windows build does.
native_path() {
  local dir=$1 jq found
  if command -v cygpath >/dev/null 2>&1; then
    printf '%s\n' "${PATH}"
    return
  fi
  jq=$(command -v jq)
  mkdir -p "${dir}"
  cat >"${dir}/jq" <<STUB
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  [[ "\${arg}" != -b ]] || exec ${jq@Q} "\$@"
done
${jq@Q} "\$@" | sed 's/\$/\r/'
STUB
  chmod +x "${dir}/jq"
  found=$(PATH="${dir}:${PATH}" type -P jq)
  [[ "${found}" == "${dir}/jq" ]]
  printf '%s\n' "${dir}:${PATH}"
}

# line_of <line> <command...>: the command's output; fails unless the command succeeds and a line of
# its output is <line> exactly.
line_of() {
  local line=$1 output
  shift
  output=$("$@") || return
  printf '%s\n' "${output}"
  grep -qxF -- "${line}" <<<"${output}"
}

# The scripts a Windows job runs over native_path's jq: one licence across crates that carry one,
# each crate on crates.io compared, and the licence handed to the steps as its own value.
native_cases() {
  local dir native one found
  dir=$(mktemp -d -p "${WORK}")
  native=$(native_path "${dir}/native")
  mkdir -p "${dir}/licence/a/src" "${dir}/licence/b/src" "${dir}/semver/bin"
  printf '[workspace]\nmembers = ["a", "b"]\nresolver = "3"\n\n[workspace.package]\nlicense = "Apache-2.0"\n' >"${dir}/licence/Cargo.toml"
  printf '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2024"\nlicense.workspace = true\n' >"${dir}/licence/a/Cargo.toml"
  printf '[package]\nname = "b"\nversion = "0.1.0"\nedition = "2024"\nlicense.workspace = true\n' >"${dir}/licence/b/Cargo.toml"
  : >"${dir}/licence/a/src/lib.rs"
  : >"${dir}/licence/b/src/lib.rs"
  printf '                           Version 2.0, January 2004\n' >"${dir}/licence/LICENSE"
  expect "own-licence: crates of one licence, from a native jq, carry one" 0 "own-licence: Apache-2.0, its text in LICENSE" \
    run_in "${dir}/licence" env PATH="${native}" bash "${GATE}/checks/own-licence.sh" Apache-2.0
  # crates.io's index holds both crates; cargo semver-checks records what it is asked.
  cat >"${dir}/semver/bin/cargo" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  metadata) printf '{"workspace_members":["a","b"],"packages":[{"id":"a","name":"crate-a","publish":null},{"id":"b","name":"crate-b","publish":null}]}\n' ;;
  semver-checks) printf 'cargo %s\n' "$*" >>"${RECORD:?}" ;;
  *) exit 2 ;;
esac
STUB
  cat >"${dir}/semver/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "${!#}" in
  https://index.crates.io/cr/at/crate-a | https://index.crates.io/cr/at/crate-b) printf 200 ;;
  *) printf 404 ;;
esac
STUB
  chmod +x "${dir}/semver/bin/cargo" "${dir}/semver/bin/curl"
  found=$(PATH="${dir}/semver/bin:${native}" type -P cargo)
  [[ "${found}" == "${dir}/semver/bin/cargo" ]]
  found=$(PATH="${dir}/semver/bin:${native}" type -P curl)
  [[ "${found}" == "${dir}/semver/bin/curl" ]]
  : >"${dir}/semver/record"
  expect "semver-checks: each crate on crates.io compared, by names from a native jq" 0 "+ cargo semver-checks --package crate-a --package crate-b" \
    run_in "${dir}/semver" env PATH="${dir}/semver/bin:${native}" RECORD="${dir}/semver/record" GITHUB_STEP_SUMMARY="${dir}/semver/summary" \
    bash "${GATE}/checks/semver-checks.sh"
  one='{"projects": {"crate-a": {"repository": "shuwariafrica/crate-a", "repository_id": 1001, "crates": ["crate-a"],
    "crates_io_owners": ["arashi01"], "tag_signers": ["20BBB4E4F90F3CE6F9BBFCDB78A12350D373DF6B"], "signing_key": null,
    "first_version": "0.1.0", "platforms": ["linux-x64", "windows-x64"], "license": "MPL-2.0"}}}'
  expect "project: the licence goes to the steps as its own line, from a native jq" 0 "licence=MPL-2.0" \
    line_of licence=MPL-2.0 project "${one}" PATH="${native}"
}

main() {
  local self only=${1:-}
  [[ -z "${only}" || "${only}" == windows ]] || {
    printf 'usage: checks/test.sh [windows]\n' >&2
    exit 2
  }
  self=$(realpath -- "${BASH_SOURCE[0]}")
  GATE=$(cd -- "$(dirname -- "${self}")/.." && pwd)
  WORK=$(mktemp -d)
  trap '((BASHPID == '"${BASHPID}"')) && rm -rf -- "${WORK}"' EXIT
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=checks GIT_AUTHOR_EMAIL=checks@invalid GIT_COMMITTER_NAME=checks GIT_COMMITTER_EMAIL=checks@invalid
  if [[ "${only}" == windows ]]; then
    project_cases
    licence_cases
    package_cases
    packaged_cases
    floor_cases
    semver_cases
    native_cases
  else
    gate_configuration_cases
    toolchain_cases
    plan_cases
    project_cases
    licence_cases
    version_cases
    git_source_cases
    package_cases
    packaged_cases
    floor_cases
    semver_cases
    native_cases
  fi
  if ((failed > 0)); then
    printf '%s case(s) failed\n' "${failed}"
    exit 1
  fi
  printf 'every case passed\n'
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
