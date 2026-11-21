#!/usr/bin/env python3
"""Fails a project's tree unless its toolchain is one exact release, named in the root's
rust-toolchain.toml alone: no `rust-toolchain` file at any depth (rustup prefers it to the .toml
beside it), no `path` key (a toolchain from the tree itself), no other channel than a release
number, and no rust-toolchain.toml elsewhere that says otherwise.

    toolchain-file.py <project>

Run with `python3 -I` (3.11 or later, for tomllib). Prints each fault, also to
GITHUB_STEP_SUMMARY when it is set; exits 1 on any, 2 on a bad invocation.
"""

import os
import re
import sys
import tomllib

RELEASE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def faults_of(path: str, shown: str) -> list[str]:
    try:
        with open(path, "rb") as f:
            document = tomllib.load(f)
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        return [f"{shown} is not readable TOML: {error}"]
    faults = []
    toolchain = document.get("toolchain")
    if set(document) != {"toolchain"} or not isinstance(toolchain, dict):
        faults.append(f"{shown} holds more than one [toolchain] table")
        toolchain = toolchain if isinstance(toolchain, dict) else {}
    if "path" in toolchain:
        faults.append(f"{shown} names a toolchain by path, which runs a toolchain from the tree")
    channel = toolchain.get("channel")
    if not isinstance(channel, str) or not RELEASE.match(channel):
        faults.append(f"{shown} names channel {channel!r}, not one exact release")
    return faults


def faults(project: str) -> list[str]:
    found = []
    root = os.path.join(project, "rust-toolchain.toml")
    if not os.path.isfile(root):
        found.append("the tree names no toolchain: rust-toolchain.toml is absent at its root")
    for directory, subdirectories, files in os.walk(project):
        subdirectories[:] = [d for d in subdirectories if d != ".git"]
        relative = os.path.relpath(directory, project)
        for name in files:
            shown = name if relative == "." else f"{relative}/{name}"
            if name == "rust-toolchain":
                found.append(f"{shown} exists, and rustup prefers it to rust-toolchain.toml")
            elif name == "rust-toolchain.toml":
                found.extend(faults_of(os.path.join(directory, name), shown))
    return found


def main() -> int:
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.stderr.write("usage: toolchain-file.py <project>\n")
        return 2
    found = faults(sys.argv[1])
    if not found:
        print("toolchain-file: one exact release, in rust-toolchain.toml alone")
        return 0
    text = "".join(f"toolchain-file: {fault}\n" for fault in found)
    sys.stdout.write(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(text)
    return 1


if __name__ == "__main__":
    sys.exit(main())
