# odin-sqlite — Project Notes

This document is for **project-internal status, development notes, implementation details, and maintenance guidance**.

The main `README.md` should stay focused on:

- what the package is
- how to use it
- how to build/test it
- where to find examples

This file is the place for:

- implementation status
- project structure notes
- development workflow notes
- ownership/lifetime policy notes
- additive feature notes beyond the original v1 boundary
- maintenance caveats

---

# Project summary

`odin-sqlite` is a thin SQLite binding for Odin built in two layers:

1. a generated raw binding layer from `sqlite3.h`
2. a small handwritten wrapper layer on top

The package is designed around explicit SQLite behavior, predictable statement reuse, explicit transactions, and operational control suitable for server-side usage.

The wrapper is intentionally **not** an ORM.

---

# Current implementation status

## Priority status

- **P0**: completed
- **P1**: implemented and tested for the current intended surface
- **P2**: intentionally skipped for now
- **P3**:
  - reflection-based row mapping: implemented as an additive convenience layer
  - struct-tag-based row mapping: implemented as an additive convenience layer
  - regex/tag-driven extraction: still skipped
  - ORM/query-builder/schema-abstraction work: still intentionally not pursued

## Implemented and tested areas

The current codebase includes:

- raw generated bindings under `sqlite/raw/generated`
- connection lifecycle
- statement lifecycle
- typed parameter binding
- batch positional bind helpers
- typed column readers
- execution helpers
- transactions and savepoints
- scalar/query convenience helpers
- statement reuse/cache
- operational helpers
- structured error model
- tracing/debug helpers
- incremental blob API
- backup API
- reflection-based row mapping
- struct-tag-based row mapping
- struct query convenience wrappers
- ownership and cleanup guidance for caller-owned copied values

The smoke suite currently passes functionally.

---

# Project layout

```text
sqlite/
  raw/
    generated/          # generated raw SQLite bindings
    imports.odin        # foreign import configuration
  *.odin                # handwritten wrapper layer

tests/
  *.odin                # smoke tests

packaging/
  apply_postgen_patches.py
  examples/
```

Additional top-level documents:

- `IMPLEMENTATION_SPEC.md`
- `PRIORITIES.md`
- `POSTGEN_PATCH_SPEC.md`
- `PROJECT.md` (this file)

---

# Design principles

This project intentionally prefers:

- explicit statement lifecycle
- explicit binding and stepping
- explicit transaction boundaries
- predictable statement reuse
- low abstraction overhead
- clear ownership/lifetime behavior

This project intentionally did **not** start with:

- ORM behavior
- schema DSLs
- query builders
- regex/tag-driven mapping

The project now includes an additive row-mapping layer on top of the explicit statement API, but that should still be treated as optional convenience rather than a replacement for explicit SQLite usage.

---

# Additive mapping layer

## Implemented mapping APIs

The current additive mapping surface includes:

- `stmt_scan_struct(...)`
- `db_query_one_struct(...)`
- `db_query_optional_struct(...)`
- `db_query_all_struct(...)`

## Implemented mapping behavior

Current mapping behavior includes:

- reflection-based mapping from the current row into a struct
- struct-tag-based remapping with `sqlite:"column_name"`
- exact column-name matching by default
- support for the current explicit wrapper value types:
  - integers
  - floats
  - bool
  - string
  - `[]u8`

## Constraints of the mapping layer

The mapping layer remains intentionally constrained:

- explicit typed getters remain available and first-class
- mapping is additive, not mandatory
- mapping does not make the wrapper an ORM
- mapping does not change statement/transaction semantics
- mapping does not infer SQL shape beyond direct column-to-field assignment

---

# Batch positional binding

The wrapper now includes positional batch binding helpers:

- `stmt_bind_args(...)`
- `stmt_bind_args_slice(...)`

Their semantics are:

- fewer args than parameters is allowed
- more args than parameters is an error
- bindings are not auto-cleared automatically

These helpers are intentionally thin wrappers over the existing typed bind machinery.

---

# Ownership and lifetime policy

## Core rule

If an API copies SQLite-managed data into memory using a caller-provided allocator, that copied memory is **caller-owned**.

That is the intended model.

## APIs that currently allocate caller-owned data

This applies to APIs such as:

- `stmt_get_text(...)`
- `stmt_get_blob(...)`
- `db_scalar_text(...)`
- `blob_read_all(...)`
- `stmt_scan_struct(...)` for `string` and `[]u8` fields
- `db_query_one_struct(...)`
- `db_query_optional_struct(...)`
- `db_query_all_struct(...)`

## Important implications

### Single values
If an API returns copied text/blob data using a non-temporary allocator:

- the caller owns that returned value
- the caller should release it with `delete(...)` when appropriate

### Struct mapping
If struct mapping writes copied `string` or `[]u8` values into a destination struct:

- that copied memory is owned by the caller through the destination struct

### Query-all mapping
For `db_query_all_struct(...)`, ownership is two-layered:

- the outer returned slice is caller-owned
- copied nested `string` / `[]u8` fields inside returned rows are also caller-owned

If using a non-temporary allocator, callers must release:

1. nested owned field data
2. then the outer slice

## Documentation/examples status

Ownership guidance has been added to:

- API comments for the allocating helper surface
- `README.md`
- `packaging/examples/README.md`

Focused examples now exist for:

- struct mapping
- struct query wrappers
- ownership and cleanup

---

# Raw binding generation workflow

## Supported workflow

The intended regeneration workflow is:

```text
make download-sqlite
make bindgen
make regenerate
make test
```

Where:

- `make download-sqlite` downloads `sqlite3.h`
- `make bindgen` builds `odin-c-bindgen` into `deps/bin`
- `make generate` regenerates raw bindings
- `make postgen-patch` applies deterministic corrections required by the current generator/toolchain behavior
- `make regenerate` runs `generate` + `postgen-patch`

For normal regeneration, prefer:

```text
make regenerate
```

Not `make generate` by itself.

## Why `make regenerate` exists

The generated raw layer is close to the SQLite C API, but the current generation pipeline still needs deterministic post-generation correction for known issues.

These corrections are automated via:

- `packaging/apply_postgen_patches.py`

So the intended regeneration pipeline is:

```text
generate -> postgen patch -> compile -> run smoke tests
```

This keeps the workflow reproducible while remaining generator/raw-output issues are still being handled outside pure bindgen configuration.

## Current raw-generation reality

Today, the project is stable and tested, but the raw generation path still relies on automated post-processing.

In practice, this means:

- the wrapper and tests are in good shape
- the generated raw layer is usable
- regeneration is reproducible
- regeneration is not yet purely “generate and done”

If you are working on the raw layer, treat `make regenerate` as the canonical path.

---

# Packaging

To create a package directory:

```text
make package-dir
```

To create a zip package:

```text
make package-zip
```

The output is written under:

```text
out/
```

See also:

- `packaging/README.package.md`

---

# Tracing notes

The current tracing/debugging surface includes:

- `stmt_expanded_sql(...)`
- `db_trace_enable(...)`
- `db_trace_disable(...)`
- helper logging functions for statement/profile/row/close events

The current tracing surface is deliberate and stable.

Callback-driven trace dispatch was explored and intentionally deferred to keep the wrapper thin and reliable.

---

# Blob and backup notes

P1 also includes thin wrappers for:

- incremental blob I/O
- online backup flows

These stay close to SQLite’s own API shape rather than trying to hide it behind large abstractions.

---

# What is intentionally not next

The project is not currently pursuing:

- ORM features
- query builders
- schema DSLs
- regex/tag-driven extraction
- advanced abstraction layers around SQL shape
- P2 subsystems unless a real need appears

---

# Test and diagnostics notes

## Functional test status

The functional smoke suite currently passes.

## Allocator tracker status

The allocator tracker has surfaced real outstanding allocations.

Known leak buckets currently include allocations attributable to:

- copied blob/text result usage in tests that are not always explicitly cleaned up
- expanded SQL strings not always explicitly deleted
- file-read buffers in tests
- temporary DB path strings in test helpers
- at least one cache-related allocation path
- some secondary OS/path/env allocations that may reduce after direct user-owned values are cleaned up

This means:

- functional behavior is currently passing
- memory ownership rules are now documented
- there is still cleanup work to do in tests and possibly in some helper paths

This should be treated as an active maintenance task rather than a completed area.

---

# Recommended way to work on this repo

If you are making changes:

1. change wrapper code conservatively
2. preserve explicit SQLite semantics
3. treat tests as the contract
4. run the smoke suite
5. prefer fixing code to match expected behavior rather than weakening tests

For ownership-sensitive work:

1. decide whether the API returns caller-owned copied data
2. document that explicitly
3. add or update examples that demonstrate correct cleanup
4. run with allocation tracking where possible

For raw binding work:

1. prefer regeneration over hand edits
2. keep generated output separate from handwritten wrapper logic
3. treat post-generation patching as deterministic infrastructure, not ad hoc editing

---

# Related documents

For authoritative planning/spec context, see:

- `IMPLEMENTATION_SPEC.md`
- `PRIORITIES.md`

For user-focused usage and examples, see:

- `README.md`
- `packaging/examples/README.md`
- `packaging/examples/common_patterns/ownership_and_cleanup/main.odin`
