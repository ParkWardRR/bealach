#!/usr/bin/env python3
"""Check that relative links in Markdown files resolve to real files.

External links (http, https, mailto) and pure-fragment links (#heading) are
ignored: this is a local integrity check, not a network linter.
"""

from __future__ import annotations

import re
import sys
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# [text](target) — good enough for this repository; skips images' ![] noise by
# allowing them (an image link is still a link that must resolve).
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")


def markdown_files() -> list[Path]:
    # harvest/ and contracts/ are provenance-pinned Cairn material: their
    # relative links describe the Cairn monorepo layout and are left untouched.
    skip = {"harvest", "contracts", ".build"}
    return sorted(
        p for p in ROOT.rglob("*.md")
        if ".git" not in p.parts and skip.isdisjoint(p.relative_to(ROOT).parts)
    )


def check_file(path: Path) -> list[str]:
    problems = []
    text = path.read_text(encoding="utf-8")
    for match in LINK.finditer(text):
        raw = match.group(1)
        if raw.startswith(("http://", "https://", "mailto:", "tel:", "data:")):
            continue
        if raw.startswith("#"):
            continue
        target = urllib.parse.unquote(raw.split("#", 1)[0])
        if not target:
            continue
        resolved = (path.parent / target).resolve()
        if not resolved.exists():
            line = text.count("\n", 0, match.start()) + 1
            problems.append(f"{path.relative_to(ROOT)}:{line}: broken link -> {raw}")
    return problems


def main() -> int:
    files = markdown_files()
    problems = [p for f in files for p in check_file(f)]
    if problems:
        print("\n".join(problems))
        print(f"\nlinks: FAIL ({len(problems)} broken in {len(files)} files)")
        return 1
    print(f"links: ok ({len(files)} markdown files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
