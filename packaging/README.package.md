# odin-sqlite package

This release asset is the consumable package output for another Odin project.

## What to copy into an Odin project

Copy the `sqlite` directory from this package into your project root so you end up with:

```text
<your-project>/vendor/sqlite/
```

Then import it in Odin with:

```odin
import sqlite "vendor:sqlite"
```

## Assumptions

This package assumes SQLite is already installed on the target system.

The raw binding import defaults are:

- `SQLITE_SYSTEM_LIB=true`
- `SQLITE_DYNAMIC_LIB=true`

So by default the package tries to load the system SQLite shared library.

## Build-time overrides

If you need different behavior, override the config values at build time:

- `-define:SQLITE_SYSTEM_LIB=false`
- `-define:SQLITE_DYNAMIC_LIB=false`

## Package contents

- `sqlite/` — handwritten wrapper layer plus generated raw bindings
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
- `examples/common_patterns/errors/main.odin` — structured error formatting and annotation patterns

## Release workflow

This package should be produced from the stable regeneration path:

```sh
make download-sqlite
make bindgen
make regenerate
make package-zip
```

Use `make regenerate`, not `make generate`, so the deterministic post-generation compatibility fixes are applied before packaging.
