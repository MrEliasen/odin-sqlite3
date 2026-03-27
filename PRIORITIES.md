# SQLite Bindings for Odin — Priority Plan

This document is a priority-only execution plan for an LLM or agentic coding system.

It is intended to answer one question clearly:

**What should be built first, what can wait, and what does “done” mean for each stage?**

The implementation context is an Odin SQLite binding intended for a **systemic 3D multiplayer game server** with roughly **200–300 players per server**.

The priority model is:

- **P0** — required for first useful release
- **P1** — important after P0 stabilizes
- **P2** — useful but non-essential
- **P3** — defer until the core is proven

---

# Priority summary

## P0 — Build first

Status: completed

These are the highest-priority items and should be implemented before anything else.

1. **Raw generated binding** — completed
2. **Connection lifecycle** — completed
3. **Statement lifecycle** — completed
4. **Binding helpers** — completed
5. **Column readers** — completed
6. **Transactions and execution helpers** — completed
7. **Common high-level query wrappers** — completed
8. **Statement reuse / caching** — completed
9. **Operational helpers** — completed
10. **P0 test suite** — completed

These are the pieces that determine whether the package is actually usable in production-style server code.

## P1 — Build after P0 is stable

Status: in progress

1. **Structured error model** — completed
2. **Tracing / debugging helpers** — implemented and tested; useful current surface is in place, but callback-driven tracing can still be strengthened
3. **Blob API** — completed
4. **Backup API** — completed

These are important, but the binding is still useful without them.

## P2 — Build only if needed (Not needed, skip for now)

1. **UDF / custom SQL function support**
2. **Serialize / deserialize support**

These are legitimate SQLite features, but they are not part of the main gameplay/server persistence path.

## P3

1. **Reflection-based row mapping** — implemented as an additive convenience layer
2. **Struct-tag mapping** — implemented as an additive convenience layer
3. **Regex/tag-driven field extraction** (skip for now)
4. **ORM-like abstractions** (skip for now)
5. **Query builder / schema DSL** (skip for now)

These should not be part of the foundation.

---

# Execution order

The agent should implement the work in the following order and should not reorder it unless a hard technical constraint requires doing so.

## Stage 0 — Raw binding generation [P0] — completed

### Objective

Create a raw Odin binding generated from `sqlite3.h` using `odin-c-bindgen`.

### Why this is first

Everything else depends on having a faithful, reproducible binding to the SQLite C API.

### Required outputs

- raw generated package
- platform import file
- regeneration instructions
- no manual edits inside generated output unless absolutely unavoidable

### Done when

- raw package compiles
- symbols are generated from `sqlite3.h`
- foreign import setup works for target platforms
- the raw package can be regenerated without hand-fixing the result

---

## Stage 1 — Connection lifecycle [P0] — completed

### Objective

Provide the minimum safe and useful DB connection wrapper.

### Required wrapped APIs

- `open_v2`
- `close_v2`
- `errmsg`
- `errstr`
- `extended_errcode`
- `extended_result_codes`
- `interrupt`
- `busy_timeout`
- `get_autocommit`

### Required wrapper surface

- `DB.open(...)`
- `DB.close()`
- `DB.errmsg()`
- `DB.errcode()`
- `DB.set_extended_errors(...)`
- `DB.set_busy_timeout(...)`
- `DB.interrupt()`
- `DB.in_transaction()`

### Why it is P0

Without this, the binding cannot be opened, configured, or debugged in a practical way.

### Done when

- database open/close works
- errors are readable
- busy timeout can be configured
- autocommit state can be queried
- handle invalidation after close is safe

---

## Stage 2 — Statement lifecycle [P0] — completed

### Objective

Wrap the core prepare/step/reset/finalize workflow cleanly.

### Required wrapped APIs

- `prepare_v3`
- `prepare_v2`
- `step`
- `reset`
- `clear_bindings`
- `finalize`
- `sql`
- `expanded_sql`
- `stmt_readonly`
- `data_count`

### Required wrapper surface

- `DB.prepare(...)`
- `Stmt.step()`
- `Stmt.next()`
- `Stmt.reset()`
- `Stmt.clear_bindings()`
- `Stmt.finalize()`
- `Stmt.sql()`
- `Stmt.expanded_sql()`
- `Stmt.readonly()`

### Why it is P0

This is the center of all normal SQLite usage.

### Done when

- statements can be prepared
- stepping rows works
- finalize works reliably
- statement reuse via reset works
- SQL inspection is available for debugging

---

## Stage 3 — Binding helpers [P0] — completed

### Objective

Support the common parameter types safely and explicitly.

### Required wrapped APIs

- `bind_null`
- `bind_int`
- `bind_int64`
- `bind_double`
- `bind_text`
- `bind_blob`
- `bind_zeroblob`
- `bind_parameter_count`
- `bind_parameter_index`
- `bind_parameter_name`

### Required wrapper surface

- `Stmt.bind(...)`
- `Stmt.bind_null(...)`
- `Stmt.bind_i32(...)`
- `Stmt.bind_i64(...)`
- `Stmt.bind_f64(...)`
- `Stmt.bind_bool(...)`
- `Stmt.bind_text(...)`
- `Stmt.bind_blob(...)`
- `Stmt.bind_named(...)`
- `Stmt.param_count()`
- `Stmt.param_index(...)`

### Why it is P0

A server cannot use prepared statements meaningfully without reliable binding.

### Done when

- all common primitive types can be bound
- named parameters work
- repeated reuse does not leave stale parameters
- lifetime rules for text/blob bindings are explicit and tested

---

## Stage 4 — Column readers [P0] — completed

### Objective

Support explicit typed reading of result columns.

### Required wrapped APIs

- `column_type`
- `column_int`
- `column_int64`
- `column_double`
- `column_text`
- `column_blob`
- `column_bytes`
- `column_name`
- `column_count`
- `column_decltype`

### Required wrapper surface

- `Stmt.column_count()`
- `Stmt.column_name(...)`
- `Stmt.column_type(...)`
- `Stmt.is_null(...)`
- `Stmt.get_i32(...)`
- `Stmt.get_i64(...)`
- `Stmt.get_f64(...)`
- `Stmt.get_bool(...)`
- `Stmt.get_text(...)`
- `Stmt.get_blob(...)`

### Why it is P0

The binding is incomplete until rows can be read predictably.

### Done when

- all common value types can be read
- nulls can be distinguished explicitly
- text/blob lifetime semantics are clear
- metadata access works

---

## Stage 5 — Transactions and execution helpers [P0] — completed

### Objective

Make write paths explicit, safe, and reusable.

### Required wrapped APIs

- `exec`
- `changes64`
- `total_changes64`
- `last_insert_rowid`

### Required wrapper surface

- `DB.exec(...)`
- `DB.exec_no_rows(...)`
- `DB.begin()`
- `DB.begin_immediate()`
- `DB.commit()`
- `DB.rollback()`
- `DB.savepoint(...)`
- `DB.release(...)`
- `DB.rollback_to(...)`
- `DB.last_insert_rowid()`
- `DB.changes()`
- `DB.total_changes()`

### Why it is P0

For a multiplayer server, transaction behavior matters more than convenience mapping.

### Done when

- explicit transactions work
- savepoints work
- write helpers work
- rowid/change counts are accessible

---

## Stage 6 — Common high-level query wrappers [P0] — completed

### Objective

Cover the most common application-level patterns with thin helpers.

### Required wrapper surface

- `DB.query_one(...)`
- `DB.query_optional(...)`
- `DB.query_all(...)`
- `DB.scalar_i64(...)`
- `DB.scalar_f64(...)`
- `DB.scalar_text(...)`
- `DB.exists(...)`

### Why it is P0

These wrappers remove repetitive boilerplate without changing SQLite semantics.

### Important note

Joins, groups, and subqueries do **not** require special binding support. They should work through normal prepare/bind/step/read flow.

### Done when

- one-row queries are ergonomic
- optional-row queries are ergonomic
- multi-row queries are ergonomic
- scalar and existence queries are ergonomic

---

## Stage 7 — Statement reuse and caching [P0] — completed

### Objective

Support high-frequency hot-path queries efficiently.

### Required capabilities

- prepare-once, reuse-many
- reset between uses
- clear bindings between uses
- persistent-preparation hint where appropriate

### Required wrapper surface

- `DB.prepare_cached(...)`
- cache clear/finalize helpers

### Why it is P0

A systemic multiplayer server will execute the same statements repeatedly. Re-preparing everything is avoidable overhead.

### Done when

- repeated queries can reuse prepared statements
- cache cleanup works
- no statement leaks occur
- reuse is safe across repeated calls

---

## Stage 8 — Operational helpers [P0] — completed

### Objective

Expose the minimum operational controls needed for a server.

### Required wrapper surface

- `DB.set_busy_timeout(...)`
- `DB.interrupt()`
- `DB.wal_checkpoint(...)`

### Why it is P0

Servers need basic operational control over lock handling and checkpointing.

### Done when

- busy timeout is configurable
- long-running queries can be interrupted
- WAL checkpoints can be triggered

---

## Stage 9 — P0 test suite [P0] — completed

### Objective

Lock down the foundation before expanding features.

### Required test areas

- connection open/close/error handling
- statement prepare/step/reset/finalize
- bind helpers
- column readers
- transaction behavior
- savepoints
- statement reuse/cache
- operational helpers

### Why it is P0

The wrapper should not expand until the basic behavior is proven.

### Done when

- all P0 areas have direct tests
- common success and failure paths are covered
- repeated statement reuse is verified
- transaction behavior is verified

---

# P1 priorities

## Stage 10 — Structured error model [P1] — completed

### Objective

Make errors easy to inspect, log, and act on.

### Required outputs

- structured `Error` type
- SQLite result code retention
- extended result code retention
- optional SQL context
- formatting/logging helpers

### Why it is P1

Important, but not required before the package is usable.

### Done when

- wrapper errors preserve SQLite codes
- logging is better than plain strings
- SQL context can be attached when useful

---

## Stage 11 — Tracing and debugging [P1] — implemented and tested

### Objective

Improve observability during development and production debugging.

### Required wrapped APIs

- `expanded_sql`
- `trace_v2`

### Required wrapper surface

- trace registration
- statement SQL inspection
- optional debug logging helpers

### Done when

- SQL can be inspected clearly
- tracing can be enabled deliberately
- debugging difficult queries is easier

### Current status

- `expanded_sql` inspection is available and tested
- `trace_v2` registration is available and tested
- optional debug logging helpers are available and tested
- current tracing surface is deliberate, useful, and stable
- callback-driven trace dispatch was explored and then intentionally deferred to preserve the thin, reliable wrapper surface

---

## Stage 12 — Blob API [P1] — completed

### Objective

Support incremental blob read/write when needed.

### Required wrapped APIs

- `blob_open`
- `blob_read`
- `blob_write`
- `blob_reopen`
- `blob_close`
- `blob_bytes`

### Why it is P1

Useful, but not part of the first common persistence path.

### Done when

- blob handles can be opened safely
- incremental blob I/O works
- blob handles close correctly

---

## Stage 13 — Backup API [P1] — completed

### Objective

Support online backup flows.

### Required wrapped APIs

- `backup_init`
- `backup_step`
- `backup_finish`
- `backup_remaining`
- `backup_pagecount`

### Why it is P1

Operationally useful, but not part of the first gameplay-facing surface.

### Done when

- online backup can run
- progress can be observed
- cleanup works correctly

---

# P2 priorities

## Stage 14 — UDF / custom function support [P2]

### Objective

Support registration of custom SQL functions.

### Required wrapped APIs

- `create_function_v2`
- `value_*`
- `result_*`

### Why it is P2

Useful for special cases, but not part of the initial server persistence path.

### Done when

- simple scalar custom functions can be registered
- argument/result handling is correct
- callback lifetime rules are safe

---

## Stage 15 — Serialize / deserialize [P2]

### Objective

Support database serialization only if there is a real use case.

### Why it is P2

Not part of the main path for routine server persistence.

### Done when

- serialization works
- memory ownership is explicit
- usage is tested

---

# P3 priorities

## Stage 16 — Reflection-based row mapping [P3]

### Objective

Optional ergonomics only after the base package is proven.

### Possible future scope

- struct mapping
- compile-time-assisted row decoding
- opt-in high-level row helpers

### Why it is P3

This should not be foundational. It adds abstraction and maintenance cost without improving the basic correctness of the binding.

### Done when

- the full base wrapper is already stable
- explicit typed getters remain available
- mapping is purely additive, not mandatory

### Current status

Implemented additive mapping surface now includes:

- `stmt_scan_struct(...)`
- `db_query_one_struct(...)`
- `db_query_optional_struct(...)`
- `db_query_all_struct(...)`

Implemented mapping behavior currently includes:

- reflection-based mapping from the current row into a struct
- struct-tag-based remapping with `sqlite:"column_name"`
- exact column-name matching by default
- support for the current explicit wrapper value types:
  - integers
  - floats
  - bool
  - string
  - `[]u8`
- additive behavior only; explicit getters and explicit statement flow remain first-class

Ownership and lifetime behavior for copied `string` / `[]u8` values is now documented explicitly:

- copied values are allocated with the passed allocator
- copied values are caller-owned
- cleanup expectations are documented in API docs and examples

Examples now include focused coverage for:

- struct mapping
- struct query wrappers
- ownership and cleanup for caller-owned copied values

---

# Priority rules for the agent

## Rule 1

Do **not** start P1, P2, or P3 work until all P0 stages are implemented and tested.

## Rule 2

Within P0, do **not** skip ahead to convenience abstractions before the underlying lifecycle wrappers exist.

## Rule 3

Treat statement reuse and transaction behavior as more important than ergonomic row mapping.

## Rule 4

Do not build abstractions around SQL shape. A join, subquery, aggregate, or grouped query should all work through the same prepared-statement API.

## Rule 5

If a feature is hard to make safe or correct, prefer exposing the raw API first and delaying the convenience wrapper.

---

# Most important items for the target use case

For a systemic multiplayer game server, the most important priorities are:

1. **Statement lifecycle**
2. **Binding helpers**
3. **Column readers**
4. **Transactions**
5. **Statement reuse/cache**
6. **Busy timeout / interrupt / WAL checkpoint**
7. **Common query helpers**
8. **Strong tests**

These matter more than advanced features.

Additional additive progress now in place on top of that foundation includes:

- batch positional binding helpers:
  - `stmt_bind_args(...)`
  - `stmt_bind_args_slice(...)`
- semantics for batch positional binding are now covered by tests:
  - fewer args than parameters is allowed
  - more args than parameters is an error
  - bindings are not auto-cleared

---

# Explicit de-prioritization

The following should not consume early implementation time:

- reflection/tag mapping
- regex-based field extraction
- ORM-style behavior
- schema builder layers
- query builder layers
- advanced custom function support
- uncommon SQLite subsystems

---

# Final instruction to the agent

Implement the priorities in order.

Do not optimize for abstraction breadth.

Optimize for:

- API correctness
- lifetime clarity
- statement reuse
- transaction correctness
- operational control
- test coverage
