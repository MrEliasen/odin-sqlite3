# odin-sqlite examples

This directory contains small, focused example programs for common `odin-sqlite` usage patterns.

The examples are intentionally split by topic so you can jump directly to the thing you care about instead of reading one large file.

## Start here

If you are new to the package, read these in order:

1. `minimal/main.odin`
2. `crud/create/main.odin`
3. `crud/read/main.odin`
4. `prepared_statements/bind_types/main.odin`
5. `transactions/commit_and_rollback/main.odin`
6. `cache/prepare_cached/main.odin`

That path gives you a good overview of:
- opening a database
- creating schema
- inserting rows
- reading rows
- binding parameters
- reusing statements
- explicit transactions
- cached statements

---

## Example index

### Minimal

- `minimal/main.odin`
  - Smallest practical example
  - Opens an in-memory database
  - Creates a table
  - Inserts rows
  - Runs a prepared query
  - Uses a scalar helper

### CRUD

- `crud/create/main.odin`
  - Create/insert flow
  - Prepared insert statement
  - `db_last_insert_rowid`
  - `db_changes`

- `crud/read/main.odin`
  - Read/select flow
  - Load a row by ID
  - Typed column access
  - Handling “not found”

- `crud/update/main.odin`
  - Update flow
  - Prepared update statement
  - Reading before and after update
  - Observing changed-row counts

- `crud/delete/main.odin`
  - Delete flow
  - Prepared delete statement
  - Verifying deletion
  - Deleting a missing row

### Prepared statements

- `prepared_statements/bind_types/main.odin`
  - Binding multiple parameter types:
    - `text`
    - `i32`
    - `i64`
    - `f64`
    - `bool`
    - `blob`
    - `null`
  - Batch positional binding helpers:
    - `stmt_bind_args(...)`
    - `stmt_bind_args_slice(...)`
  - Batch binding semantics:
    - fewer args than parameters is allowed
    - more args than parameters is an error
    - bindings are not auto-cleared automatically
  - Reading typed results back out

- `prepared_statements/named_parameters/main.odin`
  - Named parameters:
    - `:name`
    - `@name`
    - `$name`
  - Parameter metadata helpers
  - Named binding helpers

- `prepared_statements/reuse/main.odin`
  - Reusing a prepared statement repeatedly
  - `stmt_reuse`
  - `stmt_reset`
  - `stmt_clear_bindings`
  - What survives reset and what does not

### Transactions

- `transactions/commit_and_rollback/main.odin`
  - Explicit `BEGIN`
  - Explicit `BEGIN IMMEDIATE`
  - `COMMIT`
  - `ROLLBACK`
  - Observing results before and after

- `transactions/savepoints/main.odin`
  - `SAVEPOINT`
  - `ROLLBACK TO`
  - `RELEASE`
  - Outer transaction continuing after savepoint rollback

### Cache

- `cache/prepare_cached/main.odin`
  - `db_prepare_cached`
  - Prepare-once, reuse-many pattern
  - Basic cache lifecycle

- `cache/prune_and_clear/main.odin`
  - Cache usage tracking
  - `cache_reset_usage`
  - `cache_prune_unused`
  - `cache_clear`

### Common patterns

- `common_patterns/scalars_and_exists/main.odin`
  - `db_exec_no_rows`
  - `db_scalar_i64`
  - `db_scalar_f64`
  - `db_scalar_text`
  - `db_exists`

- `common_patterns/query_optional/main.odin`
  - `db_query_optional`
  - Handling “no row found” as a normal case
  - Finalizing optional result statements correctly

- `common_patterns/struct_mapping/main.odin`
  - `stmt_scan_struct`
  - Mapping the current row into a struct
  - Exact-name field matching
  - `sqlite:"column_name"` tag overrides
  - Using explicit getters alongside struct mapping

- `common_patterns/struct_queries/main.odin`
  - `db_query_one_struct`
  - `db_query_optional_struct`
  - `db_query_all_struct`
  - Collecting rows into typed structs and slices
  - Using sqlite struct tags with query wrappers

- `common_patterns/ownership_and_cleanup/main.odin`
  - Caller-owned copied text/blob values
  - Cleaning up `stmt_get_text(...)` and `stmt_get_blob(...)` results
  - Cleaning up mapped struct fields from `db_query_one_struct(...)`
  - Cleaning up nested row data from `db_query_all_struct(...)`
  - Releasing the outer returned slice after nested cleanup

- `common_patterns/ownership_and_cleanup/main.odin`
  - Caller-owned copied text/blob values
  - Cleaning up `stmt_get_text(...)` and `stmt_get_blob(...)` results
  - Cleaning up mapped struct fields from `db_query_one_struct(...)`
  - Cleaning up nested row data from `db_query_all_struct(...)`
  - Releasing the outer returned slice after nested cleanup

- `common_patterns/errors/main.odin`
  - Structured error handling
  - `error_summary`
  - `error_string`
  - `error_code_name`
  - Attaching extra context/op information

---

## Notes

### Import path

In this repository, the examples use relative imports so they can be compiled and checked in-place.

When consumed from a packaged release, you will usually import the package like this:

```text
import sqlite "vendor:sqlite"
```

### Style

These examples are intentionally explicit.

They prefer:
- direct statement preparation
- explicit binding
- explicit stepping
- explicit error checks
- explicit transaction boundaries

They do **not** try to hide SQLite behind higher-level abstractions.

### Ownership

Some convenience APIs shown in these examples copy SQLite-managed data into memory allocated with the allocator you pass in.

That means:

- copied `string` and `[]u8` values returned from helper APIs are caller-owned
- copied `string` and `[]u8` values mapped into your structs are also caller-owned
- when you use a non-temporary allocator for that data, you are responsible for releasing it with `delete(...)` when appropriate

This applies to APIs such as:

- `stmt_get_text(...)`
- `stmt_get_blob(...)`
- `db_scalar_text(...)`
- `blob_read_all(...)`
- `stmt_scan_struct(...)` for `string` and `[]u8` fields
- `db_query_one_struct(...)`
- `db_query_optional_struct(...)`
- `db_query_all_struct(...)`

For `db_query_all_struct(...)`, ownership is two-layered:

- the returned slice is owned by you
- any copied `string` / `[]u8` fields inside the returned rows are also owned by you

### Expectation

These examples are meant to be:
- easy to scan
- easy to copy from
- easy to adapt to game/server code
- representative of the actual library surface

If you are working with copied text/blob values or struct-mapped `string` / `[]u8` fields, also read:

- `common_patterns/ownership_and_cleanup/main.odin`

If you are unsure which example to open first, use `minimal/main.odin`, then jump to the specific topic you need.