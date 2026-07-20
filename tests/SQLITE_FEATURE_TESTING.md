# SQLite feature-test methodology

This document is normative for `tests/features`. Its purpose is to test the
SQLite behavior that the bindings promise to expose, without trusting the
current wrapper or generated binding implementation to define the expected
result.

## Fundamental rule

The test oracle is SQLite's documented contract and externally observable
database behavior. The implementation under test is never the oracle.

A test must begin with a SQLite requirement and then attempt to falsify that
requirement through the public binding surface. Do not begin with the current
code and write an assertion that describes what it happens to do.

When a feature test fails, the default conclusion is that the binding, its
configuration, or the test environment is wrong. Do not weaken the assertion,
change the expected value, or add an implementation-specific exception merely
to make the test pass.

## Sources of truth

Use these sources, in order:

1. The pinned `input/sqlite3.h` C API contract and the pinned SQLite source.
2. SQLite's official language and C API documentation for the pinned version.
3. A minimal C program compiled directly against the same SQLite library when
   the documented result needs an independent executable oracle.
4. An invariant observed through a distinct database connection or a distinct
   SQLite API path.

The wrapper implementation, generated Odin declaration text, existing tests,
examples, and current runtime output are not sources of expected behavior.

If SQLite explicitly leaves behavior undefined, unspecified, version-dependent,
or compile-option-dependent, the test must state that fact. Assert the stable
invariant, gate on the exact version/compile option, or omit the assertion.
Never invent portability that SQLite does not promise.

## Black-box requirements

Feature tests must:

- use only public binding APIs;
- assert externally observable SQL results, SQLite result codes, transaction
  state, persisted data, callback events, or documented lifetime behavior;
- verify an operation through a different path where practical—for example,
  write with a prepared statement and verify through a separately prepared
  query or second connection;
- distinguish `NULL`, empty text, and zero-length BLOB values;
- use `ORDER BY` whenever row order is asserted;
- bind data values rather than interpolating them into SQL;
- use fixed inputs and isolated temporary databases;
- clean up all owned values, handles, callbacks, and files;
- run under the tracking allocator and sanitizer gates.

Feature tests must not:

- inspect wrapper-private maps, ownership flags, cache entries, or backing
  buffers;
- copy an implementation constant into the expected value without checking it
  against the SQLite contract;
- use one convenience wrapper to validate another convenience wrapper when
  both share the same underlying implementation path;
- branch on the observed result and then accept whichever result occurred;
- retry, skip, or soften a failure unless SQLite documents that outcome as
  nondeterministic and the contract comment names every permitted result;
- assert an error-message sentence when SQLite only guarantees the result code;
- change a contract expectation solely because the implementation fails it.

## Mandatory contract comment

Every `test_* :: proc` in `tests/features` must be immediately preceded by one
contiguous comment block using all fields below:

```odin
// SQLITE-FEATURE-CONTRACT: sql.constraints.unique.v1
// Feature: UNIQUE constraints reject duplicate non-NULL keys.
// SQLite source: input/sqlite3.h and https://sqlite.org/lang_createtable.html#uniqueconst
// Requirement: A duplicate key fails with primary result code SQLITE_CONSTRAINT
// and the original row remains unchanged.
// Adversarial cases: Duplicate through a bound parameter; repeat after reset;
// verify from a separately prepared statement.
// Oracle: The primary result code is SQLITE_CONSTRAINT and SELECT returns the
// single original row.
// Guardrail: Do not accept success, replace the row, or change the expected
// result to the wrapper's observed behavior. Fix the binding or update this
// contract only with newer authoritative SQLite documentation.
test_sqlite_unique_constraint_contract :: proc() {
    // ...
}
```

Requirements for this block:

- `SQLITE-FEATURE-CONTRACT` is a unique, stable identifier.
- `Feature` names the SQLite capability, not a wrapper procedure.
- `SQLite source` identifies the authoritative contract.
- `Requirement` states the behavior before any implementation is considered.
- `Adversarial cases` names the boundaries and misuse attempts in the test.
- `Oracle` states exactly how correctness is independently decided.
- `Guardrail` states what future maintainers must not weaken or reinterpret.

The comment is part of the test contract. A behavioral expectation may change
only when SQLite's authoritative contract changes or the project deliberately
changes its supported SQLite version/profile. Such a change must update the
source citation, feature matrix, and release notes—not merely the assertion.

## Required attack dimensions

For every feature family, cover every applicable dimension:

1. **Nominal behavior** — the documented successful operation.
2. **Boundary values** — zero, one, maximum supported sizes/counts, empty text,
   empty BLOB, embedded NUL, minimum/maximum integers, and floating-point edges.
3. **NULL and type behavior** — affinity, conversion, `typeof`, and NULL
   propagation where SQLite defines them.
4. **Invalid use** — bad indexes, malformed SQL, invalid state transitions,
   duplicate names, closed handles, and documented misuse responses.
5. **Lifecycle** — prepare, bind, step, reset, clear, finalize, close, reprepare,
   and callback teardown.
6. **Atomicity** — inspect durable state after constraint failures, rollback,
   savepoint rollback, interruption, and busy/locked failures.
7. **Isolation and concurrency** — separate connections, locking modes, WAL,
   busy timeout, snapshot visibility, and thread configuration where supported.
8. **Persistence** — close and reopen a file database before verifying state.
9. **Feature gates** — assert the exact compile option/version prerequisite and
   run enabled features against the pinned qualification SQLite build.
10. **Resource safety** — tracking allocator and ASan/LSan must stay clean, but
    internal allocation counts are not a feature oracle.

A single test need not contain every dimension. The feature matrix must show
where each applicable dimension is exercised.

## Allocator and sanitizer discipline

Every feature-test package must execute its complete test body under Odin's
tracking allocator and exit unsuccessfully when either the live-allocation map
or invalid-free list is non-empty. Do not clear the tracker, subtract a learned
baseline, or move the operation under test outside the tracked scope to make a
failure disappear. Release every caller-owned result, handle, callback payload,
and temporary file according to the public ownership contract.

The tracking allocator observes allocations made through Odin's active
allocator; it does not replace ASan/LSan. The sanitizer profile remains required
to catch native heap misuse and leaks outside that allocator. A clean result
from either mechanism alone is incomplete resource-safety evidence.

## Independent-oracle patterns

Prefer one of these patterns:

- **State oracle:** perform an operation, then query durable state using a new
  statement or connection.
- **Code-and-state oracle:** require both the documented SQLite result code and
  the documented unchanged/committed database state.
- **Round-trip oracle:** bind a precisely typed value, select `typeof(...)`,
  length/hex representation, and the value itself through a distinct statement.
- **Callback oracle:** capture callback arguments into test-owned storage and
  verify order/count/content documented by SQLite.
- **C oracle:** run the same minimal scenario through a C fixture linked to the
  identical pinned SQLite library and compare stable outputs.
- **Metamorphic oracle:** perform equivalent SQL transformations that SQLite
  guarantees are semantically equal and compare their ordered results.

Avoid circular oracles. For example, do not use `db_scalar_i64` to verify
`db_scalar_i64`; verify its result through explicit prepare/step/column access,
or test the SQLite feature without involving that helper at all.

## Feature inventory and completion

`tests/features/FEATURE_MATRIX.md` is the coverage ledger. Every row must have:

- a SQLite feature family;
- authoritative source;
- contract IDs;
- attack dimensions covered;
- required compile options;
- supported platforms;
- status: `missing`, `partial`, or `complete`.

`complete` means the documented success path, relevant boundaries, failure
atomicity, and lifecycle have executable contracts. Merely compiling or taking
the address of a function does not make a feature complete.

## Review rules

Reviewers must reject a feature-test change when it:

- lacks any mandatory contract field;
- derives an expected result from current binding output;
- removes a failing edge case without authoritative justification;
- replaces an exact stable oracle with a weaker assertion;
- silently changes a feature gate or platform expectation;
- uses implementation internals as evidence;
- claims functional coverage from compilation or symbol linkage alone.

When a legitimate SQLite contract change requires updating a test, the review
must include the old source, new source, supported-version decision, and why the
new oracle is authoritative.

## Agent requirement

Any agent or contributor creating, editing, reviewing, or triaging files below
`tests/features` must read this document in full first and state that it is
following it. Delegated work must include this requirement verbatim. Test work
that does not follow this methodology must not be integrated.
