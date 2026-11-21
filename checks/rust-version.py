#!/usr/bin/env python3
"""Fails a project's tree unless every publishable crate's `rust-version`, and the workspace's
where it states one, is the release its rust-toolchain.toml names: the one release the project is
verified on. A crate that states none is refused too.

    rust-version.py <project>

Run with `python3 -I` (3.11 or later) after toolchain-file.py has passed, with cargo on PATH.
Prints each fault, also to GITHUB_STEP_SUMMARY when it is set; exits 1 on any, 2 on a bad
invocation or a manifest cargo cannot read.
"""

import json
import os
import subprocess
import sys
import tomllib


def release(version: str) -> tuple[int, ...]:
    """A release number with absent parts as 0, so "1.100" and "1.100.0" are one release."""
    parts = [int(part) for part in version.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def faults(project: str) -> list[str]:
    with open(os.path.join(project, "rust-toolchain.toml"), "rb") as f:
        channel = tomllib.load(f)["toolchain"]["channel"]
    with open(os.path.join(project, "Cargo.toml"), "rb") as f:
        root = tomllib.load(f)
    metadata = subprocess.run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1"],
        cwd=project, capture_output=True, check=False,
    )
    if metadata.returncode != 0:
        sys.stderr.write(metadata.stderr.decode("utf-8", "replace"))
        raise SystemExit(2)
    packages = json.loads(metadata.stdout)
    members = set(packages["workspace_members"])

    found = []
    workspace = root.get("workspace", {}).get("package", {}).get("rust-version")
    if isinstance(workspace, str) and release(workspace) != release(channel):
        found.append(f"[workspace.package] rust-version is {workspace}, rust-toolchain.toml {channel}")
    for package in packages["packages"]:
        publish = package.get("publish")
        if package["id"] not in members or publish == []:
            continue
        stated = package.get("rust_version")
        if stated is None:
            found.append(f"{package['name']} states no rust-version; rust-toolchain.toml names {channel}")
        elif release(stated) != release(channel):
            found.append(f"{package['name']}'s rust-version is {stated}, rust-toolchain.toml {channel}")
    return found


def main() -> int:
    if len(sys.argv) != 2 or not os.path.isfile(os.path.join(sys.argv[1], "Cargo.toml")):
        sys.stderr.write("usage: rust-version.py <project>, a workspace holding Cargo.toml\n")
        return 2
    found = faults(sys.argv[1])
    if not found:
        print("rust-version: every publishable crate names the toolchain's release")
        return 0
    text = "".join(f"rust-version: {fault}\n" for fault in found)
    sys.stdout.write(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(text)
    return 1


if __name__ == "__main__":
    sys.exit(main())
