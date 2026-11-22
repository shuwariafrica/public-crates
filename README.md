# public-crates

The checks every public Rust project of Shuwari Africa passes. A project holds no workflow of its
own but `template/`'s `release.yml`: the organisation requires two workflows of this repository on
every pull request to each project's default branch, at one commit of this repository. `checks.yml` runs the checks, and
nobody bypasses it. `gate-configuration.yml` fails a change to what the checks check, and an
organisation owner alone bypasses it, by merging the pull request: that deliberate merge covers the
configuration change alone, and the checks must still pass.

## The checks

On each platform the project names, in its workspace, each as its own step of the run:

```
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
RUSTDOCFLAGS='-D warnings' cargo doc --workspace --no-deps --locked
cargo package --workspace --locked
cargo deny check
cargo semver-checks
```

`cargo semver-checks` compares each crate with its last release on crates.io; a crate with no
release there is skipped, and the run's summary names it. `cargo package` is skipped while the
project's `git_sources` lists any source, since a packaged crate resolves its dependencies from
crates.io alone; the run's summary names each awaited crate and version.

Before them, each platform's job holds the project to its licence: every crate's manifest names
one `license`, `Apache-2.0` or `MPL-2.0`, and `LICENSE` at the workspace root is that licence's text.
It also builds each publishable crate whose `rust-version` is below the toolchain's release on the
release it states, its lowest: the library with default features, with all features and, where the
crate declares defaults, with none, resolved afresh in a copy of the workspace without its
`Cargo.lock`. A crate that states no lower release states the toolchain's.

Two more things read the tree itself:

- Each Linux job fails a tree whose toolchain is anything but one exact release in
  `rust-toolchain.toml` alone (a `rust-toolchain` file anywhere, a `path` key, a channel such as
  `stable`), one in which a publishable crate states no `rust-version`, or it or the workspace's is
  above that release, and one whose `Cargo.lock` takes a package from a git source that the project's
  `git_sources` in `projects.json` does not list, or at a revision off the listed branch.
- `gate-configuration.yml` fails a pull request that changes what the checks check, and lists the
  files: `.cargo/config.toml` or `.cargo/config`, `deny.toml`, `clippy.toml` or `.clippy.toml`,
  `rustfmt.toml` or `.rustfmt.toml`, `rust-toolchain.toml` or `rust-toolchain`, at any depth, any
  file under `.github/` (a workflow added there would run with the project's token), and any
  manifest's `[lints]`, `[workspace.lints]` or `rust-version`. A tree may hold any of them; a
  change to one lands only by an organisation owner's merge through this workflow's bypass. A routine toolchain raise passes:
  `rust-toolchain.toml`'s `channel` alone moves from one exact stable release to a later one, each
  publishable crate's `rust-version`, and the workspace's, that named the earlier release moves with
  it, and each one below it stays as it is. Its file list is
  `checks/gate-configuration.json`.

A git source is admitted per project, with the release that retires it: `projects.json`'s
`git_sources` names its repository, the branch whose first-parent line the lock's revision must be
on, and the crate version it awaits. Once crates.io publishes that version, the run's summary says
so as a warning, and the verdict stands. The project's `deny.toml` must `allow-git` the same
source, which is itself a configuration change.

Every run is on GitHub's standard hosted runners, restores no cache, holds a read-only token and
no secret. A first-time contributor's run waits for a maintainer's approval.

## Running them yourself

The toolchain is the project's: rustup installs what its `rust-toolchain.toml` names. The other
tools are this repository's, at the versions and digests `mise.lock` holds for Linux and Windows
on x64 and arm64:

```
git clone https://github.com/shuwariafrica/public-crates
cd public-crates && mise install --locked cargo-deny github:obi1kenobi/cargo-semver-checks
```

Then, in the project's workspace, the seven commands above, each with the tools on `PATH` (`mise
where cargo-deny` names the directory). A project's own `mise.toml`, if it has one, plays no part
in the checks.

## What is here

| Path | What it holds |
| --- | --- |
| `.github/workflows/checks.yml` | The checks, one job per platform of the project |
| `.github/actions/checks` | One platform's checks, which `checks.yml` runs and a project's release runs at `gate-commit` on its tag's commit |
| `.github/workflows/gate-configuration.yml` | The check of what the checks check, under its own ruleset and bypass |
| `.github/actions/mise` | mise at a pinned release and digest, installing from `mise.lock` with no cache |
| `.github/workflows/actions.lock` | Every action the workflows run, at a commit, which GitHub enforces at run time |
| `projects.json`, `projects.schema.json` | Each project: its repository and id, crates, tag signers, signing key, first version, platforms, licence and the git sources its lock may take |
| `keys/` | Each tag signer's certificate, `<fingerprint>.asc`, which a project's release verifies its tag with |
| `signing-keys/` | Each project's signing certificate, `<repository>.asc`, which a user's check of a release fetches and the infrastructure catalogue holds equal to its own |
| `gate-commit` | The commit of this repository the organisation's rulesets and every project's release run the checks at, which the infrastructure catalogue holds equal to its stage |
| `platforms.json` | Each platform's runner |
| `mise.toml`, `mise.lock` | The tools the checks and this repository's own checks run |
| `checks/` | The scripts the jobs run, and their cases (`checks/test.sh`) |
| `template/` | What a project takes when it is lifted here, its `release.yml` among them |

## Lifting a project

1. Its repository is public, and the infrastructure catalogue marks it `public_crate = "rust"`; an
   organisation owner alone sets the property that brings the rulesets onto it.
2. Its licence is Apache-2.0, or MPL-2.0 where interoperability with the GPL family is foreseen:
   every manifest's `license` names it and `LICENSE` holds its text. Its root takes `template/`'s
   files: `rust-toolchain.toml` (the current stable, with rustfmt and clippy), `.cargo/config.toml`
   (cargo's seven-day publish age and nothing else), `deny.toml`, `clippy.toml`,
   `.github/dependabot.yml`, `.github/workflows/release.yml` (with
   `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` replaced by the commit of `shuwariafrica/.github`
   that holds the `crate-*` actions, `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb` by `gate-commit`, and
   `verify`'s list by one entry per platform of the project, each with `platforms.json`'s runner),
   `CONTRIBUTING.md`, `SECURITY.md` and `CHANGELOG.md` (with `<project>`, `<crate>` and the signing
   key's fingerprint filled in), and `Cargo.toml`'s `[workspace.package]` and
   `[workspace.lints]` tables, which each member takes with `rust-version.workspace = true`,
   `license.workspace = true` and `[lints] workspace = true`. Its `.gitignore`, where it excludes
   dot-named paths, names `.cargo/` back, and where it excludes Markdown, the three documents.
   Its own `README.md` states the signing key's fingerprint and points to `SECURITY.md`: crates.io
   and docs.rs publish a crate's README, so the fingerprint a user compares the certificate with is
   stated away from GitHub, which serves both the certificate and `SECURITY.md`.
3. `projects.json` gains its entry, keyed by its repository's name, by a pull request here, its
   `crates_io_owners` the organisation's owners who hold a crates.io login, as the infrastructure
   catalogue lists them, and its `signing_key` null until the project's key is made, which every
   release step refuses.

When Dependabot raises the toolchain, each `rust-version` that names the earlier release moves with
it on the same branch, or the pull request fails; a lower one stays as it is.

## Changing this repository

`main` takes pull requests alone, on this repository's own `checks` job. A change to
`checks.yml`, `.github/actions/checks`, `checks/`, `mise.lock` or `projects.json` reaches the
projects only once the infrastructure catalogue stages the new commit, `gate-commit` names it, and
each project's `release.yml` names it beside. A tool is raised in `mise.toml`, then locked for
every platform:

```
mise lock --platform linux-x64,linux-arm64,windows-x64,windows-arm64
```

Dependabot raises the actions and regenerates `actions.lock`; an action added by hand is locked
with `gh actions-lock`.
