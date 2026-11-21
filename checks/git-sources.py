#!/usr/bin/env python3
"""Fails a project's tree whose Cargo.lock takes a package from a git source that the project's
`git_sources` in projects.json does not admit: the source's repository must be listed, and the
lock's revision must be on the first-parent line of the branch its entry names. A repository the
entry's `patched_from` names, where it has one, is held to its main by sources.py instead.

Each entry awaits a crate version that retires it. Where crates.io publishes that version, the run
says so as a warning, and the verdict does not change: a commit's verdict never moves with an
upstream's calendar.

    git-sources.py <project> <projects.json> <repository> <work>

Run with `python3 -I` (3.11 or later) and git on PATH. <repository> is owner/name as projects.json
names it; <work> is an empty or absent directory the histories are fetched into. A repository is
read anonymously, or with the token in TOKEN where it is set, which reaches git through its
environment alone, never an argument. crates.io's API is read at CRATES_IO_API where it is set (a
mirror), else at https://crates.io/api/v1. Prints each fault and warning, also to
GITHUB_STEP_SUMMARY when it is set; exits 1 on any fault, 2 on a bad invocation or a lock that does
not read.
"""

import base64
import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request


def repository_of(url: str) -> str:
    """A git URL as one name: no trailing `/` or `.git`."""
    url = url.rstrip("/")
    return url[: -len(".git")] if url.endswith(".git") else url


def taken(lock: dict) -> set[tuple[str, str]]:
    """Each git source the lock takes a package from, as (repository, commit)."""
    sources = set()
    for package in lock.get("package", []):
        source = package.get("source", "")
        if source.startswith("git+"):
            location, _, commit = source[len("git+"):].partition("#")
            sources.add((repository_of(location.partition("?")[0]), commit))
    return sources


def git_environment() -> dict[str, str]:
    environment = dict(os.environ)
    token = environment.pop("TOKEN", "")
    if token:
        credential = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        count = int(environment.get("GIT_CONFIG_COUNT", "0"))
        environment[f"GIT_CONFIG_KEY_{count}"] = "http.https://github.com/.extraheader"
        environment[f"GIT_CONFIG_VALUE_{count}"] = f"AUTHORIZATION: basic {credential}"
        environment["GIT_CONFIG_COUNT"] = str(count + 1)
    environment["GIT_TERMINAL_PROMPT"] = "0"
    return environment


def first_parents(repository: str, branch: str, work: str, environment: dict[str, str]) -> set[str] | None:
    """The commits on the first-parent line of the repository's branch; None where it does not read."""
    directory = os.path.join(work, re.sub(r"[^A-Za-z0-9._-]", "_", f"{repository}@{branch}"))
    if not os.path.isdir(directory):
        subprocess.run(["git", "init", "-q", directory], check=True, env=environment, capture_output=True)
        fetched = subprocess.run(
            ["git", "-C", directory, "fetch", "-q", "--no-tags", "--filter=tree:0", repository, f"refs/heads/{branch}"],
            capture_output=True, check=False, env=environment,
        )
        if fetched.returncode != 0:
            sys.stderr.write(fetched.stderr.decode("utf-8", "replace"))
            return None
    listed = subprocess.run(
        ["git", "-C", directory, "rev-list", "--first-parent", "FETCH_HEAD"], capture_output=True, check=False, env=environment,
    )
    return set(listed.stdout.decode().split()) if listed.returncode == 0 else None


def published(crate: str, version: str) -> bool | None:
    """Whether crates.io publishes the version; None where its API does not answer."""
    root = os.environ.get("CRATES_IO_API", "https://crates.io/api/v1").rstrip("/")
    request = urllib.request.Request(f"{root}/crates/{crate}/{version}", headers={"User-Agent": "shuwariafrica-checks"})
    try:
        # urlopen raises on every answer but a success, so an answer read is the version's page.
        with urllib.request.urlopen(request, timeout=30):
            return True
    except urllib.error.HTTPError as error:
        return False if error.code == 404 else None
    except (urllib.error.URLError, OSError):
        return None


def report(lines: list[str]) -> None:
    text = "".join(f"{line}\n" for line in lines)
    sys.stdout.write(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(text)


def main() -> int:
    if len(sys.argv) != 5:
        sys.stderr.write("usage: git-sources.py <project> <projects.json> <repository> <work>\n")
        return 2
    project, projects_file, repository, work = sys.argv[1:]
    with open(projects_file, encoding="utf-8") as f:
        entries = [p for p in json.load(f)["projects"].values() if p["repository"] == repository]
    if len(entries) != 1:
        sys.stderr.write(f"git-sources: {repository} is not one project of {projects_file}\n")
        return 2
    listed = {repository_of(s["repository"]): s for s in entries[0].get("git_sources", [])}
    patched = {repository_of(url) for url in entries[0].get("patched_from", [])}
    try:
        with open(os.path.join(project, "Cargo.lock"), "rb") as f:
            lock = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as error:
        sys.stderr.write(f"git-sources: Cargo.lock does not read: {error}\n")
        return 2

    os.makedirs(work, exist_ok=True)
    environment = git_environment()
    faults = []
    for url, commit in sorted(taken(lock)):
        if url in patched:
            continue
        entry = listed.get(url)
        if entry is None:
            faults.append(f"git-sources: Cargo.lock takes {url} at {commit}, which projects.json's git_sources for {repository} does not list")
            continue
        line = first_parents(url, entry["branch"], work, environment)
        if line is None:
            faults.append(f"git-sources: {url}'s {entry['branch']} does not read, so {commit} is not shown on it")
        elif commit not in line:
            faults.append(f"git-sources: Cargo.lock takes {url} at {commit}, which is not on the first-parent line of its {entry['branch']}")

    warnings = []
    for url, entry in sorted(listed.items()):
        crate, version = entry["awaits"]["crate"], entry["awaits"]["version"]
        answer = published(crate, version)
        if answer:
            warnings.append(f"::warning title=git-sources::{crate} {version} is on crates.io: take it from there, and drop {url} from git_sources")
        elif answer is None:
            warnings.append(f"git-sources: crates.io did not answer for {crate} {version}, which {url}'s entry awaits")

    report(warnings)
    if faults:
        report(faults)
        return 1
    print("git-sources: every git source the lock takes is listed, at a revision on its branch's first-parent line")
    return 0


if __name__ == "__main__":
    sys.exit(main())
