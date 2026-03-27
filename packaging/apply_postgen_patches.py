#!/usr/bin/env python3
"""
Apply deterministic post-generation patches to the generated SQLite raw binding.

This script exists because the current generated output from odin-c-bindgen
still requires a small number of narrowly-scoped corrections before the raw
bindings are acceptable for this project.

It is intentionally conservative:
- it patches only known-bad patterns
- it fails loudly if a required pattern is missing
- it avoids broad rewriting of generated output

Usage:
    python3 packaging/apply_postgen_patches.py

Run this from the project root.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import sys


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_GENERATED = PROJECT_ROOT / "sqlite" / "raw" / "generated" / "sqlite3.odin"
RAW_IMPORTS = PROJECT_ROOT / "sqlite" / "raw" / "imports.odin"


@dataclass
class PatchResult:
    changed: bool
    applied_count: int


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def ensure_file(path: Path) -> None:
    if not path.exists():
        fail(f"required file not found: {path}")


def replace_all_required(text: str, old: str, new: str, description: str) -> tuple[str, int]:
    count = text.count(old)
    if count == 0:
        fail(f"required pattern not found for patch: {description}")
    return text.replace(old, new), count


def replace_one_required(text: str, old: str, new: str, description: str) -> tuple[str, int]:
    count = text.count(old)
    if count == 0:
        fail(f"required pattern not found for patch: {description}")
    if count > 1:
        fail(f"expected exactly one match for patch '{description}', found {count}")
    return text.replace(old, new, 1), 1


def ensure_once(text: str, needle: str, description: str) -> None:
    count = text.count(needle)
    if count != 1:
        fail(f"expected exactly one occurrence of {description}, found {count}")


def patch_imports_file() -> PatchResult:
    ensure_file(RAW_IMPORTS)
    text = RAW_IMPORTS.read_text(encoding="utf-8")
    original = text
    applied = 0

    if not text.startswith("package raw\n"):
        if text.startswith("\n"):
            text = "package raw\n" + text
        elif text.lstrip().startswith("package raw"):
            fail("imports file contains misplaced package declaration")
        else:
            text = "package raw\n\n" + text
        applied += 1

    # Project-specific Darwin linkage for Homebrew SQLite.
    darwin_dynamic_old = 'foreign import sqlite "system:libsqlite3.dylib"'
    darwin_dynamic_new = 'foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"'
    darwin_static_old = 'foreign import sqlite "system:libsqlite3.a"'
    darwin_static_new = 'foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.a"'

    # Replace all matching instances because both system/non-system branches may appear.
    if darwin_dynamic_old in text:
        count = text.count(darwin_dynamic_old)
        text = text.replace(darwin_dynamic_old, darwin_dynamic_new)
        applied += count

    if darwin_static_old in text:
        count = text.count(darwin_static_old)
        text = text.replace(darwin_static_old, darwin_static_new)
        applied += count

    if text != original:
        RAW_IMPORTS.write_text(text, encoding="utf-8")

    ensure_once(text, "package raw\n", "package raw declaration in imports file")
    return PatchResult(changed=text != original, applied_count=applied)


def patch_generated_file() -> PatchResult:
    ensure_file(RAW_GENERATED)
    text = RAW_GENERATED.read_text(encoding="utf-8")
    original = text
    applied = 0

    # 1. Remove duplicate package insertion that can happen when imports_file
    # content is injected after the file's own package declaration.
    duplicate_package_block = 'import "core:c"\n\npackage raw\n\n'
    if duplicate_package_block in text:
        text, count = replace_one_required(
            text,
            duplicate_package_block,
            'import "core:c"\n\n',
            "duplicate package raw block after core:c import",
        )
        applied += count

    # 2. Foreign blocks must target the named sqlite import group.
    if "foreign lib {" in text:
        text, count = replace_all_required(
            text,
            "foreign lib {",
            "foreign sqlite {",
            "foreign lib to foreign sqlite replacement",
        )
        applied += count

    # 3. SQLite destructor sentinels need Odin-compatible definitions.
    if "STATIC      :: ((destructor_type)0)" in text:
        text, count = replace_one_required(
            text,
            "STATIC      :: ((destructor_type)0)",
            "STATIC      : Destructor_Type = nil",
            "SQLITE_STATIC sentinel patch",
        )
        applied += count

    if "TRANSIENT   :: ((destructor_type)-1)" in text:
        text, count = replace_one_required(
            text,
            "TRANSIENT   :: ((destructor_type)-1)",
            "TRANSIENT   : Destructor_Type = transmute(Destructor_Type)(~uintptr(0))",
            "SQLITE_TRANSIENT sentinel patch",
        )
        applied += count

    # 4. Make ownership explicit for sqlite3_expanded_sql.
    if "expanded_sql :: proc(pStmt: ^Stmt) -> cstring ---" in text:
        text, count = replace_one_required(
            text,
            "expanded_sql :: proc(pStmt: ^Stmt) -> cstring ---",
            "expanded_sql :: proc(pStmt: ^Stmt) -> rawptr ---",
            "expanded_sql return type patch",
        )
        applied += count

    # 5. Normalize sqlite3_column_text to cstring for UTF-8 text handling.
    if "column_text    :: proc(_: ^Stmt, iCol: i32) -> ^u8 ---" in text:
        text, count = replace_one_required(
            text,
            "column_text    :: proc(_: ^Stmt, iCol: i32) -> ^u8 ---",
            "column_text    :: proc(_: ^Stmt, iCol: i32) -> cstring ---",
            "column_text return type patch",
        )
        applied += count

    # 6. Ensure column_blob remains rawptr if generation changes later.
    if "column_blob    :: proc(_: ^Stmt, iCol: i32) -> rawptr ---" not in text:
        fail("column_blob rawptr declaration missing or changed unexpectedly")

    # 7. Deduplicate legacy CARRAY constants by renaming the second block.
    carray_legacy_block = (
        "/*\n"
        "** Versions of the above #defines that omit the initial SQLITE_, for\n"
        "** legacy compatibility.\n"
        "*/\n"
        "CARRAY_INT32     :: 0    /* Data is 32-bit signed integers */\n"
        "CARRAY_INT64     :: 1    /* Data is 64-bit signed integers */\n"
        "CARRAY_DOUBLE    :: 2    /* Data is doubles */\n"
        "CARRAY_TEXT      :: 3    /* Data is char* */\n"
        "CARRAY_BLOB      :: 4    /* Data is struct iovec */"
    )
    carray_legacy_replacement = (
        "/*\n"
        "** Versions of the above #defines that omit the initial SQLITE_, for\n"
        "** legacy compatibility.\n"
        "*/\n"
        "CARRAY_INT32_LEGACY     :: 0    /* Data is 32-bit signed integers */\n"
        "CARRAY_INT64_LEGACY     :: 1    /* Data is 64-bit signed integers */\n"
        "CARRAY_DOUBLE_LEGACY    :: 2    /* Data is doubles */\n"
        "CARRAY_TEXT_LEGACY      :: 3    /* Data is char* */\n"
        "CARRAY_BLOB_LEGACY      :: 4    /* Data is struct iovec */"
    )
    if carray_legacy_block in text:
        text, count = replace_one_required(
            text,
            carray_legacy_block,
            carray_legacy_replacement,
            "legacy CARRAY duplicate rename patch",
        )
        applied += count

    # 8. Project-specific Darwin linkage for Homebrew SQLite in generated file too.
    darwin_dynamic_old = 'foreign import sqlite "system:libsqlite3.dylib"'
    darwin_dynamic_new = 'foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"'
    darwin_static_old = 'foreign import sqlite "system:libsqlite3.a"'
    darwin_static_new = 'foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.a"'

    if darwin_dynamic_old in text:
        count = text.count(darwin_dynamic_old)
        text = text.replace(darwin_dynamic_old, darwin_dynamic_new)
        applied += count

    if darwin_static_old in text:
        count = text.count(darwin_static_old)
        text = text.replace(darwin_static_old, darwin_static_new)
        applied += count

    if text != original:
        RAW_GENERATED.write_text(text, encoding="utf-8")

    # Sanity checks after patching.
    if "foreign lib {" in text:
        fail("post-patch verification failed: foreign lib blocks still remain")

    if "STATIC      :: ((destructor_type)0)" in text or "TRANSIENT   :: ((destructor_type)-1)" in text:
        fail("post-patch verification failed: destructor sentinels still in invalid form")

    if "expanded_sql :: proc(pStmt: ^Stmt) -> rawptr ---" not in text:
        fail("post-patch verification failed: expanded_sql is not patched to rawptr")

    if "column_text    :: proc(_: ^Stmt, iCol: i32) -> cstring ---" not in text:
        fail("post-patch verification failed: column_text is not patched to cstring")

    if text.count("CARRAY_INT32     :: 0    /* Data is 32-bit signed integers */") != 1:
        fail("post-patch verification failed: canonical CARRAY_INT32 definition count is not exactly 1")

    if "CARRAY_INT32_LEGACY" not in text:
        fail("post-patch verification failed: legacy CARRAY block was not renamed")

    return PatchResult(changed=text != original, applied_count=applied)


def main() -> int:
    print("Applying post-generation SQLite binding patches...")
    imports_result = patch_imports_file()
    generated_result = patch_generated_file()

    print(
        f"Patched imports: {'yes' if imports_result.changed else 'no'} "
        f"(operations={imports_result.applied_count})"
    )
    print(
        f"Patched generated raw file: {'yes' if generated_result.changed else 'no'} "
        f"(operations={generated_result.applied_count})"
    )
    print("Post-generation patching complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())