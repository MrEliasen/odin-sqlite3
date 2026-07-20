package optional_extensions

import raw "../../../sqlite/raw/generated"

when ALL_FEATURE_BINDING_PROFILE {
	Session_Conflict_State :: struct {
		calls:                  int,
		last_conflict:          i32,
		resolution:             i32,
		db:                     ^raw.Sqlite3,
		earlier_change_visible: bool,
		observation_error:      bool,
	}

	session_conflict_callback :: proc "c" (context_ptr: rawptr, conflict: i32, iterator: ^raw.Changeset_Iter) -> i32 {
		_ = iterator
		state := cast(^Session_Conflict_State)context_ptr
		if state == nil {
			return raw.CHANGESET_ABORT
		}
		state.calls += 1
		state.last_conflict = conflict
		if state.db != nil {
			stmt: ^raw.Stmt
			rc := raw.prepare_v2(state.db, "SELECT value FROM early_records WHERE id=?1", -1, &stmt, nil)
			if rc != raw.OK || stmt == nil {
				state.observation_error = true
			} else {
				if raw.bind_int64(stmt, 1, 1) != raw.OK || raw.step(stmt) != raw.ROW {
					state.observation_error = true
				} else {
					value := raw.column_text(stmt, 0)
					state.earlier_change_visible = value != nil && string(value) == "applied"
				}
				if raw.finalize(stmt) != raw.OK {
					state.observation_error = true
				}
			}
		}
		return state.resolution
	}

	session_schema :: proc(db: ^raw.Sqlite3) {
		exec_ok(db, "CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT NOT NULL, payload BLOB NOT NULL)")
	}

	session_insert :: proc(db: ^raw.Sqlite3, id: i64, value: string, payload: []u8) {
		stmt := prepare_ok(db, "INSERT INTO records(id, value, payload) VALUES(?1, ?2, ?3)")
		defer finalize_ok(&stmt)
		bind_i64(stmt, 1, id)
		bind_text(stmt, 2, value)
		bind_blob(stmt, 3, payload)
		step_done(stmt)
	}

	session_seed :: proc(db: ^raw.Sqlite3) {
		session_schema(db)
		session_insert(db, 1, "one", []u8{1})
		session_insert(db, 2, "two", []u8{2})
	}

	verify_session_result :: proc(db: ^raw.Sqlite3) {
		stmt := prepare_ok(db, "SELECT id, value, typeof(payload), length(payload) FROM records ORDER BY id")
		defer finalize_ok(&stmt)
		step_row(stmt)
		expect_equal(i64(raw.column_int64(stmt, 0)), i64(1), "first surviving row id")
		expect_equal(string(raw.column_text(stmt, 1)), "ONE", "updated row value")
		expect_equal(string(raw.column_text(stmt, 2)), "blob", "updated row payload type")
		expect_equal(i64(raw.column_int64(stmt, 3)), i64(1), "updated row payload length")
		step_row(stmt)
		expect_equal(i64(raw.column_int64(stmt, 0)), i64(3), "inserted row id")
		expect_equal(raw.column_type(stmt, 1), i32(raw.TEXT), "empty text must remain TEXT")
		expect_equal(raw.column_bytes(stmt, 1), i32(0), "inserted empty text length")
		expect_equal(string(raw.column_text(stmt, 2)), "blob", "empty BLOB must remain BLOB")
		expect_equal(i64(raw.column_int64(stmt, 3)), i64(0), "inserted empty BLOB length")
		step_done(stmt)
	}

	ordered_session_seed :: proc(db: ^raw.Sqlite3) {
		exec_ok(db, "CREATE TABLE early_records(id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
		exec_ok(db, "CREATE TABLE late_records(id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
		early := prepare_ok(db, "INSERT INTO early_records(id, value) VALUES(?1, ?2)")
		bind_i64(early, 1, 1)
		bind_text(early, 2, "base")
		step_done(early)
		finalize_ok(&early)
		late := prepare_ok(db, "INSERT INTO late_records(id, value) VALUES(?1, ?2)")
		bind_i64(late, 1, 1)
		bind_text(late, 2, "base")
		step_done(late)
		finalize_ok(&late)
	}

	// SQLITE-FEATURE-CONTRACT: optional.session.changeset-roundtrip-conflict.v1
	// Feature: Session changesets encode row changes, apply atomically, and report data conflicts.
	// SQLite source: input/sqlite3.h session extension declarations and https://sqlite.org/sessionintro.html
	// Requirement: An attached session emits changes that reproduce source state; tables are applied in attachment order, and CHANGESET_ABORT rolls back earlier applied table groups when a later group conflicts.
	// Adversarial cases: Bound update/delete/insert, empty TEXT and zero-length BLOB, iterator lifecycle, close/reopen persistence, two ordered table groups, a divergent late old value, and callback-time state inspection.
	// Oracle: Iterator counts and reopened nominal rows prove round-trip behavior; the conflict callback observes the earlier table's new value before returning ABORT, then reopened SELECTs prove both tables restored to their pre-apply values.
	// Guardrail: Do not infer rollback from an unordered single-table changeset, treat a non-empty buffer as coverage, or accept partial target mutation after CHANGESET_ABORT.
	test_session_changeset_roundtrip_conflict_contract :: proc() {
		source := open_db(":memory:")
		defer close_db(&source)
		session_seed(source)

		session: ^raw.Session
		expect_rc(raw.sqlite3session_create(source, "main", &session), raw.OK, "sqlite3session_create")
		expect(session != nil, "sqlite3session_create must return a session")
		defer raw.sqlite3session_delete(session)
		expect_rc(raw.sqlite3session_attach(session, "records"), raw.OK, "sqlite3session_attach")
		expect(raw.sqlite3session_isempty(session) != 0, "newly attached session must initially be empty")

		update := prepare_ok(source, "UPDATE records SET value=?1 WHERE id=?2")
		bind_text(update, 1, "ONE")
		bind_i64(update, 2, 1)
		step_done(update)
		finalize_ok(&update)

		delete_stmt := prepare_ok(source, "DELETE FROM records WHERE id=?1")
		bind_i64(delete_stmt, 1, 2)
		step_done(delete_stmt)
		finalize_ok(&delete_stmt)
		session_insert(source, 3, "", []u8{})
		expect(raw.sqlite3session_isempty(session) == 0, "session must report recorded changes")

		changeset_size: i32
		changeset: rawptr
		expect_rc(raw.sqlite3session_changeset(session, &changeset_size, &changeset), raw.OK, "sqlite3session_changeset")
		expect(changeset != nil && changeset_size > 0, "behavioral changes must produce a non-empty changeset")
		defer raw.free(changeset)

		iterator: ^raw.Changeset_Iter
		expect_rc(raw.sqlite3changeset_start(&iterator, changeset_size, changeset), raw.OK, "sqlite3changeset_start")
		expect(iterator != nil, "changeset iterator must be created")
		insert_count, update_count, delete_count := 0, 0, 0
		for {
			rc := raw.sqlite3changeset_next(iterator)
			if rc == raw.DONE {
				break
			}
			expect_rc(rc, raw.ROW, "sqlite3changeset_next")
			table: cstring
			columns, operation, indirect: i32
			expect_rc(raw.sqlite3changeset_op(iterator, &table, &columns, &operation, &indirect), raw.OK, "sqlite3changeset_op")
			expect_equal(string(table), "records", "changeset table name")
			expect_equal(columns, i32(3), "changeset column count")
			expect_equal(indirect, i32(0), "direct changes must not be marked indirect")
			switch operation {
			case raw.INSERT:
				insert_count += 1
			case raw.UPDATE:
				update_count += 1
			case raw.DELETE:
				delete_count += 1
			case:
				fail("unexpected changeset operation %d", operation)
			}
		}
		expect_rc(raw.sqlite3changeset_finalize(iterator), raw.OK, "sqlite3changeset_finalize")
		iterator = nil
		expect_equal(insert_count, 1, "changeset INSERT count")
		expect_equal(update_count, 1, "changeset UPDATE count")
		expect_equal(delete_count, 1, "changeset DELETE count")

		path := temp_db_path("odin_sqlite_optional_session.sqlite3")
		defer delete(path)
		clean_db_files(path)
		defer clean_db_files(path)
		target := open_db(path)
		session_seed(target)
		nominal_conflict := Session_Conflict_State{resolution = raw.CHANGESET_ABORT}
		expect_rc(raw.sqlite3changeset_apply(target, changeset_size, changeset, nil, session_conflict_callback, &nominal_conflict), raw.OK, "sqlite3changeset_apply(nominal)")
		expect_equal(nominal_conflict.calls, 0, "compatible target must not invoke conflict handler")
		close_db(&target)
		target = open_db(path)
		verify_session_result(target)
		close_db(&target)

		ordered_source := open_db(":memory:")
		defer close_db(&ordered_source)
		ordered_session_seed(ordered_source)
		ordered_session: ^raw.Session
		expect_rc(raw.sqlite3session_create(ordered_source, "main", &ordered_session), raw.OK, "sqlite3session_create(ordered)")
		defer raw.sqlite3session_delete(ordered_session)
		expect_rc(raw.sqlite3session_attach(ordered_session, "early_records"), raw.OK, "attach early table first")
		expect_rc(raw.sqlite3session_attach(ordered_session, "late_records"), raw.OK, "attach late table second")
		early_update := prepare_ok(ordered_source, "UPDATE early_records SET value=?1 WHERE id=?2")
		bind_text(early_update, 1, "applied")
		bind_i64(early_update, 2, 1)
		step_done(early_update)
		finalize_ok(&early_update)
		late_update := prepare_ok(ordered_source, "UPDATE late_records SET value=?1 WHERE id=?2")
		bind_text(late_update, 1, "incoming")
		bind_i64(late_update, 2, 1)
		step_done(late_update)
		finalize_ok(&late_update)

		ordered_size: i32
		ordered_changeset: rawptr
		expect_rc(raw.sqlite3session_changeset(ordered_session, &ordered_size, &ordered_changeset), raw.OK, "ordered changeset generation")
		expect(ordered_changeset != nil && ordered_size > 0, "ordered changeset must contain both table groups")
		defer raw.free(ordered_changeset)

		conflict_path := temp_db_path("odin_sqlite_optional_session_conflict.sqlite3")
		defer delete(conflict_path)
		clean_db_files(conflict_path)
		defer clean_db_files(conflict_path)
		conflict_target := open_db(conflict_path)
		ordered_session_seed(conflict_target)
		diverge := prepare_ok(conflict_target, "UPDATE late_records SET value=?1 WHERE id=?2")
		bind_text(diverge, 1, "divergent")
		bind_i64(diverge, 2, 1)
		step_done(diverge)
		finalize_ok(&diverge)

		conflict := Session_Conflict_State{resolution = raw.CHANGESET_ABORT, db = conflict_target}
		rc := raw.sqlite3changeset_apply(conflict_target, ordered_size, ordered_changeset, nil, session_conflict_callback, &conflict)
		expect_equal(primary_rc(rc), i32(raw.ABORT), "CHANGESET_ABORT must abort apply")
		expect_equal(conflict.calls, 1, "late divergent update must invoke one conflict callback before abort")
		expect_equal(conflict.last_conflict, i32(raw.CHANGESET_DATA), "late divergent old value conflict kind")
		expect(!conflict.observation_error, "callback-time independent SELECT must succeed")
		expect(conflict.earlier_change_visible, "earlier attached table change must be visible before the later conflict aborts")
		close_db(&conflict_target)
		conflict_target = open_db(conflict_path)
		check := prepare_ok(conflict_target, "SELECT value FROM early_records WHERE id=?1")
		bind_i64(check, 1, 1)
		step_row(check)
		expect_equal(string(raw.column_text(check, 0)), "base", "earlier applied change must be rolled back to pre-state")
		step_done(check)
		finalize_ok(&check)
		check = prepare_ok(conflict_target, "SELECT value FROM late_records WHERE id=?1")
		bind_i64(check, 1, 1)
		step_row(check)
		expect_equal(string(raw.column_text(check, 0)), "divergent", "conflicting table must retain its pre-apply divergent value")
		step_done(check)
		finalize_ok(&check)
		close_db(&conflict_target)
	}
}
