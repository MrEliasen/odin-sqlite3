# odin-sqlite

Thin SQLite bindings for Odin:

- generated raw bindings for SQLite's C API;
- a high-level wrapper for normal application use; and
- no ORM, query builder, migration system, or bundled SQLite library.

## Status

Raw bindings target SQLite **3.53.1** and cover:

- all 283 baseline public C functions;
- all 81 compile-option-gated functions; and
- ABI checks for 23 C structs.

`sqlite3_activate_cerod` is the only excluded function. CEROD and other
encryption products are not supported.

The high-level wrapper covers:

- connections, errors, busy timeout, interruption, and WAL checkpoints;
- prepare/bind/step/reset/finalize and typed column reads;
- transactions, savepoints, queries, scalars, and statement caches;
- backup and incremental BLOB APIs; and
- struct mapping and typed one/optional/all-row helpers.

Raw coverage does not mean every function has a high-level helper or a complete
behavioral test. The pinned suite runs 109 wrapper tests, 42 adversarial SQLite
contracts, and 18 executable examples. Exact coverage lives in the
[feature matrix](tests/features/FEATURE_MATRIX.md).

### Not currently claimed

- virtual-table modules and custom VFS implementations;
- FTS5 extension/tokenizer C APIs;
- session streams, patchsets, changegroups, and rebasers;
- snapshot recovery;
- window UDFs and remaining hook, trace, limit, and status families;
- 32-bit, Android, iOS, BSD, or WebAssembly support;
- ORM, migrations, pooling, or async scheduling; and
- encryption extensions.

Raw declarations may still exist for these APIs. Items marked `partial` or
`missing` in the feature matrix are not production coverage claims.

### Tested platforms

- Native: Ubuntu 24.04 x64, macOS 14 arm64, Windows Server 2022 x64.
- Compile-only: Linux x64/arm64, macOS x64/arm64, Windows x64.
- ASan: all native runners.
- LeakSanitizer: Linux and macOS; unavailable on Windows.

Cross-target checks prove compilation only. The separately built SQLite C
library is not sanitizer-instrumented.

## Install

Copy `sqlite/` into your project's `vendor/` directory:

```odin
import sqlite "vendor:sqlite"
```

By default the package links `sqlite3` on Unix-like systems and `sqlite3.lib`
on Windows. Select another static or shared-library import with:

```sh
odin build . -define:SQLITE_LIB=system:/absolute/path/to/libsqlite3.a
```

Only the pinned 3.53.1 qualification build is fully tested. Other system SQLite
versions and compile options may work, but must provide every symbol your build
uses.

## Optional SQLite APIs

Optional declarations are off by default. Enable a gate only when the selected
SQLite library was built with its matching option.

| Odin definition | Required SQLite option | Tested status |
|---|---|---|
| `SQLITE_HAS_NORMALIZE_API` | `SQLITE_ENABLE_NORMALIZE` | complete |
| `SQLITE_HAS_PREUPDATE_API` | `SQLITE_ENABLE_PREUPDATE_HOOK` | complete |
| `SQLITE_HAS_SESSION_API` | `SQLITE_ENABLE_SESSION` | core changesets only |
| `SQLITE_HAS_COLUMN_METADATA_API` | `SQLITE_ENABLE_COLUMN_METADATA` | complete |
| `SQLITE_HAS_UNLOCK_NOTIFY_API` | `SQLITE_ENABLE_UNLOCK_NOTIFY` | complete |
| `SQLITE_HAS_STMT_SCANSTATUS_API` | `SQLITE_ENABLE_STMT_SCANSTATUS` | complete |
| `SQLITE_HAS_SNAPSHOT_API` | `SQLITE_ENABLE_SNAPSHOT` | recovery missing |

The CI qualification library exports and link-loads all 81 gated symbols.

## Example

```odin
package main

import "core:fmt"
import sqlite "vendor:sqlite"

main :: proc() {
	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println(sqlite.error_string(err))
		sqlite.error_destroy(&err)
		return
	}
	defer sqlite.db_close_cleanup(&db)

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(db, "SELECT ?1")
	if !prep_ok {
		fmt.println(sqlite.error_string(prep_err))
		sqlite.error_destroy(&prep_err)
		return
	}
	defer sqlite.stmt_finalize_cleanup(&stmt)

	bind_err, bind_ok := sqlite.stmt_bind_i64(&stmt, 1, 42)
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
	if has_row {
		fmt.println(sqlite.stmt_get_i64(stmt, 0))
	}
}
```

More examples: [`packaging/examples/README.md`](packaging/examples/README.md).
In release archives, examples live under `examples/`.

## Ownership and concurrency

- Failed calls return an owned `Error`; release it with
  `sqlite.error_destroy(&err)`.
- Use `db_close_cleanup`, `stmt_finalize_cleanup`, `blob_close_cleanup`, and
  similar helpers in `defer` paths.
- Copied text, BLOBs, mapped string/BLOB fields, and returned row slices belong
  to the caller when using a non-temporary allocator. Release them with
  `delete(...)` as appropriate.
- `db_query_all_struct` returns an owned outer slice plus owned copied fields in
  each row.
- `db_errmsg`, `db_errstr`, `stmt_sql`, column names/types, and parameter names
  are borrowed. Clone them if they must outlive SQLite's documented lifetime.
- Parameterize data values. Savepoint helpers reject unsafe identifier text.
- Connections use SQLite's serialized `OPEN_FULLMUTEX` mode by default. Caches
  and trace configuration still require external synchronization when shared.

See the executable
[ownership example](packaging/examples/common_patterns/ownership_and_cleanup/main.odin)
for cleanup patterns.

## Build and test

From a repository checkout:

```sh
make test                    # wrapper tests and examples
make test-features           # pinned SQLite feature contracts
make test-features-sanitize  # pinned suite under ASan/LSan
make cross-check             # compile-only target matrix
make package-check           # verify release package and examples
```

Tests and examples use tracking allocators and fail on leaks or invalid frees.

Packaging details: [`packaging/README.package.md`](packaging/README.package.md).
Contribution and CI details: [`CONTRIBUTING.md`](CONTRIBUTING.md).

## LLM disclosure and license

This repository is more than 98% LLM-generated. I have done what I can to whip
the tin cans into doing a good job.

Released into the public domain under the [Unlicense](LICENSE), without
warranty.
