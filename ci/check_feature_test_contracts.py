#!/usr/bin/env python3
"""Reject SQLite feature tests that do not declare an immutable contract."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FEATURE_ROOT = ROOT / "tests" / "features"
FEATURE_MATRIX = FEATURE_ROOT / "FEATURE_MATRIX.md"
TEST_DECLARATION = re.compile(r"^\s*(test_[A-Za-z0-9_]+)\s*::\s*proc\b")
CONTRACT_ID_VALUE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
FIELD_PREFIXES = (
    "// SQLITE-FEATURE-CONTRACT:",
    "// Feature:",
    "// SQLite source:",
    "// Requirement:",
    "// Adversarial cases:",
    "// Oracle:",
    "// Guardrail:",
)


def preceding_comment(lines: list[str], declaration_index: int) -> list[str]:
    index = declaration_index - 1
    block: list[str] = []
    while index >= 0 and lines[index].lstrip().startswith("//"):
        block.append(lines[index].strip())
        index -= 1
    block.reverse()
    return block


def validate_contract_block(
    block: list[str], location: str, test_name: str
) -> tuple[str | None, list[str]]:
    errors: list[str] = []
    if not block:
        return None, [f"{location}: {test_name} has no contract comment block"]
    if not block[0].startswith(FIELD_PREFIXES[0]):
        errors.append(
            f"{location}: contract block must begin with {FIELD_PREFIXES[0]}"
        )

    positions: list[int] = []
    values: dict[str, str] = {}
    for prefix in FIELD_PREFIXES:
        matches = [
            (index, line[len(prefix) :].strip())
            for index, line in enumerate(block)
            if line.startswith(prefix)
        ]
        if len(matches) != 1:
            errors.append(
                f"{location}: {test_name} needs exactly one line beginning {prefix}"
            )
            continue
        position, value = matches[0]
        positions.append(position)
        values[prefix] = value
        if not value:
            errors.append(f"{location}: mandatory field {prefix} must not be empty")

    if len(positions) == len(FIELD_PREFIXES) and positions != sorted(positions):
        errors.append(
            f"{location}: mandatory contract fields must appear in methodology order"
        )

    contract_id = values.get(FIELD_PREFIXES[0])
    if contract_id and CONTRACT_ID_VALUE.fullmatch(contract_id) is None:
        errors.append(
            f"{location}: invalid contract id {contract_id!r}; use lowercase letters, "
            "digits, dots, underscores, and hyphens"
        )
        contract_id = None
    return contract_id, errors


def is_registered(test_name: str, package_text: str) -> bool:
    pattern = re.compile(
        rf'\brun_(?:case|contract)\s*\(\s*"[^"]+"\s*,\s*{re.escape(test_name)}\b',
        re.DOTALL,
    )
    return pattern.search(package_text) is not None


def parser_self_test() -> None:
    valid = [f"{prefix} value" for prefix in FIELD_PREFIXES]
    contract_id, errors = validate_contract_block(valid, "self-test:1", "test_valid")
    if errors or contract_id != "value":
        raise RuntimeError(f"contract checker rejected its valid self-test: {errors}")

    malformed = [
        "// SQLITE-FEATURE-CONTRACT: malformed.v1",
        "// Feature: value // SQLite source: value // Requirement: value "
        "// Adversarial cases: value // Oracle: value // Guardrail: value",
    ]
    _, malformed_errors = validate_contract_block(
        malformed, "self-test:2", "test_malformed"
    )
    if not malformed_errors:
        raise RuntimeError("contract checker accepted a collapsed malformed block")

    empty = [f"{prefix} value" for prefix in FIELD_PREFIXES]
    empty[3] = FIELD_PREFIXES[3]
    _, empty_errors = validate_contract_block(empty, "self-test:3", "test_empty")
    if not empty_errors:
        raise RuntimeError("contract checker accepted an empty mandatory field")


def main() -> int:
    parser_self_test()
    errors: list[str] = []
    contract_ids: dict[str, str] = {}
    test_count = 0

    if not FEATURE_ROOT.is_dir():
        print(f"SQLite feature-test root is missing: {FEATURE_ROOT}", file=sys.stderr)
        return 1
    if not FEATURE_MATRIX.is_file():
        print(f"SQLite feature matrix is missing: {FEATURE_MATRIX}", file=sys.stderr)
        return 1
    matrix_text = FEATURE_MATRIX.read_text(encoding="utf-8")

    for path in sorted(FEATURE_ROOT.rglob("*.odin")):
        lines = path.read_text(encoding="utf-8").splitlines()
        relative = path.relative_to(ROOT)
        package_text = "\n".join(
            source.read_text(encoding="utf-8")
            for source in sorted(path.parent.glob("*.odin"))
        )
        for index, line in enumerate(lines):
            match = TEST_DECLARATION.match(line)
            if match is None:
                continue
            test_count += 1
            test_name = match.group(1)
            location = f"{relative}:{index + 1}"
            block = preceding_comment(lines, index)
            contract_id, block_errors = validate_contract_block(
                block, location, test_name
            )
            errors.extend(block_errors)

            if contract_id is not None:
                if contract_id in contract_ids:
                    errors.append(
                        f"{location}: duplicate contract id {contract_id!r}; "
                        f"first used at {contract_ids[contract_id]}"
                    )
                else:
                    contract_ids[contract_id] = location
                if f"`{contract_id}`" not in matrix_text:
                    errors.append(
                        f"{location}: contract id {contract_id!r} is absent from "
                        f"{FEATURE_MATRIX.relative_to(ROOT)}"
                    )

            if not is_registered(test_name, package_text):
                errors.append(
                    f"{location}: {test_name} is declared but not registered with "
                    "run_case/run_contract"
                )

    if test_count == 0:
        errors.append(f"{FEATURE_ROOT.relative_to(ROOT)} contains no feature tests")

    if errors:
        print("SQLite feature-test contract check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        f"SQLite feature-test contracts verified: {test_count} tests, "
        f"{len(contract_ids)} unique contracts."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
