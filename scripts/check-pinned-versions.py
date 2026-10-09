#!/usr/bin/env python3
"""Fail when an image or Harbor jar has different tags across tracked files, i.e. a partial bump."""
import re
import subprocess
import sys
from collections import defaultdict

# Names allowed to carry more than one tag on purpose.
ALLOW_MULTIPLE: set[str] = set()

TAG = r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"
# A whole `repo:tag` reference; the lookbehind keeps `//host:port` and `a/b` suffixes out.
REF_RE = re.compile(rf"(?<![A-Za-z0-9._/])([a-z0-9][a-z0-9._/-]*):({TAG})")
IMAGE_FIELD_RE = re.compile(r"""image:\s*["']?$""")


def normalize(repo: str) -> tuple[str, bool, bool]:
    """Return (name, is_jar, qualified), stripping the registry host, `library/` and `jars/`."""
    parts = repo.split("/")
    qualified = len(parts) > 1
    if qualified and ("." in parts[0] or parts[0] == "localhost"):
        parts = parts[1:]
    if len(parts) > 1 and parts[0] in ("library", "jars"):
        return "/".join(parts[1:]), parts[0] == "jars", True
    return "/".join(parts), False, qualified


def main() -> int:
    files = subprocess.run(["git", "ls-files", "-z"], check=True, capture_output=True, text=True).stdout.split("\0")
    refs = []
    for path in filter(None, files):
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        for m in REF_RE.finditer(text):
            name, is_jar, qualified = normalize(m[1])
            in_field = bool(IMAGE_FIELD_RE.search(text, max(0, m.start() - 20), m.start()))
            line = text.count("\n", 0, m.start()) + 1
            refs.append((name, m[2], f"{path}:{line}", is_jar, in_field, qualified))

    images = {r[0] for r in refs if r[4] and not r[3]}
    jars = {r[0] for r in refs if r[3]}

    # A bare name (postgres:5432) may be a Service host, so it counts only in `image:` or qualified.
    found = defaultdict(lambda: defaultdict(list))
    for name, tag, loc, _, in_field, qualified in refs:
        if name in jars or (name in images and (in_field or qualified)):
            found[name][tag].append(loc)

    failed = False
    for name in sorted(found):
        tags = found[name]
        if len(tags) > 1 and name not in ALLOW_MULTIPLE:
            failed = True
            print(f"{name} is pinned to {len(tags)} tags:")
            for tag in sorted(tags):
                for loc in tags[tag]:
                    print(f"  {tag:<12} {loc}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
