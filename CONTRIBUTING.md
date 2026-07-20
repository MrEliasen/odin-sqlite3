# Contributing and qualification

## SQLite feature-test policy

Before creating, editing, reviewing, or triaging tests below `tests/features`,
read [`tests/SQLITE_FEATURE_TESTING.md`](tests/SQLITE_FEATURE_TESTING.md) in
full. Those tests use SQLite's documented behavior as their oracle and must not
be changed to accommodate the binding implementation. Every feature test needs
the mandatory contract comment defined by that methodology; CI enforces it
with `python3 ci/check_feature_test_contracts.py`.

The authoritative build matrix is `.github/workflows/ci.yml`. It uses Python
3.13.14, Odin `dev-2026-05`, and a checksum-pinned SQLite 3.53.1 source archive.
A release tag calls that workflow first, so packaging and publication cannot
start until the qualification matrix passes.

## Local commands

Generate the ignored raw binding before running qualification from a clean
checkout:

```sh
make download-sqlite
make bindgen
make regenerate
```

The normal native gate uses the SQLite selected by `SQLITE_LIB` in the raw
binding (the system linker default unless overridden):

```sh
make test
```

Run the black-box SQLite feature contracts against the checksum-pinned
all-feature SQLite build with:

```sh
make test-features
make test-features-sanitize
```

These commands execute the existing wrapper suite, all examples, and the
SQL-language, engine-runtime, and optional/extensions contract packages. The
feature contracts deliberately require the pinned all-feature profile; they do
not accept an ambient system SQLite as their behavioral oracle. Coverage and
known missing families are recorded in
[`tests/features/FEATURE_MATRIX.md`](tests/features/FEATURE_MATRIX.md).

`make test` checks the handwritten package, test package, and every packaged
example before executing all 109 tests and all 18 examples. Commands stop on
the first failure. The test runners and every example execute with Odin's
tracking allocator; leaked binding/example allocations and invalid frees are
fatal. `python3 ci/check_example_memory_harness.py` prevents new examples from
bypassing the shared fail-closed harness. AddressSanitizer/LeakSanitizer remains
the complementary native-memory gate. To use an exact library instead of the
system default:

```sh
make test QUALIFICATION_SQLITE_LIBRARY=/absolute/path/to/libsqlite3.a
```

On Windows, invoke the portable Python command directly if POSIX `make` is not
installed, and pass a static or import `.lib`:

```powershell
python ci/qualify.py native --sqlite-library C:/path/to/sqlite3.lib
```

## Compile-only portability

```sh
make cross-check
```

This type-checks both `sqlite/raw/generated` and the handwritten `sqlite`
package with the conservative default feature profile and the all-feature
profile for:

- `darwin_amd64` and `darwin_arm64`
- `linux_amd64` and `linux_arm64`
- `windows_amd64`

These checks do not link, execute, or establish runtime portability. Native CI
on each operating system supplies that evidence.

## Optional SQLite APIs

Optional APIs remain disabled by default. Enable a gate only when the selected
library was built with its matching SQLite option:

- `SQLITE_HAS_NORMALIZE_API`
- `SQLITE_HAS_PREUPDATE_API`
- `SQLITE_HAS_SESSION_API`
- `SQLITE_HAS_COLUMN_METADATA_API`
- `SQLITE_HAS_UNLOCK_NOTIFY_API`
- `SQLITE_HAS_STMT_SCANSTATUS_API`
- `SQLITE_HAS_SNAPSHOT_API`

CI builds a static SQLite with all seven gated C-API families plus FTS5 and
R-Tree from the pinned
source, then runs a probe that strongly references all 81 gated symbols and
checks that every loaded address is non-null. This proves the symbols link and
load through Odin; it does not functionally invoke those APIs. The same probe
can be run locally:

```sh
python3 ci/build_sqlite.py --output out/ci-sqlite
make verify-optional-link \
  QUALIFICATION_SQLITE_LIBRARY=out/ci-sqlite/libsqlite3.a \
  SQLITE_FEATURE_PROFILE=all
```

## Sanitizer gate

```sh
make test-sanitize
```

This reruns the complete native test and example suite with Odin's address
sanitizer instrumentation. On macOS the command selects Homebrew LLVM when it
is installed; set `ODIN_SANITIZER_LLVM_BIN` to another compatible LLVM `bin`
directory if needed. Linux needs a Clang toolchain. Windows x64 uses Odin's
bundled ASan runtime; leak detection is disabled there because LeakSanitizer is
not available, while address errors remain fatal. The separately compiled
SQLite C library is trusted input and is not itself sanitizer-instrumented.

Run the orchestration's negative fail-fast test with:

```sh
make test-orchestration
```

`make package-check` rebuilds the package directory and type-checks the copied
wrapper plus every example after its import path has been rewritten. The
`package-zip` target includes this check.

## What CI proves

The workflow has three distinct gates:

1. Linux regeneration, ABI/API verification, and the compile-only matrix above.
2. Complete native runtime execution plus the 81-symbol optional
   link-and-load/reference probe
   on Ubuntu 24.04 x64, macOS 14 arm64, and Windows Server 2022 x64.
3. Complete native ASan execution on the same three runners, with the Windows
   leak-detection limitation stated above.

Do not describe cross-target `odin check` results as native execution or a
sanitizer result.
