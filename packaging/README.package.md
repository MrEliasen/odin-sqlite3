# odin-sqlite package

This release asset is the consumable package output for another Odin project.

## What to copy into an Odin project

Copy the `sqlite` directory from this package into your project's `vendor`
directory so you end up with:

```text
<your-project>/vendor/sqlite/
```

Then import it in Odin with:

```odin
import sqlite "vendor:sqlite"
```

## SQLite library selection

This package assumes SQLite is already installed on the target system.

The raw binding uses these default Odin foreign-import values:

- Windows: `SQLITE_LIB=system:sqlite3.lib`
- other targets: `SQLITE_LIB=system:sqlite3`

The `system:` prefix asks the platform linker to find that name in its normal
system library search paths. The binding does not embed a Homebrew prefix or
architecture-specific path.

## Build-time overrides

If you vendor SQLite, need a particular static/shared build, or use a custom
installation prefix, override the complete foreign-import value at build time:

```sh
odin build . -define:SQLITE_LIB=system:/absolute/path/to/libsqlite3.a
```

You can also supply another `system:<name>` value when the installed library
uses a different linker name. The `system:` prefix prevents Odin from resolving
the remainder as a path relative to the binding, so retain it for absolute
paths too. Use a non-system value only for a library intentionally stored
relative to `sqlite/raw/generated/sqlite3.odin`.

On Windows, provide a static or DLL import `.lib`; the runtime `.dll` itself is
not a linker input.

### Optional API feature gates

The generated raw surface contains SQLite APIs that upstream libraries may
omit. They are disabled by default and are available only when the corresponding
`SQLITE_HAS_*` definition is true. Enable a definition only when the exact
library selected by `SQLITE_LIB` was compiled with that feature; otherwise an
application that references the API will fail to link.

The project qualification workflow builds checksum-pinned SQLite 3.53.1 with
all optional families, then runs a probe that strongly references all 81 gated
symbols and checks that every loaded address is non-null on Linux, macOS, and
Windows. This proves the symbols link and load; it does not functionally invoke
those APIs. The separate cross-target checks are compile-only and do not claim
runtime compatibility.

## Concurrency

`db_open` and `db_open_into` request SQLite's `OPEN_FULLMUTEX` (serialized)
connection mode by default. If you explicitly pass `OPEN_NOMUTEX`, externally
serialize every use of that `DB` and every statement, blob, or backup derived
from it.

The wrapper's mutable trace configuration and statement caches do not add their
own synchronization, so externally serialize access to those wrapper objects
even when SQLite itself is in serialized mode.

## Package contents

- `sqlite/` — handwritten wrapper layer plus generated raw bindings
- `LICENSE` — project license
- `README.md` — top-level project overview
- `README.package.md` — package-specific consumption notes
- `examples/README.md` — examples index and “which example should I read first?” guide
- `examples/minimal/main.odin` — minimal open/create/query example
- `examples/crud/create/main.odin` — create/insert flow
- `examples/crud/read/main.odin` — read/select flow
- `examples/crud/update/main.odin` — update flow
- `examples/crud/delete/main.odin` — delete flow
- `examples/prepared_statements/bind_types/main.odin` — prepared statements with multiple bind/value types
- `examples/prepared_statements/named_parameters/main.odin` — named parameter binding and lookup
- `examples/prepared_statements/reuse/main.odin` — reset, clear_bindings, and reuse behavior
- `examples/transactions/commit_and_rollback/main.odin` — explicit transaction commit and rollback
- `examples/transactions/savepoints/main.odin` — savepoint, rollback_to, and release usage
- `examples/cache/prepare_cached/main.odin` — prepare-once reuse-many cache usage
- `examples/cache/prune_and_clear/main.odin` — cache usage tracking, prune, and clear helpers
- `examples/common_patterns/scalars_and_exists/main.odin` — scalar helpers and existence checks
- `examples/common_patterns/query_optional/main.odin` — optional-row query handling
- `examples/common_patterns/struct_mapping/main.odin` — current-row mapping into a struct
- `examples/common_patterns/struct_queries/main.odin` — typed one/optional/all struct query helpers
- `examples/common_patterns/ownership_and_cleanup/main.odin` — copied text/blob ownership and cleanup
- `examples/common_patterns/errors/main.odin` — structured error formatting and annotation patterns

The package recipe adjusts the examples' repository-relative imports to the
release directory layout, so the examples can be checked directly in the
unpacked package.

## Release workflow

`make package` (or its `package-dir` alias) creates the unpacked release
directory. `make package-check` rebuilds and type-checks that directory after
the example imports are rewritten. `make package-zip` includes that check
before creating the zip.

This package should be produced from the stable regeneration path:

```sh
make download-sqlite
make bindgen
make regenerate
make package-zip
```

Use `make regenerate`, not `make generate`, so the deterministic post-generation compatibility fixes are applied before packaging.
