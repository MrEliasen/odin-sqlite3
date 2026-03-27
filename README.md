# odin-sqlite

Thin SQLite bindings for Odin.

`odin-sqlite` is designed as:

1. a generated raw binding layer from `sqlite3.h`
2. a small handwritten wrapper layer on top
3. a practical, explicit API for normal SQLite usage in Odin

The design goal is not to build an ORM. The wrapper stays close to SQLite’s actual execution model and is optimized first for predictable server-side usage.

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

That runs the project checks and the smoke suite.

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

## Minimal example

```text
package main

import "core:fmt"
import sqlite "../sqlite"

main :: proc() {
	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println(sqlite.error_string(err))
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
		return
	}
	defer sqlite.db_close(&db)

	_, _ = sqlite.db_exec(db, "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	_, _ = sqlite.db_exec(db, "INSERT INTO users(name) VALUES ('alice'), ('bob')")

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(db, "SELECT name FROM users WHERE id = ?1")
	if !prep_ok {
		fmt.println(sqlite.error_string(prep_err))
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	bind_err, bind_ok := sqlite.stmt_bind_i64(&stmt, 1, 2)
	if !bind_ok {
		fmt.println(sqlite.error_string(bind_err))
		return
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println(sqlite.error_string(step_err))
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
- bindings are not auto-cleared automatically

Example:

```text
package main

import "core:fmt"
import sqlite "../sqlite"

main :: proc() {
	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println(sqlite.error_string(err))
		return
	}
	defer sqlite.db_close(&db)

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(db, "SELECT ?1, ?2, ?3")
	if !prep_ok {
		fmt.println(sqlite.error_string(prep_err))
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
		return
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok || !has_row {
		fmt.println(sqlite.error_string(step_err))
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

## Ownership notes

Some convenience APIs copy SQLite-managed data into caller-owned memory using the allocator you pass in.

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

If you want a focused usage example for this, read:

- `packaging/examples/common_patterns/ownership_and_cleanup/main.odin`

## Import path

Inside this repository, examples use relative imports.

In a packaged consumer project, you will usually import the package from wherever you vendor/install it, for example:

```text
import sqlite "vendor:sqlite"
```

## More information

For user-facing examples and packaging notes, see:

- `packaging/examples/README.md`
- `packaging/README.package.md`

For project-internal implementation notes, development workflow notes, and status tracking, see:

- `PROJECT.md`
- `IMPLEMENTATION_SPEC.md`
- `PRIORITIES.md`
