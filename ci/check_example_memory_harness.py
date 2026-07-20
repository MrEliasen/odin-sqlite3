#!/usr/bin/env python3
"""Require every packaged example to run through the fail-closed allocator harness."""

from __future__ import annotations

import os
from pathlib import Path
import re
import sys


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EXAMPLES_ROOT = PROJECT_ROOT / "packaging" / "examples"
SUPPORT_ROOT = EXAMPLES_ROOT / "_support"

ENTRY_POINT_RE = re.compile(
    r"(?ms)^main :: proc\(\) \{\s*"
    r"example_support\.run\(example_main\)\s*"
    r"\}\s*\Z"
)


def main() -> int:
    examples = sorted(EXAMPLES_ROOT.rglob("main.odin"))
    if not examples:
        print(f"error: no examples found below {EXAMPLES_ROOT}", file=sys.stderr)
        return 1

    errors: list[str] = []
    for example in examples:
        source = example.read_text(encoding="utf-8")
        relative = example.relative_to(PROJECT_ROOT)
        support_import = Path(
            os.path.relpath(SUPPORT_ROOT, start=example.parent)
        ).as_posix()
        expected_import = f'import example_support "{support_import}"'

        if expected_import not in source:
            errors.append(f"{relative}: missing `{expected_import}`")
        if len(re.findall(r"(?m)^example_main :: proc\(\) \{", source)) != 1:
            errors.append(f"{relative}: must define exactly one `example_main :: proc()`")
        if len(re.findall(r"(?m)^main :: proc\(\) \{", source)) != 1:
            errors.append(f"{relative}: must define exactly one `main :: proc()`")
        elif ENTRY_POINT_RE.search(source) is None:
            errors.append(
                f"{relative}: main must contain only "
                "`example_support.run(example_main)` and be the final declaration"
            )
        if "Tracking_Allocator" in source or "tracking_allocator" in source:
            errors.append(
                f"{relative}: allocator tracking belongs in the shared example harness"
            )
        if re.search(r"\bos\.exit\s*\(", source):
            errors.append(f"{relative}: `os.exit` would bypass the memory harness")

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    print(
        f"Example memory-harness check passed: {len(examples)} examples use the "
        "fail-closed tracking allocator.",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
