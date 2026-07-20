# SQLite feature coverage matrix

Methodology: [`../SQLITE_FEATURE_TESTING.md`](../SQLITE_FEATURE_TESTING.md)

This ledger records behavior tested against SQLite's contract. `complete` does
not mean that declarations merely compile or link; it requires executable
feature contracts and stable external oracles.

| Feature family | Authoritative source | Contract IDs | Attack dimensions | Compile options | Platforms | Status |
|---|---|---|---|---|---|---|
| Core values and expressions | SQLite datatype/expression docs | `sql.values.storage-affinity.v1`, `sql.expressions.core.v1`, `engine.values.exact-null-text-blob-transport.v1`, `engine.values.numeric-boundaries-conversions.v1` | nominal, NULL/empty, affinity, numeric boundaries, invalid conversions | baseline | pinned native matrix | partial |
| DDL and schema changes | SQLite CREATE TABLE/INDEX/VIEW/TRIGGER docs | `sql.ddl.indexes.v1`, `sql.ddl.views-triggers-generated.v1`, `sql.ddl.strict-without-rowid.v1`, `engine.statement.schema-auto-reprepare.v1` | nominal, uniqueness, generated values, strict rejection, reprepare | baseline | pinned native matrix | partial |
| DML and `RETURNING` | SQLite INSERT/UPDATE/DELETE/RETURNING docs | `sql.dml.returning-atomicity.v1`, `sql.dml.conflict-upsert.v1` | nominal, bound values, conflict, rollback state, returned rows | baseline | pinned native matrix | complete |
| Constraints and conflict handling | SQLite constraint/conflict docs | `sql.constraints.core.v1`, `sql.constraints.foreign-key-actions.v1`, `sql.constraints.foreign-key-deferred.v1`, `sql.dml.conflict-upsert.v1` | PK/UNIQUE/NULL/CHECK/FK, actions, deferral, failure atomicity | baseline | pinned native matrix | complete |
| Joins, aggregates, CTEs, windows, compounds | SQLite SELECT documentation | `sql.select.joins-subqueries.v1`, `sql.select.aggregates-compounds.v1`, `sql.select.order-limit.v1`, `sql.select.cte-windows.v1` | nominal, empty groups, NULL, ordering, recursion, frames | baseline | pinned native matrix | partial |
| Transactions and savepoints | SQLite transaction/savepoint docs | `sql.transactions.savepoints.v1`, `engine.transaction.isolation-locking-busy.v1` | commit, rollback, nested rollback, failure state, connection isolation | baseline | pinned native matrix | complete |
| Locking, busy handling, WAL, concurrency | SQLite locking/WAL docs | `engine.transaction.isolation-locking-busy.v1`, `engine.wal.snapshot-checkpoint-visibility.v1`, `optional.unlock-notify.shared-cache.v1` | two connections, busy, visibility, checkpoint, callback | mixed | pinned native matrix | partial |
| Prepared statements and parameter binding | `input/sqlite3.h` | `engine.statement.prepare-bind-lifecycle.v1`, `engine.statement.schema-auto-reprepare.v1`, `engine.values.exact-null-text-blob-transport.v1`, `engine.values.numeric-boundaries-conversions.v1` | bind/step/reset/clear/finalize, reprepare, exact transport | baseline | pinned native matrix | complete |
| Storage, URI, and memory databases | SQLite URI/in-memory docs | `engine.storage.persistence-uri-modes.v1`, `engine.storage.memory-isolation-shared-lifetime.v1` | reopen persistence, URI modes, isolation, shared lifetime | baseline | pinned native matrix | complete |
| Column values and metadata | `input/sqlite3.h` | `engine.values.exact-null-text-blob-transport.v1`, `engine.values.numeric-boundaries-conversions.v1`, `optional.column-metadata.behavior.v1` | type/bytes/value, NULL/empty, origin metadata, lifecycle | `SQLITE_ENABLE_COLUMN_METADATA` | pinned native matrix | complete |
| Errors, limits, interruption, status | `input/sqlite3.h` | `engine.execution.progress-interrupt-recovery.v1`, `optional.scanstatus.counters-reset-plan.v1` | interruption/recovery, counters/reset, plan evidence | mixed | pinned native matrix | partial |
| Hooks, authorizer, tracing, progress | `input/sqlite3.h` | `engine.execution.progress-interrupt-recovery.v1`, `engine.callbacks.collation-authorizer-teardown.v1`, `optional.preupdate.events-depth-count.v1`, `optional.preupdate.blobwrite-lifecycle.v1` | callback arguments, denial, teardown, depth/count/blob write | mixed | pinned native matrix | partial |
| User functions, aggregates, windows, collations | `input/sqlite3.h` | `engine.callbacks.scalar-aggregate-registration.v1`, `engine.callbacks.collation-authorizer-teardown.v1` | registration, arguments, aggregation, ordering, teardown | baseline | pinned native matrix | partial |
| Backup, incremental BLOB, serialize/deserialize | `input/sqlite3.h` | `engine.backup.roundtrip-progress.v1`, `engine.blob.incremental-bounds-reopen.v1`, `engine.serialize.deserialize-readonly-ownership.v1` | round trip, progress, bounds, reopen, ownership/read-only | baseline | pinned native matrix | complete |
| Virtual tables and custom VFS | `input/sqlite3.h` | — | — | baseline | — | missing |
| FTS5 SQL | SQLite FTS5 documentation | `extension.fts5.match-rank-mutation.v1` | MATCH, phrase/prefix, rank/highlight, update/delete | `SQLITE_ENABLE_FTS5` | qualification build/native matrix | complete |
| FTS5 extension/tokenizer API | SQLite FTS5 extension API docs | — | — | `SQLITE_ENABLE_FTS5` | — | missing |
| R-Tree SQL | SQLite R-Tree documentation | `extension.rtree.spatial-mutation-boundary.v1` | containment/intersection, update/delete, numeric boundary | `SQLITE_ENABLE_RTREE` | qualification build/native matrix | complete |
| JSON | SQLite JSON documentation | `sql.json.core.v1`, `extension.json.functions-operators-tvf.v1` | functions/operators/TVF, NULL, invalid input, mutation | pinned-version baseline | pinned native matrix | complete |
| Date and time | SQLite date/time documentation | `sql.datetime.deterministic.v1` | fixed UTC, epoch/leap boundaries, invalid-input NULL | baseline | pinned native matrix | complete |
| Session and changesets | SQLite session extension docs | `optional.session.changeset-roundtrip-conflict.v1` | generate, iterate, apply, conflict rollback | `SQLITE_ENABLE_SESSION` | qualification build/native matrix | partial |
| Session streams, patchsets, changegroups, rebasers | SQLite session extension docs | — | — | `SQLITE_ENABLE_SESSION` | — | missing |
| Normalized SQL | `input/sqlite3.h` | `optional.normalized-sql.literals.v1` | literal normalization, parameter preservation, lifecycle | `SQLITE_ENABLE_NORMALIZE` | qualification build/native matrix | complete |
| Pre-update hook | `input/sqlite3.h` | `optional.preupdate.events-depth-count.v1`, `optional.preupdate.blobwrite-lifecycle.v1` | callback events/values, depth/count, blob-write, teardown | `SQLITE_ENABLE_PREUPDATE_HOOK` | qualification build/native matrix | complete |
| Snapshot capture/open/free | SQLite snapshot documentation | `optional.snapshot.wal-lifecycle.v1` | get/open/free, historical WAL visibility, lifecycle failure | `SQLITE_ENABLE_SNAPSHOT` | qualification build/native matrix | complete |
| Snapshot recovery | SQLite snapshot documentation | — | — | `SQLITE_ENABLE_SNAPSHOT` | — | missing |
| Unlock notify | `input/sqlite3.h` | `optional.unlock-notify.shared-cache.v1` | reproducible shared-cache lock, callback/unblock lifecycle | `SQLITE_ENABLE_UNLOCK_NOTIFY` | qualification build/native matrix | complete |
| Statement scan status | `input/sqlite3.h` | `optional.scanstatus.counters-reset-plan.v1` | counters, reset, query-plan evidence | `SQLITE_ENABLE_STMT_SCANSTATUS` | qualification build/native matrix | complete |
| Window UDFs, remaining hooks/trace, limits/status | `input/sqlite3.h` | — | — | mixed | — | missing |
