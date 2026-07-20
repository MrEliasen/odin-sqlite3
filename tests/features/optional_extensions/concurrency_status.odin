package optional_extensions

import "core:strings"
import raw "../../../sqlite/raw/generated"

when ALL_FEATURE_BINDING_PROFILE {
	// SQLITE-FEATURE-CONTRACT: optional.snapshot.wal-lifecycle.v1
	// Feature: WAL snapshots capture, reopen, and release historical read states.
	// SQLite source: input/sqlite3.h sqlite3_snapshot_get/open/free() and https://sqlite.org/c3ref/snapshot.html
	// Requirement: In WAL mode a snapshot captured inside a read transaction can open the same historical state after a later commit; autocommit misuse fails with SQLITE_ERROR.
	// Adversarial cases: Autocommit snapshot_get, explicit transaction, later writer commit, connection WAL initialization, historical reopen, latest-state read, and snapshot free.
	// Oracle: COUNT(*) from the snapshot reader is one while a separate latest transaction sees two; result codes and autocommit state independently establish lifecycle correctness.
	// Guardrail: Do not accept a current-state read as a historical snapshot or claim snapshot_recover coverage from a successful call alone; recovery remains explicitly unclaimed.
	test_snapshot_wal_lifecycle_contract :: proc() {
		path := temp_db_path("odin_sqlite_optional_snapshot.sqlite3")
		defer delete(path)
		clean_db_files(path)
		defer clean_db_files(path)

		writer := open_db(path)
		defer close_db(&writer)
		mode := scalar_text(writer, "PRAGMA journal_mode=WAL")
		expect_equal(mode, "wal", "database must enter WAL mode")
		delete(mode)
		exec_ok(writer, "PRAGMA wal_autocheckpoint=0")
		exec_ok(writer, "CREATE TABLE snapshot_rows(id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
		insert := prepare_ok(writer, "INSERT INTO snapshot_rows(id, value) VALUES(?1, ?2)")
		bind_i64(insert, 1, 1)
		bind_text(insert, 2, "first")
		step_done(insert)
		finalize_ok(&insert)

		reader := open_db(path)
		defer close_db(&reader)
		_ = scalar_i64(reader, "PRAGMA application_id")
		snapshot: ^raw.Snapshot
		rc := raw.snapshot_get(reader, "main", &snapshot)
		expect_equal(primary_rc(rc), i32(raw.ERROR), "snapshot_get in autocommit mode must fail")
		expect(raw.get_autocommit(reader) != 0, "failed autocommit snapshot_get must leave this prerequisite scenario in autocommit")

		exec_ok(reader, "BEGIN")
		expect_rc(raw.snapshot_get(reader, "main", &snapshot), raw.OK, "sqlite3_snapshot_get")
		expect(snapshot != nil, "successful snapshot_get must return an owned snapshot")
		exec_ok(reader, "COMMIT")

		insert = prepare_ok(writer, "INSERT INTO snapshot_rows(id, value) VALUES(?1, ?2)")
		bind_i64(insert, 1, 2)
		bind_text(insert, 2, "second")
		step_done(insert)
		finalize_ok(&insert)

		exec_ok(reader, "BEGIN")
		expect_rc(raw.snapshot_open(reader, "main", snapshot), raw.OK, "sqlite3_snapshot_open")
		expect_equal(scalar_i64(reader, "SELECT COUNT(*) FROM snapshot_rows"), i64(1), "historical snapshot row count")
		exec_ok(reader, "COMMIT")

		exec_ok(reader, "BEGIN")
		expect_equal(scalar_i64(reader, "SELECT COUNT(*) FROM snapshot_rows"), i64(2), "latest transaction row count")
		exec_ok(reader, "COMMIT")

		raw.snapshot_free(snapshot)
		snapshot = nil
	}

	Unlock_State :: struct {
		calls:        int,
		argument_count: int,
		seen_context: bool,
	}

	unlock_callback :: proc "c" (arguments: ^rawptr, count: i32) {
		if arguments == nil || count <= 0 {
			return
		}
		items := ([^]rawptr)(arguments)[:count]
		for item in items {
			state := cast(^Unlock_State)item
			if state != nil {
				state.calls += 1
				state.argument_count += int(count)
				state.seen_context = true
			}
		}
	}

	begin_shared_read_lock :: proc(db: ^raw.Sqlite3) -> ^raw.Stmt {
		exec_ok(db, "BEGIN")
		stmt := prepare_ok(db, "SELECT value FROM shared_rows ORDER BY id")
		step_row(stmt)
		return stmt
	}

	blocked_shared_update :: proc(db: ^raw.Sqlite3, value: string) -> ^raw.Stmt {
		stmt := prepare_ok(db, "UPDATE shared_rows SET value=?1 WHERE id=?2")
		bind_text(stmt, 1, value)
		bind_i64(stmt, 2, 1)
		rc := raw.step(stmt)
		expect_equal(primary_rc(rc), i32(raw.LOCKED), "shared-cache writer must be table-locked")
		expect_equal(raw.extended_errcode(db), i32(raw.LOCKED_SHAREDCACHE), "lock must identify a blocking shared-cache connection")
		return stmt
	}

	// SQLITE-FEATURE-CONTRACT: optional.unlock-notify.shared-cache.v1
	// Feature: Unlock-notify callbacks fire when a shared-cache table lock is released and can be cancelled.
	// SQLite source: input/sqlite3.h sqlite3_unlock_notify() and https://sqlite.org/unlock_notify.html
	// Requirement: SQLITE_LOCKED_SHAREDCACHE identifies a blocking connection; a registered callback runs after its transaction ends, while a cancelled callback does not.
	// Adversarial cases: Active read cursor plus explicit transaction, blocked bound UPDATE, callback context delivery, retry after reset, callback cancellation, and second retry.
	// Oracle: Extended result code, test-owned callback counters, successful retried writes, and an independent SELECT jointly decide correctness.
	// Guardrail: Do not substitute SQLITE_BUSY, timing sleeps, or the same-connection DROP TABLE exception for a reproducible shared-cache blocking connection.
	test_unlock_notify_shared_cache_contract :: proc() {
		path := temp_db_path("odin_sqlite_optional_unlock_notify.sqlite3")
		defer delete(path)
		clean_db_files(path)
		defer clean_db_files(path)
		uri := strings.concatenate({"file:", path, "?cache=shared"})
		defer delete(uri)
		flags := i32(raw.OPEN_READWRITE | raw.OPEN_CREATE | raw.OPEN_URI | raw.OPEN_SHAREDCACHE | raw.OPEN_FULLMUTEX)
		locker := open_db(uri, flags)
		defer close_db(&locker)
		blocked := open_db(uri, flags)
		defer close_db(&blocked)
		exec_ok(locker, "CREATE TABLE shared_rows(id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
		seed := prepare_ok(locker, "INSERT INTO shared_rows(id, value) VALUES(?1, ?2)")
		bind_i64(seed, 1, 1)
		bind_text(seed, 2, "before")
		step_done(seed)
		finalize_ok(&seed)

		read_stmt := begin_shared_read_lock(locker)
		write_stmt := blocked_shared_update(blocked, "notified")
		state := Unlock_State{}
		expect_rc(raw.unlock_notify(blocked, unlock_callback, &state), raw.OK, "sqlite3_unlock_notify(register)")
		expect_equal(state.calls, 0, "callback must wait while the blocking transaction remains open")
		finalize_ok(&read_stmt)
		exec_ok(locker, "COMMIT")
		expect_equal(state.calls, 1, "callback invocation count after unlock")
		expect_equal(state.argument_count, 1, "callback context batch size")
		expect(state.seen_context, "callback must receive the registered context")
		rc := raw.reset(write_stmt)
		expect_equal(primary_rc(rc), i32(raw.LOCKED), "reset reports the prior locked step while making the statement reusable")
		step_done(write_stmt)
		finalize_ok(&write_stmt)
		value := scalar_text(locker, "SELECT value FROM shared_rows WHERE id=1")
		expect_equal(value, "notified", "retried update must become externally visible")
		delete(value)

		read_stmt = begin_shared_read_lock(locker)
		write_stmt = blocked_shared_update(blocked, "cancelled-callback")
		expect_rc(raw.unlock_notify(blocked, unlock_callback, &state), raw.OK, "sqlite3_unlock_notify(register before cancel)")
		expect_rc(raw.unlock_notify(blocked, nil, nil), raw.OK, "sqlite3_unlock_notify(cancel)")
		finalize_ok(&read_stmt)
		exec_ok(locker, "COMMIT")
		expect_equal(state.calls, 1, "cancelled callback must not run")
		_ = raw.reset(write_stmt)
		step_done(write_stmt)
		finalize_ok(&write_stmt)
	}

	// SQLITE-FEATURE-CONTRACT: optional.scanstatus.counters-reset-plan.v1
	// Feature: Statement scan-status reports measured loop counters and query-plan identity and resets counters.
	// SQLite source: input/sqlite3.h sqlite3_stmt_scanstatus(), sqlite3_stmt_scanstatus_reset() and https://sqlite.org/c3ref/stmt_scanstatus.html
	// Requirement: Executed query loops expose NLOOP/NVISIT and plan strings; reset zeroes event counters; an out-of-range element leaves output unchanged.
	// Adversarial cases: Indexed equality query over 100 bound rows, exact visit count, independent EXPLAIN QUERY PLAN, counter reset/reuse, and invalid loop index.
	// Oracle: Scan-status counters are compared with the known selected row count and its plan text with separately prepared EXPLAIN QUERY PLAN output.
	// Guardrail: Do not count availability of sqlite3_stmt_scanstatus as coverage or weaken exact deterministic counters to mere non-negativity.
	test_statement_scanstatus_contract :: proc() {
		db := open_db(":memory:")
		defer close_db(&db)
		exec_ok(db, "CREATE TABLE scan_items(id INTEGER PRIMARY KEY, category INTEGER NOT NULL, value INTEGER NOT NULL)")
		exec_ok(db, "CREATE INDEX idx_scan_category ON scan_items(category)")
		insert := prepare_ok(db, "INSERT INTO scan_items(id, category, value) VALUES(?1, ?2, ?3)")
		for id := i64(0); id < 100; id += 1 {
			bind_i64(insert, 1, id)
			bind_i64(insert, 2, id % 5)
			bind_i64(insert, 3, id)
			step_done(insert)
			reset_ok(insert)
		}
		finalize_ok(&insert)

		stmt := prepare_ok(db, "SELECT sum(value) FROM scan_items WHERE category=?1")
		bind_i64(stmt, 1, 3)
		step_row(stmt)
		expect_equal(i64(raw.column_int64(stmt, 0)), i64(1010), "indexed query result")
		step_done(stmt)

		nloop, nvisit: raw.Int64
		expect_rc(raw.stmt_scanstatus(stmt, 0, raw.SCANSTAT_NLOOP, &nloop), 0, "scanstatus NLOOP")
		expect_rc(raw.stmt_scanstatus(stmt, 0, raw.SCANSTAT_NVISIT, &nvisit), 0, "scanstatus NVISIT")
		expect_equal(i64(nloop), i64(1), "indexed loop execution count")
		expect_equal(i64(nvisit), i64(20), "indexed rows visited")
		name, explanation: cstring
		expect_rc(raw.stmt_scanstatus(stmt, 0, raw.SCANSTAT_NAME, &name), 0, "scanstatus NAME")
		expect_rc(raw.stmt_scanstatus(stmt, 0, raw.SCANSTAT_EXPLAIN, &explanation), 0, "scanstatus EXPLAIN")
		expect_equal(string(name), "idx_scan_category", "scanstatus index name")
		expect_contains(string(explanation), "SEARCH", "scanstatus plan must report an index search")
		expect_contains(string(explanation), "idx_scan_category", "scanstatus plan must name the index")

		plan := prepare_ok(db, "EXPLAIN QUERY PLAN SELECT sum(value) FROM scan_items WHERE category=?1")
		bind_i64(plan, 1, 3)
		step_row(plan)
		plan_text := string(raw.column_text(plan, 3))
		expect_contains(plan_text, "SEARCH", "EXPLAIN QUERY PLAN independent oracle")
		expect_contains(plan_text, "idx_scan_category", "EXPLAIN QUERY PLAN index identity")
		step_done(plan)
		finalize_ok(&plan)

		sentinel := raw.Int64(777)
		expect(raw.stmt_scanstatus(stmt, 99, raw.SCANSTAT_NLOOP, &sentinel) != 0, "out-of-range scan element must fail")
		expect_equal(i64(sentinel), i64(777), "out-of-range scan element must leave output unchanged")
		raw.stmt_scanstatus_reset(stmt)
		nloop = 999
		nvisit = 999
		expect_rc(raw.stmt_scanstatus(stmt, 0, raw.SCANSTAT_NLOOP, &nloop), 0, "scanstatus NLOOP after reset")
		expect_rc(raw.stmt_scanstatus(stmt, 0, raw.SCANSTAT_NVISIT, &nvisit), 0, "scanstatus NVISIT after reset")
		expect_equal(i64(nloop), i64(0), "reset NLOOP")
		expect_equal(i64(nvisit), i64(0), "reset NVISIT")
		reset_ok(stmt)
		step_row(stmt)
		step_done(stmt)
		expect_rc(raw.stmt_scanstatus(stmt, 0, raw.SCANSTAT_NVISIT, &nvisit), 0, "scanstatus after statement reuse")
		expect_equal(i64(nvisit), i64(20), "reused statement visit count")
		finalize_ok(&stmt)
	}
}
