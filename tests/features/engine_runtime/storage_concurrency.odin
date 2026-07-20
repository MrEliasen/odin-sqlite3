package engine_runtime

import "core:fmt"
import "core:strings"
import "core:time"
import raw "../../../sqlite/raw/generated"

Progress_State :: struct {
	calls: i32,
	stop_after: i32,
}

progress_interrupt_callback :: proc "c" (context_pointer: rawptr) -> i32 {
	state := (^Progress_State)(context_pointer)
	state.calls += 1
	if state.calls >= state.stop_after {
		return 1
	}
	return 0
}

// SQLITE-FEATURE-CONTRACT: engine.storage.persistence-uri-modes.v1
// Feature: File persistence across close/reopen and URI read-only/read-write modes.
// SQLite source: input/sqlite3.h section "Opening A New Database Connection" and https://sqlite.org/uri.html.
// Requirement: Committed file content survives closing every handle; mode=ro permits reads but rejects writes with SQLITE_READONLY, and mode=rw refuses to create a missing file with SQLITE_CANTOPEN.
// Adversarial cases: Bound text persisted through a full close, write attempted through a read-only URI, failed statement finalized after SQLITE_READONLY, and a nonexistent mode=rw URI.
// Oracle: Reopened prepared statements read the exact value, stable primary error codes are checked, and a final independent reopen proves failed writes did not alter durable row count.
// Guardrail: Do not verify persistence before close, accept an accidentally writable read-only connection, interpolate stored values into SQL, or assert error-message wording.
test_file_persistence_and_uri_modes :: proc() {
	path := make_temp_db_path("persistence_uri")
	defer delete(path)
	remove_db_files(path)
	defer remove_db_files(path)

	db := open_db(path)
	exec_ok(db, "CREATE TABLE persisted(id INTEGER PRIMARY KEY, value TEXT)")
	insert := prepare_ok(db, "INSERT INTO persisted(id, value) VALUES(?1, ?2)")
	bind_i64_ok(insert, 1, 1)
	bind_text_ok(insert, 2, "durable-value")
	step_done(insert)
	finalize_ok(&insert)
	close_db(&db)

	read_only_uri := fmt.tprintf("file:%s?mode=ro", path)
	read_only := open_db_with_flags(
		read_only_uri,
		i32(raw.OPEN_READONLY | raw.OPEN_URI | raw.OPEN_FULLMUTEX),
	)
	reader := prepare_ok(read_only, "SELECT value FROM persisted WHERE id=?1")
	bind_i64_ok(reader, 1, 1)
	step_row(reader)
	expect_column_text(reader, 0, "durable-value")
	step_done(reader)
	finalize_ok(&reader)

	failed_write := prepare_ok(read_only, "INSERT INTO persisted(id, value) VALUES(?1, ?2)")
	bind_i64_ok(failed_write, 1, 2)
	bind_text_ok(failed_write, 2, "must-not-persist")
	write_rc := raw.step(failed_write)
	expect_primary_rc(write_rc, raw.READONLY, "write through mode=ro URI")
	finalize_rc := raw.finalize(failed_write)
	expect_primary_rc(finalize_rc, raw.READONLY, "finalize failed read-only write")
	failed_write = nil
	close_db(&read_only)

	reopened := open_db(path)
	expect_eq(query_i64(reopened, "SELECT count(*) FROM persisted"), i64(1), "failed read-only write leaves durable row count unchanged")
	verify := prepare_ok(reopened, "SELECT value FROM persisted WHERE id=?1")
	bind_i64_ok(verify, 1, 1)
	step_row(verify)
	expect_column_text(verify, 0, "durable-value")
	step_done(verify)
	finalize_ok(&verify)
	close_db(&reopened)

	missing_path := make_temp_db_path("uri_missing")
	defer delete(missing_path)
	remove_db_files(missing_path)
	defer remove_db_files(missing_path)
	missing_uri := fmt.tprintf("file:%s?mode=rw", missing_path)
	c_missing_uri := strings.clone_to_cstring(missing_uri)
	defer delete(c_missing_uri)
	missing_db: ^raw.Sqlite3
	open_rc := raw.open_v2(
		c_missing_uri,
		&missing_db,
		i32(raw.OPEN_READWRITE | raw.OPEN_URI | raw.OPEN_FULLMUTEX),
		nil,
	)
	expect_primary_rc(open_rc, raw.CANTOPEN, "mode=rw open of nonexistent file")
	if missing_db != nil {
		expect_rc(raw.close_v2(missing_db), raw.OK, "close failed-open URI handle")
	}
}

// SQLITE-FEATURE-CONTRACT: engine.storage.memory-isolation-shared-lifetime.v1
// Feature: Isolation of :memory: databases and documented named shared in-memory database lifetime.
// SQLite source: input/sqlite3.h URI filename documentation and https://sqlite.org/inmemorydb.html.
// Requirement: Separate :memory: connections are isolated; URI mode=memory with the same name and cache=shared shares one database while at least one connection remains, then deletes it after the last close.
// Adversarial cases: Two anonymous connections, two named shared-cache connections, a bound cross-connection read, and reopening the same name after every original handle closes.
// Oracle: sqlite_master and prepared SELECT results are observed through distinct connections, and the final reopened connection has no prior schema.
// Guardrail: Do not use a wrapper-global registry as evidence of sharing, omit the last-close lifetime check, or silently skip when the pinned build unexpectedly omits shared cache.
test_memory_isolation_and_named_shared_memory :: proc() {
	expect_eq(raw.compileoption_used("OMIT_SHARED_CACHE"), i32(0), "pinned qualification build must include shared-cache support")

	first := open_db(":memory:")
	defer close_db(&first)
	second := open_db(":memory:")
	defer close_db(&second)
	exec_ok(first, "CREATE TABLE anonymous_only(value INTEGER)")
	expect_rc(insert_i64(first, "INSERT INTO anonymous_only(value) VALUES(?1)", 7), raw.DONE, "insert anonymous memory row")
	expect_eq(query_count_by_name(second, "anonymous_only"), i64(0), "separate :memory: connection must not see schema")

	shared_uri := "file:odin_engine_runtime_shared?mode=memory&cache=shared"
	shared_first := open_db(shared_uri)
	shared_second := open_db(shared_uri)
	exec_ok(shared_first, "CREATE TABLE shared_probe(value INTEGER)")
	expect_rc(insert_i64(shared_first, "INSERT INTO shared_probe(value) VALUES(?1)", 73), raw.DONE, "insert shared-memory row")
	shared_reader := prepare_ok(shared_second, "SELECT value FROM shared_probe")
	step_row(shared_reader)
	expect_eq(i64(raw.column_int64(shared_reader, 0)), i64(73), "named shared-memory row visible through second connection")
	step_done(shared_reader)
	finalize_ok(&shared_reader)
	close_db(&shared_second)
	close_db(&shared_first)

	shared_reopened := open_db(shared_uri)
	expect_eq(query_count_by_name(shared_reopened, "shared_probe"), i64(0), "named memory database disappears after last close")
	close_db(&shared_reopened)
}

// SQLITE-FEATURE-CONTRACT: engine.transaction.isolation-locking-busy.v1
// Feature: Multi-connection transaction isolation, BEGIN modes, file locking, busy timeout, and rollback atomicity.
// SQLite source: input/sqlite3.h busy-timeout and transaction-state contracts plus https://sqlite.org/lang_transaction.html.
// Requirement: Deferred transactions acquire locks on first access, a writer excludes a second writer with SQLITE_BUSY, busy_timeout waits before giving up, BEGIN IMMEDIATE reserves the write transaction, BEGIN EXCLUSIVE blocks readers in rollback-journal mode, and rollback removes all uncommitted changes.
// Adversarial cases: The same competing insert is attempted first with a zero timeout and then with 250 ms, monotonic timing uses disjoint conservative windows, the failed statement is reset/finalized, immediate-vs-immediate and exclusive-vs-reader conflicts follow, and visibility is checked before rollback and after commit.
// Oracle: Both attempts return primary SQLITE_BUSY; zero-timeout takes under 100 ms while 250 ms timeout takes 150 ms to 5 s, distinguishing waiting from immediate failure, and sqlite3_txn_state/autocommit plus independent-connection counts prove state atomicity.
// Guardrail: Do not claim timeout coverage from installation alone, retry away SQLITE_BUSY, use wall-clock time, widen the timing windows to overlap, use one connection as its own isolation oracle, or leave a failed transaction active.
test_transaction_isolation_locking_and_busy_timeout :: proc() {
	path := make_temp_db_path("locking_busy")
	defer delete(path)
	remove_db_files(path)
	defer remove_db_files(path)

	first := open_db(path)
	defer close_db(&first)
	second := open_db(path)
	defer close_db(&second)
	exec_ok(first, "PRAGMA journal_mode=DELETE")
	exec_ok(first, "CREATE TABLE lock_probe(value INTEGER)")
	expect_rc(raw.busy_timeout(second, 0), raw.OK, "disable busy wait for immediate baseline")

	exec_ok(first, "BEGIN DEFERRED")
	exec_ok(second, "BEGIN DEFERRED")
	expect_eq(raw.get_autocommit(first), i32(0), "first deferred transaction disables autocommit")
	expect_eq(raw.txn_state(first, "main"), raw.TXN_NONE, "deferred transaction has no lock before access")
	expect_rc(insert_i64(first, "INSERT INTO lock_probe(value) VALUES(?1)", 10), raw.DONE, "first deferred writer")
	expect_eq(raw.txn_state(first, "main"), raw.TXN_WRITE, "first connection enters write transaction")

	competing_insert := prepare_ok(second, "INSERT INTO lock_probe(value) VALUES(?1)")
	bind_i64_ok(competing_insert, 1, 20)
	immediate_start := time.tick_now()
	immediate_rc := raw.step(competing_insert)
	immediate_elapsed := time.tick_since(immediate_start)
	expect_primary_rc(immediate_rc, raw.BUSY, "competing writer with zero timeout")
	expect(
		immediate_elapsed < 100 * time.Millisecond,
		"zero-timeout SQLITE_BUSY must be immediate; elapsed=%v",
		immediate_elapsed,
	)
	expect_primary_rc(raw.reset(competing_insert), raw.BUSY, "reset statement after immediate SQLITE_BUSY")
	bind_i64_ok(competing_insert, 1, 20)

	expect_rc(raw.busy_timeout(second, 250), raw.OK, "install 250 ms busy timeout")
	timed_start := time.tick_now()
	timed_rc := raw.step(competing_insert)
	timed_elapsed := time.tick_since(timed_start)
	expect_primary_rc(timed_rc, raw.BUSY, "competing writer after busy timeout")
	expect(
		timed_elapsed >= 150 * time.Millisecond,
		"250 ms busy timeout must wait rather than fail immediately; elapsed=%v",
		timed_elapsed,
	)
	expect(
		timed_elapsed <= 5 * time.Second,
		"250 ms busy timeout exceeded conservative upper bound; elapsed=%v",
		timed_elapsed,
	)
	expect_primary_rc(raw.finalize(competing_insert), raw.BUSY, "finalize statement after timed SQLITE_BUSY")
	competing_insert = nil
	expect_eq(query_i64(second, "SELECT count(*) FROM lock_probe"), i64(0), "second connection cannot see uncommitted row")
	exec_ok(second, "ROLLBACK")
	exec_ok(first, "ROLLBACK")
	expect_eq(query_i64(second, "SELECT count(*) FROM lock_probe"), i64(0), "rollback removes first writer row")
	expect_rc(raw.busy_timeout(second, 0), raw.OK, "restore zero busy timeout")

	exec_ok(first, "BEGIN IMMEDIATE")
	expect_eq(raw.txn_state(first, "main"), raw.TXN_WRITE, "BEGIN IMMEDIATE starts write transaction")
	expect_primary_rc(exec_rc(second, "BEGIN IMMEDIATE"), raw.BUSY, "second BEGIN IMMEDIATE while writer active")
	expect_rc(insert_i64(first, "INSERT INTO lock_probe(value) VALUES(?1)", 30), raw.DONE, "insert in immediate transaction")
	exec_ok(first, "COMMIT")
	expect_eq(query_i64(second, "SELECT count(*) FROM lock_probe"), i64(1), "committed row visible to independent connection")
	expect_eq(query_i64(second, "SELECT value FROM lock_probe"), i64(30), "only successful writer value persists")

	exec_ok(first, "BEGIN EXCLUSIVE")
	expect_primary_rc(exec_rc(second, "SELECT count(*) FROM lock_probe"), raw.BUSY, "exclusive transaction blocks rollback-journal reader")
	exec_ok(first, "ROLLBACK")
	expect_eq(raw.get_autocommit(first), i32(1), "rollback restores autocommit")
}

// SQLITE-FEATURE-CONTRACT: engine.wal.snapshot-checkpoint-visibility.v1
// Feature: WAL reader snapshot visibility and explicit checkpoint behavior.
// SQLite source: input/sqlite3.h section "Checkpointing A Database" and https://sqlite.org/isolation.html.
// Requirement: A WAL read transaction retains its original snapshot while another connection commits, sees the new commit only after ending that transaction, and a checkpoint preserves all committed content.
// Adversarial cases: Reader snapshot held across a writer commit, passive checkpoint while that reader exists, truncate checkpoint after release, full close, and reopen.
// Oracle: Ordered connection-local counts distinguish old and new snapshots; checkpoint result/output counters are validated; a reopened connection confirms durable rows.
// Guardrail: Do not expect read-uncommitted visibility, close the reader before the snapshot assertion, or treat WAL file size as the data oracle.
test_wal_snapshot_visibility_and_checkpoint :: proc() {
	path := make_temp_db_path("wal_visibility")
	defer delete(path)
	remove_db_files(path)
	defer remove_db_files(path)

	writer := open_db(path)
	reader := open_db(path)
	mode := query_text(writer, "PRAGMA journal_mode=WAL")
	expect_eq(mode, "wal", "journal mode transition")
	delete(mode)
	exec_ok(writer, "PRAGMA wal_autocheckpoint=0")
	exec_ok(writer, "CREATE TABLE wal_probe(value INTEGER)")
	expect_rc(insert_i64(writer, "INSERT INTO wal_probe(value) VALUES(?1)", 1), raw.DONE, "insert first WAL row")

	exec_ok(reader, "BEGIN")
	expect_eq(query_i64(reader, "SELECT count(*) FROM wal_probe"), i64(1), "reader initial WAL snapshot")
	expect_rc(insert_i64(writer, "INSERT INTO wal_probe(value) VALUES(?1)", 2), raw.DONE, "writer commit during reader snapshot")
	expect_eq(query_i64(reader, "SELECT count(*) FROM wal_probe"), i64(1), "reader retains old WAL snapshot")

	log_frames: i32 = -1
	checkpointed_frames: i32 = -1
	expect_rc(
		raw.wal_checkpoint_v2(writer, "main", raw.CHECKPOINT_PASSIVE, &log_frames, &checkpointed_frames),
		raw.OK,
		"passive checkpoint with reader",
	)
	expect(log_frames >= 0, "passive checkpoint must report a nonnegative WAL frame count")
	expect(checkpointed_frames >= 0 && checkpointed_frames <= log_frames, "checkpointed frame count must be within WAL frame count")

	exec_ok(reader, "COMMIT")
	expect_eq(query_i64(reader, "SELECT count(*) FROM wal_probe"), i64(2), "reader sees new snapshot after commit")
	log_frames = -1
	checkpointed_frames = -1
	expect_rc(
		raw.wal_checkpoint_v2(writer, "main", raw.CHECKPOINT_TRUNCATE, &log_frames, &checkpointed_frames),
		raw.OK,
		"truncate checkpoint after reader release",
	)
	expect_eq(log_frames, i32(0), "successful truncate checkpoint log frames")
	expect_eq(checkpointed_frames, i32(0), "successful truncate checkpointed frames")
	close_db(&reader)
	close_db(&writer)

	reopened := open_db(path)
	expect_eq(query_i64(reopened, "SELECT count(*) FROM wal_probe"), i64(2), "checkpointed WAL rows survive reopen")
	close_db(&reopened)
}

// SQLITE-FEATURE-CONTRACT: engine.execution.progress-interrupt-recovery.v1
// Feature: Progress-handler cancellation, SQLITE_INTERRUPT propagation, idle interrupt no-op, and connection recovery.
// SQLite source: input/sqlite3.h sections "Query Progress Callbacks" and "Interrupt A Long-Running Query".
// Requirement: A nonzero progress callback interrupts the running operation with SQLITE_INTERRUPT; after all running statements finish, sqlite3_interrupt while idle is a no-op and later statements execute normally.
// Adversarial cases: High-work recursive query with a bound limit, callback every virtual-machine instruction batch, finalize after interruption, handler removal, and explicit idle sqlite3_interrupt.
// Oracle: Callback count and exact primary code prove cancellation; a statement started after the idle interrupt returns the bound value, and sqlite3_is_interrupted is clear once that statement completes.
// Guardrail: Do not use elapsed time as the cancellation oracle, accept SQLITE_DONE for the long query, or reuse the interrupted statement without completing its documented cleanup.
test_progress_interrupt_and_recovery :: proc() {
	db := open_db(":memory:")
	defer close_db(&db)

	statement := prepare_ok(
		db,
		"WITH RECURSIVE numbers(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM numbers WHERE value<?1) SELECT sum(value) FROM numbers",
	)
	bind_i64_ok(statement, 1, 1000000)
	state := Progress_State{stop_after = 25}
	raw.progress_handler(db, 10, progress_interrupt_callback, rawptr(&state))
	step_rc := raw.step(statement)
	expect_primary_rc(step_rc, raw.INTERRUPT, "progress callback interruption")
	expect(state.calls >= state.stop_after, "progress callback must run through cancellation threshold")
	expect_primary_rc(raw.errcode(db), raw.INTERRUPT, "connection error after progress interruption")
	raw.progress_handler(db, 0, nil, nil)
	finalize_rc := raw.finalize(statement)
	expect_primary_rc(finalize_rc, raw.INTERRUPT, "finalize interrupted statement")
	statement = nil

	raw.interrupt(db)
	recovery := prepare_ok(db, "SELECT ?1")
	bind_i64_ok(recovery, 1, 77)
	step_row(recovery)
	expect_eq(i64(raw.column_int64(recovery, 0)), i64(77), "connection executes after interruption cleanup")
	step_done(recovery)
	expect_eq(raw.is_interrupted(db), i32(0), "interrupt flag clears after the unaffected statement completes")
	finalize_ok(&recovery)
}
