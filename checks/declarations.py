#!/usr/bin/env python3
"""Fails when the platforms the checks name disagree: platforms.json's keys, the platforms
projects.schema.json admits, and the platforms mise.lock holds an entry for, for every tool, are
one set; and each project of projects.json is keyed by its own repository's name.

    python3 -I checks/declarations.py   (from the repository's root; 3.11 or later)
"""

import json
import sys
import tomllib


def main() -> int:
    with open("platforms.json", encoding="utf-8") as f:
        platforms = set(json.load(f))
    with open("projects.schema.json", encoding="utf-8") as f:
        schema = json.load(f)
    with open("projects.json", encoding="utf-8") as f:
        projects = json.load(f)["projects"]
    with open("mise.lock", "rb") as f:
        lock = tomllib.load(f)

    faults = []
    admitted = set(schema["$defs"]["project"]["properties"]["platforms"]["items"]["enum"])
    if admitted != platforms:
        faults.append(f"projects.schema.json admits {sorted(admitted)}, platforms.json holds {sorted(platforms)}")
    # A tool whose options differ by platform has one lock entry per set of options.
    for tool, entries in lock["tools"].items():
        locked = {key.removeprefix("platforms.") for entry in entries for key in entry if key.startswith("platforms.")}
        if locked != platforms:
            faults.append(f"mise.lock holds {tool} for {sorted(locked)}, the checks run on {sorted(platforms)}")
    for key, project in projects.items():
        if project["repository"].split("/")[1] != key:
            faults.append(f"projects.json keys {project['repository']} as {key}")

    for fault in faults:
        print(f"declarations: {fault}", file=sys.stderr)
    return 1 if faults else 0


if __name__ == "__main__":
    sys.exit(main())
