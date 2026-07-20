package optional_extensions

import "core:strings"
import raw "../../../sqlite/raw/generated"

when ALL_FEATURE_BINDING_PROFILE {
	// SQLITE-FEATURE-CONTRACT: optional.column-metadata.behavior.v1
	// Feature: Column metadata reports declared schema properties and result-column origins.
	// SQLite source: input/sqlite3.h and https://sqlite.org/c3ref/table_column_metadata.html
	// Requirement: Enabled metadata APIs return declared type, collation, constraints, and origin names; unknown columns fail with SQLITE_ERROR.
	// Adversarial cases: AUTOINCREMENT primary key, NOCASE NOT NULL column, expression column without an origin, missing column, close and reopen.
	// Oracle: Metadata is compared with the independently created schema and sqlite_master state, including after reopening the database.
	// Guardrail: Do not infer metadata from wrapper declarations or accept success for a nonexistent column; this contract requires SQLITE_ENABLE_COLUMN_METADATA.
	test_column_metadata_contract :: proc() {
		path := temp_db_path("odin_sqlite_optional_column_metadata.sqlite3")
		defer delete(path)
		clean_db_files(path)
		defer clean_db_files(path)

		db := open_db(path)
		exec_ok(db, "CREATE TABLE metadata_probe(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT COLLATE NOCASE NOT NULL, amount REAL)")

		data_type, coll_seq: cstring
		not_null, primary_key, autoincrement: i32
		rc := raw.table_column_metadata(db, "main", "metadata_probe", "name", &data_type, &coll_seq, &not_null, &primary_key, &autoincrement)
		expect_rc(rc, raw.OK, "sqlite3_table_column_metadata(name)")
		expect_equal(string(data_type), "TEXT", "declared type must come from the table schema")
		expect_equal(string(coll_seq), "NOCASE", "declared collation must come from the table schema")
		expect_equal(not_null, i32(1), "NOT NULL flag")
		expect_equal(primary_key, i32(0), "non-primary-key flag")
		expect_equal(autoincrement, i32(0), "non-autoincrement flag")

		rc = raw.table_column_metadata(db, "main", "metadata_probe", "id", &data_type, &coll_seq, &not_null, &primary_key, &autoincrement)
		expect_rc(rc, raw.OK, "sqlite3_table_column_metadata(id)")
		expect_equal(string(data_type), "INTEGER", "INTEGER PRIMARY KEY declared type")
		expect_equal(primary_key, i32(1), "primary-key flag")
		expect_equal(autoincrement, i32(1), "AUTOINCREMENT flag")

		stmt := prepare_ok(db, "SELECT name AS display_name, id, amount + 1 AS computed FROM metadata_probe")
		expect_equal(string(raw.column_database_name(stmt, 0)), "main", "result column database origin")
		expect_equal(string(raw.column_table_name(stmt, 0)), "metadata_probe", "result column table origin")
		expect_equal(string(raw.column_origin_name(stmt, 0)), "name", "alias must retain the base-column origin")
		expect_equal(string(raw.column_origin_name(stmt, 1)), "id", "primary-key result origin")
		expect(raw.column_origin_name(stmt, 2) == nil, "expression result must not claim a table-column origin")
		finalize_ok(&stmt)

		rc = raw.table_column_metadata(db, "main", "metadata_probe", "missing", nil, nil, nil, nil, nil)
		expect_equal(primary_rc(rc), i32(raw.ERROR), "unknown column must fail with primary SQLITE_ERROR")
		expect_equal(scalar_i64(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='metadata_probe'"), i64(1), "metadata failure must not alter schema state")

		close_db(&db)
		db = open_db(path)
		rc = raw.table_column_metadata(db, "main", "metadata_probe", "name", &data_type, &coll_seq, &not_null, &primary_key, &autoincrement)
		expect_rc(rc, raw.OK, "metadata after reopen")
		expect_equal(string(coll_seq), "NOCASE", "metadata must persist across close and reopen")
		close_db(&db)
	}

	// SQLITE-FEATURE-CONTRACT: optional.normalized-sql.literals.v1
	// Feature: Normalized SQL replaces literal values while preserving statement behavior.
	// SQLite source: input/sqlite3.h sqlite3_normalized_sql() and https://sqlite.org/c3ref/expanded_sql.html
	// Requirement: With SQLITE_ENABLE_NORMALIZE, prepared v2 statements expose managed normalized SQL in which literal values are replaced by placeholders.
	// Adversarial cases: Integer, text, and blob literals; execution after inspection; malformed SQL; statement finalization and copied-text lifetime.
	// Oracle: The normalized text omits every distinctive literal and contains placeholders, while column APIs return the original literal values from execution.
	// Guardrail: Do not assert undocumented whitespace or keyword formatting and do not use the binding's current normalization output as the expected string.
	test_normalized_sql_contract :: proc() {
		db := open_db(":memory:")
		defer close_db(&db)

		sql := "SELECT 987654321, 'rare-literal-42', x'CAFE' WHERE 314159 = 314159"
		stmt := prepare_ok(db, sql)
		normalized_ptr := raw.normalized_sql(stmt)
		expect(normalized_ptr != nil, "sqlite3_normalized_sql must return text for a prepared v2 statement")
		normalized := strings.clone(string(normalized_ptr))
		defer delete(normalized)
		expect_contains(normalized, "?", "normalization must introduce literal placeholders")
		expect(!contains(normalized, "987654321"), "normalized SQL must not retain the integer literal")
		expect(!contains(normalized, "rare-literal-42"), "normalized SQL must not retain the text literal")
		expect(!contains(normalized, "CAFE"), "normalized SQL must not retain the blob literal")
		expect(!contains(normalized, "314159"), "normalized SQL must replace repeated predicate literals")

		step_row(stmt)
		expect_equal(i64(raw.column_int64(stmt, 0)), i64(987654321), "normalization must not change integer execution semantics")
		expect_equal(string(raw.column_text(stmt, 1)), "rare-literal-42", "normalization must not change text execution semantics")
		expect_equal(raw.column_bytes(stmt, 2), i32(2), "blob literal must still contain two bytes")
		blob := ([^]u8)(raw.column_blob(stmt, 2))[:2]
		expect_equal(blob[0], u8(0xca), "first blob byte")
		expect_equal(blob[1], u8(0xfe), "second blob byte")
		step_done(stmt)
		finalize_ok(&stmt)
		expect_contains(normalized, "?", "the test-owned copy must survive statement finalization")

		bad_stmt: ^raw.Stmt
		rc := prepare_rc(db, "SELECT FROM", &bad_stmt)
		expect_equal(primary_rc(rc), i32(raw.ERROR), "malformed SQL must fail preparation")
		expect(bad_stmt == nil, "malformed SQL must not produce a statement handle")
	}

	Preupdate_Event :: struct {
		op:          i32,
		depth:       i32,
		column_count: i32,
		blob_column: i32,
		old_key:     i64,
		new_key:     i64,
		old_value:   i64,
		new_value:   i64,
		old_valid:   bool,
		new_valid:   bool,
		main_schema: bool,
		items_table: bool,
		audit_table: bool,
	}

	Preupdate_State :: struct {
		events:         [16]Preupdate_Event,
		event_count:    int,
		callback_error: bool,
	}

	preupdate_capture :: proc "c" (context_ptr: rawptr, db: ^raw.Sqlite3, op: i32, schema, table: cstring, old_key, new_key: raw.Int64) {
		state := cast(^Preupdate_State)context_ptr
		if state == nil || state.event_count >= len(state.events) {
			if state != nil {
				state.callback_error = true
			}
			return
		}
		event := &state.events[state.event_count]
		state.event_count += 1
		event.op = op
		event.depth = raw.preupdate_depth(db)
		event.column_count = raw.preupdate_count(db)
		event.blob_column = raw.preupdate_blobwrite(db)
		event.old_key = i64(old_key)
		event.new_key = i64(new_key)
		event.main_schema = schema != nil && string(schema) == "main"
		event.items_table = table != nil && string(table) == "items"
		event.audit_table = table != nil && string(table) == "audit"

		if op == raw.UPDATE || op == raw.DELETE {
			value: ^raw.Value
			rc := raw.preupdate_old(db, 1, &value)
			if rc != raw.OK || value == nil {
				state.callback_error = true
			} else {
				event.old_value = i64(raw.value_int64(value))
				event.old_valid = true
			}
		}
		if op == raw.UPDATE || op == raw.INSERT {
			value: ^raw.Value
			rc := raw.preupdate_new(db, 1, &value)
			if rc != raw.OK || value == nil {
				state.callback_error = true
			} else {
				event.new_value = i64(raw.value_int64(value))
				event.new_valid = true
			}
		}
	}

	insert_item :: proc(db: ^raw.Sqlite3, id, value: i64, payload: []u8) {
		stmt := prepare_ok(db, "INSERT INTO items(id, value, payload) VALUES(?1, ?2, ?3)")
		defer finalize_ok(&stmt)
		bind_i64(stmt, 1, id)
		bind_i64(stmt, 2, value)
		bind_blob(stmt, 3, payload)
		step_done(stmt)
	}

	// SQLITE-FEATURE-CONTRACT: optional.preupdate.events-depth-count.v1
	// Feature: Pre-update hooks expose row events, values, column counts, and trigger depth.
	// SQLite source: input/sqlite3.h sqlite3_preupdate_hook(), sqlite3_preupdate_old/new/count/depth() and https://sqlite.org/c3ref/preupdate_blobwrite.html
	// Requirement: INSERT, UPDATE, and DELETE invoke the hook before mutation; old/new values are available for their documented operations and trigger writes have depth greater than zero.
	// Adversarial cases: Bound values, AFTER INSERT trigger recursion, UPDATE old/new values, DELETE old value, hook teardown, and independently queried final state.
	// Oracle: Test-owned callback records are matched to SQL operation codes and values, while a separate SELECT confirms durable table and trigger state.
	// Guardrail: Do not accept missing callbacks, synthesize values from post-update rows, or treat update_hook behavior as a substitute for the pre-update contract.
	test_preupdate_events_depth_count_contract :: proc() {
		db := open_db(":memory:")
		defer close_db(&db)
		exec_ok(db, "CREATE TABLE items(id INTEGER PRIMARY KEY, value INTEGER NOT NULL, payload BLOB NOT NULL)")
		exec_ok(db, "CREATE TABLE audit(id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
		exec_ok(db, "CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN INSERT INTO audit(id, value) VALUES(new.id, new.value); END")

		state := Preupdate_State{}
		previous := raw.preupdate_hook(db, preupdate_capture, &state)
		expect(previous == nil, "first pre-update hook registration must return no previous context")
		insert_item(db, 1, 10, []u8{1, 2, 3, 4})

		update := prepare_ok(db, "UPDATE items SET value=?1 WHERE id=?2")
		bind_i64(update, 1, 20)
		bind_i64(update, 2, 1)
		step_done(update)
		finalize_ok(&update)

		delete_stmt := prepare_ok(db, "DELETE FROM items WHERE id=?1")
		bind_i64(delete_stmt, 1, 1)
		step_done(delete_stmt)
		finalize_ok(&delete_stmt)

		expect(!state.callback_error, "pre-update callback API calls must all succeed")
		expect_equal(state.event_count, 4, "direct insert, trigger insert, update, and delete must each produce one event")
		expect_equal(state.events[0].op, i32(raw.INSERT), "first event operation")
		expect(state.events[0].items_table && state.events[0].main_schema, "direct insert event identity")
		expect_equal(state.events[0].depth, i32(0), "direct insert depth")
		expect_equal(state.events[0].column_count, i32(3), "items column count")
		expect(state.events[0].new_valid && state.events[0].new_value == 10, "insert new value")
		expect_equal(state.events[0].blob_column, i32(-1), "ordinary insert is not an incremental blob write")

		expect_equal(state.events[1].op, i32(raw.INSERT), "trigger event operation")
		expect(state.events[1].audit_table, "trigger event table")
		expect_equal(state.events[1].depth, i32(1), "trigger event depth")
		expect_equal(state.events[1].column_count, i32(2), "audit column count")

		expect_equal(state.events[2].op, i32(raw.UPDATE), "update event operation")
		expect_equal(state.events[2].depth, i32(0), "direct update depth")
		expect(state.events[2].old_valid && state.events[2].old_value == 10, "update old value")
		expect(state.events[2].new_valid && state.events[2].new_value == 20, "update new value")
		expect_equal(state.events[2].old_key, i64(1), "update old rowid")
		expect_equal(state.events[2].new_key, i64(1), "update new rowid")

		expect_equal(state.events[3].op, i32(raw.DELETE), "delete event operation")
		expect(state.events[3].old_valid && state.events[3].old_value == 20, "delete old value")
		expect_equal(state.events[3].depth, i32(0), "direct delete depth")

		removed_context := raw.preupdate_hook(db, nil, nil)
		expect(removed_context == rawptr(&state), "hook removal must return the prior context pointer")
		insert_item(db, 2, 30, []u8{})
		expect_equal(state.event_count, 4, "removed hook must not receive later writes")
		expect_equal(scalar_i64(db, "SELECT COUNT(*) FROM items"), i64(1), "final item state through independent SELECT")
		expect_equal(scalar_i64(db, "SELECT COUNT(*) FROM audit"), i64(2), "trigger writes must remain observable independently")
	}

	// SQLITE-FEATURE-CONTRACT: optional.preupdate.blobwrite-lifecycle.v1
	// Feature: Pre-update hooks identify incremental BLOB writes and preserve state after rejected writes.
	// SQLite source: input/sqlite3.h sqlite3_preupdate_blobwrite() and sqlite3_blob_write(), plus https://sqlite.org/c3ref/preupdate_blobwrite.html
	// Requirement: A successful sqlite3_blob_write invokes a SQLITE_DELETE pre-update event with the written column index because new values are unavailable; an out-of-range write returns SQLITE_ERROR without changing the BLOB.
	// Adversarial cases: Write one byte past the BLOB boundary, valid interior write, hook removal, handle close/reopen, and a later unobserved write.
	// Oracle: Callback count and blob-column index are paired with hex(payload) queried through a separately prepared statement before and after each operation.
	// Guardrail: Do not count ordinary UPDATE callbacks as blob-write coverage or accept a callback/state change for the rejected boundary write.
	test_preupdate_blobwrite_lifecycle_contract :: proc() {
		db := open_db(":memory:")
		defer close_db(&db)
		exec_ok(db, "CREATE TABLE items(id INTEGER PRIMARY KEY, value INTEGER NOT NULL, payload BLOB NOT NULL)")
		insert_item(db, 1, 7, []u8{0, 0, 0, 0})

		state := Preupdate_State{}
		_ = raw.preupdate_hook(db, preupdate_capture, &state)
		blob: ^raw.Blob
		expect_rc(raw.blob_open(db, "main", "items", "payload", 1, 1, &blob), raw.OK, "sqlite3_blob_open(write)")
		expect(blob != nil, "sqlite3_blob_open must return a handle")

		byte := u8(0x7f)
		rc := raw.blob_write(blob, &byte, 1, 4)
		expect_equal(primary_rc(rc), i32(raw.ERROR), "write past the BLOB end must fail")
		expect_equal(state.event_count, 0, "rejected blob write must not invoke pre-update hook")
		before := scalar_text(db, "SELECT hex(payload) FROM items WHERE id=1")
		expect_equal(before, "00000000", "rejected blob write must leave data unchanged")
		delete(before)

		expect_rc(raw.blob_write(blob, &byte, 1, 2), raw.OK, "sqlite3_blob_write(valid)")
		expect_equal(state.event_count, 1, "successful blob write callback count")
		expect_equal(state.events[0].op, i32(raw.DELETE), "incremental blob write is reported as DELETE because new values are unavailable")
		expect_equal(state.events[0].blob_column, i32(2), "payload is column index 2")
		expect_equal(state.events[0].column_count, i32(3), "blob-write table column count")
		expect_equal(state.events[0].depth, i32(0), "direct blob-write depth")
		expect_rc(raw.blob_close(blob), raw.OK, "sqlite3_blob_close")
		blob = nil

		after := scalar_text(db, "SELECT hex(payload) FROM items WHERE id=1")
		expect_equal(after, "00007F00", "valid incremental write must persist at the requested offset")
		delete(after)

		_ = raw.preupdate_hook(db, nil, nil)
		expect_rc(raw.blob_open(db, "main", "items", "payload", 1, 1, &blob), raw.OK, "sqlite3_blob_open(after hook removal)")
		byte = 0x22
		expect_rc(raw.blob_write(blob, &byte, 1, 0), raw.OK, "blob write after hook removal")
		expect_rc(raw.blob_close(blob), raw.OK, "sqlite3_blob_close(after hook removal)")
		expect_equal(state.event_count, 1, "removed hook must not observe later blob writes")
	}
}
