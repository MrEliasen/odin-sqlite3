# Post-Generation Patch Spec for `sqlite/raw/generated/sqlite3.odin`

This document defines the required post-generation corrections that must be applied after regenerating the raw SQLite bindings from `input/sqlite3.h`.

It exists because the current generated output is not yet fully acceptable as-is for this project.

The goal is:

1. keep the generated layer as close to `sqlite3.h` as possible
2. keep manual intervention narrowly scoped
3. make post-generation corrections deterministic
4. ensure the handwritten wrapper layer and tests are not forced to work around broken raw bindings unnecessarily

This document is intended both for humans and for LLM/codegen agents.

---

# Scope

This spec applies only to:

- `sqlite/raw/generated/sqlite3.odin`

and, where noted, also to:

- `sqlite/raw/imports.odin`

This spec does **not** authorize broad rewriting of the generated file.

It authorizes only the minimal edits described below.

---

# General rules

## Rule 1

Do not hand-rewrite unrelated parts of the generated bindings.

## Rule 2

Only patch the specific known-bad output patterns described here.

## Rule 3

If regeneration changes line numbers or nearby formatting, patch by matching symbols/text patterns, not by assuming exact line numbers.

## Rule 4

If a new generator version fixes one of these problems upstream, remove that patch from the post-gen workflow rather than preserving unnecessary manual edits.

## Rule 5

Do not change wrapper code or tests to compensate for a raw binding issue if the raw binding can be fixed safely here.

## Rule 6

The automated post-generation patch workflow is the standard regeneration path for this project. Treat:

1. generate
2. apply post-generation patches
3. compile-check
4. run smoke tests

as a single required sequence.

---

# Current known generator issues

The current generation flow has been observed to produce these issues:

1. `sqlite3_expanded_sql` ownership/type is not represented clearly enough in generated output
2. foreign blocks are emitted as `foreign lib { ... }` instead of the form this project/toolchain accepts
3. destructor sentinel constants are emitted in invalid Odin syntax
4. duplicate `CARRAY_*` constants are emitted twice
5. macOS library import behavior requires explicit project-specific import handling
6. generated platform import content may duplicate or bypass intended `imports_file` behavior
7. generated file content may reintroduce a duplicate `package raw` block when `imports_file` content is injected

These problems are narrow and should be patched narrowly.

---

# Automated workflow

## Standard workflow

Use the Makefile workflow:

```text
make regenerate
```

This is expected to perform:

```text
make generate
make postgen-patch
```

The automated patch script is:

- `packaging/apply_postgen_patches.py`

## Expectations of the patch script

The patch script must:

- patch only known-bad patterns
- fail loudly if required patterns are missing
- verify critical post-patch invariants
- remain deterministic and conservative

This document describes the expected behavior of that script.

---

# Required patches

## Patch 1 — Use the correct foreign import group name

### Problem

The generated file emits foreign blocks like:

```text
foreign lib {
```

In this project/toolchain setup, these must bind against the named foreign import:

```text
foreign sqlite {
```

### Required action

Replace every occurrence of:

```text
foreign lib {
```

with:

```text
foreign sqlite {
```

### Notes

- This is required throughout the generated file
- Do not rename the actual imported library symbol from `sqlite`
- Only change the foreign block target name

### Acceptance criteria

- No `foreign lib {` remains in `sqlite/raw/generated/sqlite3.odin`
- All raw procs are declared inside `foreign sqlite { ... }` blocks

---

## Patch 2 — Fix destructor sentinel constants

### Problem

The generator currently emits invalid Odin syntax for SQLite destructor sentinels, typically in the form:

```text
Destructor_Type :: proc "c" (rawptr)

STATIC      :: ((destructor_type)0)
TRANSIENT   :: ((destructor_type)-1)
```

This is not acceptable Odin code.

### Required action

Replace that emitted section with Odin-compatible definitions.

### Required target form

Use:

```text
Destructor_Type :: proc "c" (rawptr)

STATIC      : Destructor_Type = nil
TRANSIENT   : Destructor_Type = transmute(Destructor_Type)uintptr(1)
```

### Important note

This is a project compatibility patch.

SQLite uses sentinel destructor values in C:
- `SQLITE_STATIC`
- `SQLITE_TRANSIENT`

The raw bindings must expose usable equivalents for wrapper code.

### Acceptance criteria

- The raw file compiles
- Wrapper bind code can pass `raw.STATIC` and `raw.TRANSIENT`

---

## Patch 3 — Deduplicate legacy `CARRAY_*` constants

### Problem

The generator emits the `CARRAY_*` constants twice.

Observed pattern:

First block:

```text
CARRAY_INT32     :: 0
CARRAY_INT64     :: 1
CARRAY_DOUBLE    :: 2
CARRAY_TEXT      :: 3
CARRAY_BLOB      :: 4
```

Then a second “legacy compatibility” block repeats the same names again, causing redeclaration errors.

### Required action

Do not leave both blocks with the same names.

### Approved fix

Rename the second legacy compatibility block to distinct names:

```text
CARRAY_INT32_LEGACY
CARRAY_INT64_LEGACY
CARRAY_DOUBLE_LEGACY
CARRAY_TEXT_LEGACY
CARRAY_BLOB_LEGACY
```

### Notes

- Only rename the second duplicated block
- Leave the first canonical block unchanged

### Acceptance criteria

- No `CARRAY_*` redeclaration errors remain
- The primary canonical constants keep their original names

---

## Patch 4 — Correct `sqlite3_expanded_sql` raw signature semantics

### Problem

In `sqlite3.h`, the function is declared as:

```text
char *sqlite3_expanded_sql(sqlite3_stmt *pStmt);
```

This returned pointer:
- is heap-allocated by SQLite
- must be freed by the caller using `sqlite3_free()`

The generator currently emits it as plain `cstring`, which obscures ownership.

### Required action

Override the generated declaration for `expanded_sql` so the raw binding makes ownership explicit.

### Required target form

Prefer:

```text
expanded_sql :: proc(pStmt: ^Stmt) -> rawptr ---
```

### Rationale

`rawptr` is preferred here because:
- it avoids pretending the result is an ordinary borrowed string
- it forces wrapper code to explicitly convert and free the memory
- it better reflects SQLite’s ownership rules

### Wrapper expectation

The wrapper layer is expected to:
1. check for `nil`
2. convert to C string form
3. clone into Odin-managed memory
4. free the SQLite-owned pointer with `raw.free(...)`

### Important status note

The wrapper-side lifetime bug for `stmt_expanded_sql` has been resolved.

The important remaining requirement of this patch is still:
- make ownership explicit in the raw layer

### Acceptance criteria

- `expanded_sql` no longer returns plain `cstring`
- wrapper code can safely convert, clone, and free the result
- smoke tests can assert on expanded SQL content

---

## Patch 5 — Prefer a stable UTF-8 text type for `sqlite3_column_text`

### Problem

In `sqlite3.h`, the function is:

```text
const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
```

The generator currently emits:

```text
column_text :: proc(_: ^Stmt, iCol: i32) -> ^u8 ---
```

This is not strictly wrong, but it is less ergonomic and less intention-revealing for UTF-8 text handling.

### Required action

Normalize the raw binding to:

```text
column_text :: proc(_: ^Stmt, iCol: i32) -> cstring ---
```

### Notes

- `column_blob` should remain `rawptr`
- `column_text16` should remain `rawptr`
- This change is specifically for the UTF-8 text-returning function

### Acceptance criteria

- `column_text` returns `cstring`
- wrapper text extraction logic can use this directly

---

## Patch 6 — Ensure `column_blob` remains raw pointer-like

### Problem

`sqlite3_column_blob` is:

```text
const void *sqlite3_column_blob(sqlite3_stmt*, int iCol);
```

This should remain represented as a raw pointer-like type.

### Required action

Ensure the declaration is:

```text
column_blob :: proc(_: ^Stmt, iCol: i32) -> rawptr ---
```

### Acceptance criteria

- `column_blob` is not converted to `cstring`
- blob access remains byte-count-driven via `column_bytes`

---

## Patch 7 — Ensure `sqlite/raw/imports.odin` declares the correct package

### Problem

The imports file must belong to package `raw`.

### Required action

At the top of `sqlite/raw/imports.odin`, ensure:

```text
package raw
```

exists exactly once at the top.

### Acceptance criteria

- `sqlite/raw/imports.odin` starts with `package raw`
- it can be included into generated raw bindings without package mismatch

---

## Patch 8 — macOS SQLite import must match the project environment

### Problem

On macOS in this project, SQLite is installed via Homebrew and the default generated import behavior has not been sufficient in practice.

### Required action

For Darwin handling in the raw import logic, ensure the project uses the intended import path format for the local environment.

### Current project-specific expected form

For both relevant Darwin branches in this project, use:

```text
foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"
```

and for static:

```text
foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.a"
```

### Important note

This is a project-environment patch, not a universal SQLite rule.

If project packaging later switches to a more portable approach, this section may need revision.

### Acceptance criteria

- the tests link and run on the target macOS/Homebrew environment
- raw linkage does not fall back to unresolved `libsqlite3.dylib` behavior

---

## Patch 9 — Remove duplicate `package raw` injection in generated file

### Problem

After regeneration, the generated file may contain a duplicate `package raw` block because `imports_file` content is injected in a way that duplicates package declaration content.

### Required action

Ensure the generated file contains exactly one `package raw` declaration.

A common broken pattern is:

```text
package raw

import "core:c"

package raw
```

This must be normalized to:

```text
package raw

import "core:c"
```

### Acceptance criteria

- `sqlite/raw/generated/sqlite3.odin` contains exactly one `package raw` declaration
- the generated raw file parses correctly

---

# Patches that are preferred in config, but currently must still be verified after generation

The following were attempted via `bindgen.sjson` using `procedure_type_overrides`:

- `expanded_sql = rawptr`
- `column_blob = rawptr`
- `column_text = cstring`

However, after regeneration, those overrides did **not** reliably appear in the generated output.

Therefore:

- keep those config entries in `bindgen.sjson`
- but still verify and patch the generated file after regeneration if needed

This means the current workflow is:

1. regenerate
2. apply automated post-generation patching
3. compile-check
4. run smoke tests

---

# Post-generation checklist

After running generation, perform this checklist in order.

## Checklist

### 1. Verify the file exists
- `sqlite/raw/generated/sqlite3.odin`

### 2. Verify foreign block target
- replace every `foreign lib {` with `foreign sqlite {`

### 3. Verify destructor sentinels
- patch `STATIC`
- patch `TRANSIENT`

### 4. Verify duplicated `CARRAY_*`
- rename the second block to `*_LEGACY`

### 5. Verify `expanded_sql`
- ensure it returns `rawptr`

### 6. Verify `column_text`
- ensure it returns `cstring`

### 7. Verify `column_blob`
- ensure it returns `rawptr`

### 8. Verify imports file package
- `sqlite/raw/imports.odin` begins with `package raw`

### 9. Verify macOS imports
- ensure Darwin import branches use the project-required Homebrew/system import format

### 10. Verify generated file package declaration
- `sqlite/raw/generated/sqlite3.odin` contains exactly one `package raw`

### 11. Compile-check raw + wrapper
- raw layer should compile
- wrapper layer should compile against patched raw layer

### 12. Run smoke tests
- use smoke tests as behavioral validation
- do not weaken tests to fit an obviously broken raw binding

---

# Explicit non-goals of post-gen patching

The post-gen patch phase must **not** do any of the following:

- rewrite the raw file into a wrapper API
- reorder declarations just for style
- rename broad swaths of generated API
- handwrite the entire raw SQLite surface
- change unrelated generated enums/structs without evidence
- weaken ownership semantics for convenience
- patch wrappers/tests to hide raw binding bugs

---

# Relationship to wrapper layer

The wrapper layer may assume these post-gen guarantees:

1. `expanded_sql` returns owned memory that the wrapper must free after cloning
2. `column_text` is exposed as UTF-8 string pointer semantics
3. `column_blob` is exposed as opaque raw bytes pointer semantics
4. `STATIC` and `TRANSIENT` are usable
5. raw foreign procs are bound through the `sqlite` foreign import group
6. the raw generated file belongs to package `raw` cleanly

If these guarantees are not true, fix the raw layer first.

---

# Relationship to tests

Tests are the acceptance gate.

If a smoke test reveals:
- invalid text decoding
- broken expanded SQL handling
- cache misuse after bind/reset
- bad statement reuse semantics

then:

1. first inspect wrapper logic
2. if the wrapper looks sound, inspect raw signature correctness
3. if the raw signature is misleading or ownership is obscured, fix the post-gen patch layer
4. do not immediately weaken tests unless the test assumption is disproven by actual SQLite runtime behavior

---

# Status of `expanded_sql`

The wrapper-side `expanded_sql` lifetime bug is resolved.

Specifically:
- the wrapper now clones the returned C string before freeing the SQLite-owned memory
- full `expanded_sql` content assertions are enabled in the smoke suite and pass

The remaining concern is generation quality:
- the raw layer still needs post-generation correction so the ownership semantics are explicit and reproducible after regeneration

So `expanded_sql` is no longer a temporary test exception, but it is still part of the required post-generation patch workflow.

---

# Suggested future improvement

If generator behavior can be fixed upstream or via project automation improvements, the preferred long-term solution is:

1. keep `bindgen.sjson` minimal but sufficient
2. reduce post-gen patching to the smallest possible scripted step
3. eliminate manual edits where generator correctness can be improved

Until then, this file is the authoritative spec for required post-generation correction.

---

# Final instruction to implementers

Treat this file as operational source of truth for post-generation raw binding correction.

Do not improvise broad edits.

Patch only what is known to be broken.

Then let wrapper compilation and P0 tests determine the next required correction.