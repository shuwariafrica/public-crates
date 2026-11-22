#!/usr/bin/env python3
"""Lists what a change does to the files that set what the checks check, and fails when it does
anything. Which files, and which tables of a manifest, are this repository's
gate-configuration.json beside this script: each file pattern is matched at any depth, under every
name its tool reads it by, and a manifest counts where one of the named tables, or its
`rust-version`, changes. A tree that holds them passes; only a change to one fails.

One change passes as data, the routine toolchain raise: the root rust-toolchain.toml changes its
`channel` alone, from one exact stable release to a later one, every publishable crate's
`rust-version`, and the workspace's, that named the earlier release names the later one afterwards,
and each one below the earlier release is unchanged. A lower `rust-version` is the project's own
floor, reviewed like the rest of what the checks check, so the raise carries it along unchanged. A
`rust-version` change passes only as part of the raise.

    gate-configuration.py <base> <head>

Run with `python3 -I` (3.11 or later, for tomllib) inside the project's checkout, whose git holds
both commits. Prints each changed file, also to GITHUB_STEP_SUMMARY when it is set; exits 1 when
any changed, 2 on a bad invocation or a commit git cannot read.
"""

import json
import os
import re
import subprocess
import sys
import tomllib

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "gate-configuration.json"), encoding="utf-8") as _f:
    _RULES = json.load(_f)
GATE_FILES = re.compile("|".join(f"(?:{pattern})" for pattern in _RULES["files"]))
TABLES = [tuple(keys) for keys in _RULES["manifest_tables"]]
MANIFEST = re.compile(r"(^|/)Cargo\.toml$")
TOOLCHAIN = "rust-toolchain.toml"
RELEASE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
UNREADABLE = "unreadable"


def git(*args: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(["git", *args], capture_output=True, check=False)


def toml_at(revision: str, path: str) -> object:
    """The file's TOML at `revision`; None where it is absent there, UNREADABLE where it is not
    TOML, which differs from any readable document."""
    shown = git("show", f"{revision}:{path}")
    if shown.returncode != 0:
        return None
    try:
        return tomllib.loads(shown.stdout.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError):
        return UNREADABLE


def table(document: object, *keys: str) -> object:
    for key in keys:
        document = document.get(key) if isinstance(document, dict) else None
    return document


def release(version: object) -> tuple[int, ...] | None:
    """A rust-version as a release, absent parts 0; None for anything else."""
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", version):
        return None
    parts = [int(part) for part in version.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def raised(base: str, head: str) -> tuple[tuple[int, ...], tuple[int, ...]] | None:
    """The releases the root toolchain file is raised from and to, where its change is a routine
    raise."""
    before, after = toml_at(base, TOOLCHAIN), toml_at(head, TOOLCHAIN)
    if not isinstance(before, dict) or not isinstance(after, dict):
        return None
    if set(before) != {"toolchain"} or set(after) != {"toolchain"}:
        return None
    old, new = before["toolchain"], after["toolchain"]
    if not isinstance(old, dict) or not isinstance(new, dict) or "path" in old or "path" in new:
        return None
    if {k: v for k, v in old.items() if k != "channel"} != {k: v for k, v in new.items() if k != "channel"}:
        return None
    if not all(isinstance(c, str) and RELEASE.match(c) for c in (old.get("channel"), new.get("channel"))):
        return None
    if release(new["channel"]) <= release(old["channel"]):
        return None
    return release(old["channel"]), release(new["channel"])


def carried(before: list[object], after: list[object], raise_: tuple[tuple[int, ...], tuple[int, ...]]) -> bool:
    """Whether a manifest's rust-versions change as the raise moves them: each that named the
    earlier release names the later one, and every other is unchanged."""
    old, new = raise_
    return len(before) == len(after) and all(
        a == b or (release(b) == old and release(a) == new) for b, a in zip(before, after)
    )


def rust_versions(document: object) -> list[object]:
    """The rust-versions a manifest states, its package's (where it publishes) and its workspace's;
    an inherited one is the workspace's."""
    stated = []
    package = table(document, "package")
    if isinstance(package, dict) and package.get("publish") is not False and package.get("publish") != []:
        version = package.get("rust-version")
        if not isinstance(version, dict):
            stated.append(version)
    workspace = table(document, "workspace", "package", "rust-version")
    if workspace is not None:
        stated.append(workspace)
    return stated


def changed(base: str, head: str) -> list[str]:
    diff = git("diff", "--no-renames", "--name-only", "-z", base, head, "--")
    if diff.returncode != 0:
        sys.stderr.write(diff.stderr.decode("utf-8", "replace"))
        raise SystemExit(2)
    paths = [raw.decode("utf-8", "surrogateescape") for raw in diff.stdout.split(b"\0") if raw]
    raise_ = raised(base, head) if TOOLCHAIN in paths else None

    found = []
    for path in paths:
        if path == TOOLCHAIN and raise_ is not None:
            continue
        if GATE_FILES.search(path):
            found.append(path)
        elif MANIFEST.search(path):
            before, after = toml_at(base, path), toml_at(head, path)
            if UNREADABLE in (before, after) or [table(before, *keys) for keys in TABLES] != [table(after, *keys) for keys in TABLES]:
                found.append(f"{path}: its {' or '.join('[' + '.'.join(keys) + ']' for keys in TABLES)}")
            # A manifest added or removed takes its rust-version with it, which rust-version.py
            # holds to at most the toolchain's release and floor.sh builds on.
            elif None not in (before, after) and rust_versions(before) != rust_versions(after) and (
                raise_ is None or not carried(rust_versions(before), rust_versions(after), raise_)
            ):
                found.append(f"{path}: its rust-version, outside a routine toolchain raise")

    # A raise leaves no publishable crate, and not the workspace, on the release it raises from.
    if raise_ is not None:
        listing = git("ls-tree", "-r", "-z", "--name-only", head)
        for raw in listing.stdout.split(b"\0"):
            path = raw.decode("utf-8", "surrogateescape")
            if MANIFEST.search(path):
                behind = [v for v in rust_versions(toml_at(head, path)) if release(v) == raise_[0]]
                if behind:
                    found.append(f"{path}: its rust-version {behind[0]} is left behind the raised toolchain")
    return found


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: gate-configuration.py <base> <head>\n")
        return 2
    found = changed(sys.argv[1], sys.argv[2])
    if not found:
        print("gate-configuration: this change leaves what the checks check as it is")
        return 0
    lines = [
        "gate-configuration: this change sets what the checks check, so it lands only by a deliberate "
        "merge through this check's bypass, and the checks themselves still pass:",
        *(f"- {path}" for path in found),
    ]
    text = "\n".join(lines) + "\n"
    sys.stdout.write(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(text)
    return 1


if __name__ == "__main__":
    sys.exit(main())
