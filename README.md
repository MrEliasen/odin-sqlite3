# odin-sqlite

Thin SQLite bindings for Odin.

`odin-sqlite` is designed as:

1. a generated raw binding layer from `sqlite3.h`
2. a small "handwritten" wrapper layer on top
3. a practical, explicit API for normal SQLite usage in Odin

The design goal is not to build an ORM. The wrapper stays close to SQLite's actual execution model and is optimized first for predictable server-side usage.

## LLM Disclaimer

I normally hand roll my code, and I started down the path with sqlite3 bindings as well, but I thought why not actually give the LLMs a proper shot at something where I can very strictly define the scope.

This is the result, a probably ~90~95% LLM generate SQLite3 bindings for Odin. It does not cover everything, but it should pretty much cover more than what most people use.
I did have to sort out a fair few memory issues manually, but other than that, the LLM's did the rest. The markdown files which summarise what is done, the spec etc is in the `llm-docs` branch.

## What you get

The current user-facing surface includes:

- database open/close helpers
- statement prepare/step/reset/finalize helpers
- typed parameter binding
- batch positional bind helpers
- typed column readers
- transaction and savepoint helpers
- scalar/query convenience helpers
- statement reuse/cache helpers
- tracing/debug helpers
- incremental blob API
- backup API
- reflection-based row mapping
- struct-tag-based row mapping
- struct query convenience wrappers

## Quick start

If you are new to the package:

1. read the minimal example below
2. browse `packaging/examples/README.md`
3. run all the tests with `make test`

## Build and test

Run the wrapper checks, example checks and smoke tests:

```text
make test
```

That runs the project checks and the smoke suite. The smoke suite uses a
tracking allocator and exits non-zero on any leaked allocation or bad free, so
`make test` doubles as a memory-safety gate.

## Install / package notes

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

## Examples

The packaged examples live under:

- `packaging/examples/`

Start with:

- `packaging/examples/README.md`

Useful examples include:

- `packaging/examples/minimal/main.odin`
- `packaging/examples/prepared_statements/bind_types/main.odin`
- `packaging/examples/common_patterns/query_optional/main.odin`
- `packaging/examples/common_patterns/struct_mapping/main.odin`
- `packaging/examples/common_patterns/struct_queries/main.odin`
- `packaging/examples/common_patterns/ownership_and_cleanup/main.odin`
- `packaging/examples/transactions/commit_and_rollback/main.odin`
- `packaging/examples/common_patterns/errors/main.odin`

## Minimal example

```text
package main

import "core:fmt"
import sqlite "../sqlite"

main :: proc() {
	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println(sqlite.error_string(err))
		sqlite.error_destroy(&err)
		return
	}
	defer sqlite.db_close(&db)

	_, _ = sqlite.db_exec(db, "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	_, _ = sqlite.db_exec(db, "INSERT INTO items(name) VALUES ('alpha'), ('beta')")

	value, scalar_err, scalar_ok := sqlite.db_scalar_text(
		db,
		"SELECT name FROM items WHERE id = 1",
	)
	if !scalar_ok {
		fmt.println(sqlite.error_string(scalar_err))
		sqlite.error_destroy(&scalar_err)
		return
	}
	defer delete(value)

	fmt.println(value)
}
```

## Statement-oriented example

```text
package main

import "core:fmt"
import sqlite "../sqlite"

main :: proc() {
	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println(sqlite.error_string(err))
		sqlite.error_destroy(&err)
		return
	}
	defer sqlite.db_close(&db)

	_, _ = sqlite.db_exec(db, "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	_, _ = sqlite.db_exec(db, "INSERT INTO users(name) VALUES ('alice'), ('bob')")

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(db, "SELECT name FROM users WHERE id = ?1")
	if !prep_ok {
		fmt.println(sqlite.error_string(prep_err))
		sqlite.error_destroy(&prep_err)
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	bind_err, bind_ok := sqlite.stmt_bind_i64(&stmt, 1, 2)
	if !bind_ok {
		fmt.println(sqlite.error_string(bind_err))
		sqlite.error_destroy(&bind_err)
		return
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println(sqlite.error_string(step_err))
		sqlite.error_destroy(&step_err)
		return
	}
	if !has_row {
		fmt.println("no row")
		return
	}

	name := sqlite.stmt_get_text(stmt, 0)
	defer delete(name)

	fmt.println(name)
}
```

## Batch positional binding

The wrapper includes positional batch bind helpers:

- `stmt_bind_args(...)`
- `stmt_bind_args_slice(...)`

Their semantics are:

- fewer args than parameters is allowed
- more args than parameters is an error
- bindings are not auto-cleared automatically; the per-slot copy stored by the
  wrapper is freed on rebind, reset+clear_bindings, or finalize

Example:

```text
package main

import "core:fmt"
import sqlite "../sqlite"

main :: proc() {
	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println(sqlite.error_string(err))
		sqlite.error_destroy(&err)
		return
	}
	defer sqlite.db_close(&db)

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(db, "SELECT ?1, ?2, ?3")
	if !prep_ok {
		fmt.println(sqlite.error_string(prep_err))
		sqlite.error_destroy(&prep_err)
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	bind_err, bind_ok := sqlite.stmt_bind_args(
		&stmt,
		sqlite.bind_arg_i64(42),
		sqlite.bind_arg_text("alice"),
		sqlite.bind_arg_bool(true),
	)
	if !bind_ok {
		fmt.println(sqlite.error_string(bind_err))
		sqlite.error_destroy(&bind_err)
		return
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok || !has_row {
		fmt.println(sqlite.error_string(step_err))
		sqlite.error_destroy(&step_err)
		return
	}

	text_value := sqlite.stmt_get_text(stmt, 1)
	defer delete(text_value)

	fmt.printf(
		"values -> %d %q %v\n",
		sqlite.stmt_get_i64(stmt, 0),
		text_value,
		sqlite.stmt_get_bool(stmt, 2),
	)
}
```

## Struct mapping

The package now includes additive struct-mapping helpers such as:

- `stmt_scan_struct(...)`
- `db_query_one_struct(...)`
- `db_query_optional_struct(...)`
- `db_query_all_struct(...)`

These helpers are convenience layers on top of the explicit statement API.

Capabilities:

- exact column-name matching, with optional `sqlite:"column_name"` tag overrides
- `using inner: Inner_Struct` (embedded) fields are walked recursively
- integer narrowing (`i64` → `i8`/`i16`/`i32`/`u8`/`u16`/`u32`) is range-checked
  and out-of-range or negative-into-unsigned reads return `SQLITE_MISMATCH`
- on a scan error mid-struct, any field memory already copied is freed before
  the proc returns

Example:

```text
package main

import "core:fmt"
import sqlite "../sqlite"

User_Row :: struct {
	id:           i64,
	display_name: string `sqlite:"user_name"`,
	is_admin:     bool,
}

main :: proc() {
	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println(sqlite.error_string(err))
		sqlite.error_destroy(&err)
		return
	}
	defer sqlite.db_close(&db)

	_, _ = sqlite.db_exec(db, "CREATE TABLE users(id INTEGER PRIMARY KEY, user_name TEXT NOT NULL, is_admin INTEGER NOT NULL)")
	_, _ = sqlite.db_exec(db, "INSERT INTO users(user_name, is_admin) VALUES ('alice', 1), ('bob', 0)")

	row := User_Row{}
	query_err, query_ok := sqlite.db_query_one_struct(
		db,
		"SELECT id, user_name, is_admin FROM users ORDER BY id LIMIT 1",
		&row,
	)
	if !query_ok {
		fmt.println(sqlite.error_string(query_err))
		sqlite.error_destroy(&query_err)
		return
	}
	defer delete(row.display_name)

	fmt.printf(
		"user -> {id=%d display_name=%q is_admin=%v}\n",
		row.id,
		row.display_name,
		row.is_admin,
	)
}
```

## Error contract

`Error` is a value type. It carries owned copies of its `message`, `sql`,
`ctx`, and `op` strings.

Ownership rules:

- a successful call (`ok == true`) returns `error_none()` — all string fields
  are empty, no allocation happened, and no destroy is required
- a failing call (`ok == false`) returns an `Error` that owns its strings;
  release them with `sqlite.error_destroy(&err)` when you are done
- `error_with_op(&err, "...")`, `error_with_context(&err, "...")`, and
  `error_with_sql(&err, "...")` mutate `err` in place and free any previous
  value of the field they set — they are pointer-taking on purpose so the
  ownership chain stays linear
- `error_make(code, message)` is the safe constructor for user-built Errors;
  do not use `Error{message = "literal"}` because `error_destroy` would try to
  free a string literal

`error_string(err)` and `error_summary(err)` allocate via
`context.temp_allocator` and return a borrowed view that is valid until the
next temp-allocator reset. Clone with `strings.clone` if you need to retain
the formatted string.

Typical failure pattern in application code:

```text
err, ok := sqlite.db_exec(db, sql)
if !ok {
	fmt.println(sqlite.error_string(err))
	sqlite.error_destroy(&err)
	return
}
```

## Savepoint identifier validation

`db_savepoint`, `db_release`, and `db_rollback_to` validate the supplied name
against `[A-Za-z_][A-Za-z0-9_]*`. Names containing quotes, semicolons, or any
other punctuation are rejected with `SQLITE_MISUSE` — SQLite has no parameter
binding for SAVEPOINT names so the wrapper refuses to splice arbitrary input
into the SQL string.

## Cache contract

`db_prepare_cached` requires a non-nil `^Stmt_Cache`. If you do not want a
cache, call `stmt_prepare` directly and manage the lifetime yourself.

`cache_put(&cache, &stmt)` consumes the caller's `Stmt` value (it is zeroed
after the call). The cache now owns the handle, the cloned SQL string, and
any bound-storage allocations. Do not finalize the original `stmt` afterwards.

`cache_clear` / `cache_destroy` / `cache_prune_unused` finalize the cached
statements they remove. `db_prepare_cached` returns a pointer to a
cache-owned `Stmt` — do not call `stmt_finalize` on it directly.

## Ownership notes

Some convenience APIs copy SQLite-managed data into caller-owned memory using
the allocator you pass in.

That means:

- copied `string` and `[]u8` values returned from helper APIs are caller-owned
- copied `string` and `[]u8` values mapped into your structs are also caller-owned
- when you use a non-temporary allocator for that data, you are responsible
  for releasing it with `delete(...)` when appropriate

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
- any copied `string` / `[]u8` fields inside the returned rows are also owned
  by you
- on an error mid-iteration, the wrapper frees every already-appended row's
  copied fields and the dynamic array before returning; the caller does not
  need to clean up partial state

If you want a focused usage example for this, read:

- `packaging/examples/common_patterns/ownership_and_cleanup/main.odin`

## Borrowed-vs-owned strings

A few wrapper procs return strings that **borrow** SQLite-managed memory.
These are documented inline at the call site. The notable ones:

- `db_errmsg(db)` — valid only until the next SQLite call on the same DB.
  Prefer the `message` field on a returned `Error`, which is an owned copy.
- `db_errstr(code)` — borrows SQLite's static error-string table; valid for
  the program's lifetime.
- `stmt_sql(stmt)` — valid for the statement's lifetime.
- `stmt_column_name(stmt, i)` / `stmt_column_decltype(stmt, i)` — valid until
  the next call on the same column or until the statement is finalized /
  automatically re-prepared.
- `stmt_param_name(stmt, i)` — valid for the statement's lifetime.

Clone with `strings.clone` if you need to retain any of these across other
SQLite calls.

## i32 length limits

SQLite's `sqlite3_bind_text`, `sqlite3_bind_blob`, `sqlite3_blob_read`, and
`sqlite3_blob_write` take their length and offset arguments as 32-bit `int`.
The wrapper guards against silent overflow: any input whose length or offset
exceeds `max(i32)` (≈ 2 GiB) is rejected with `SQLITE_TOOBIG` instead of
wrapping into a negative number.

## More information

For user-facing examples and packaging notes, see:

- `packaging/examples/README.md`
- `packaging/README.package.md`
