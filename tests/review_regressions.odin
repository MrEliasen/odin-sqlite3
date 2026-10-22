package tests

import "core:mem"
import sqlite "../sqlite"
import raw "../sqlite/raw/generated"

// Regression tests for defects found in the wrapper review: DB copies sharing
// trace storage, 32-bit boolean reads, UTF-16 struct fields, a column index
// built before re-prepare, and per-row temp-allocator growth.

run_review_regression_tests :: proc() {
	run_test("trace_config_survives_db_copies", test_trace_config_survives_db_copies)
	run_test("column_get_bool_uses_sqlite_truthiness", test_column_get_bool_uses_sqlite_truthiness)
	run_test("row_mapping_rejects_utf16_string_fields", test_row_mapping_rejects_utf16_string_fields)
	run_test("query_all_struct_maps_columns_after_reprepare", test_query_all_struct_maps_columns_after_reprepare)
	run_test("scan_struct_does_not_grow_temp_allocator", test_scan_struct_does_not_grow_temp_allocator)
}

Review_App :: struct {
	db: sqlite.DB,
}

// DB is passed and stored by value. Reconfiguring tracing through one copy and
// closing through another used to free the same trace event storage twice.
test_trace_config_survives_db_copies :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	tracker.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)

	db, open_err, open_ok := sqlite.db_open(":memory:")
	expect_no_error(open_err, open_ok, "open in-memory database")

	config := sqlite.Trace_Config{}
	append(&config.events, sqlite.Trace_Event.Statement, sqlite.Trace_Event.Profile, sqlite.Trace_Event.Statement)
	enable_err, enable_ok := sqlite.db_trace_enable(&db, config)
	delete(config.events)
	expect_no_error(enable_err, enable_ok, "db_trace_enable")

	app := Review_App{db = db}

	disable_err, disable_ok := sqlite.db_trace_disable(&db)
	expect_no_error(disable_err, disable_ok, "db_trace_disable through the original handle")
	expect_false(sqlite.db_trace_enabled(db), "the disabled copy reports tracing off")
	expect_true(sqlite.db_trace_enabled(app.db), "a copy made before db_trace_disable keeps its own settings")

	copy_config := sqlite.db_trace_config(app.db)
	expect_eq(len(copy_config.events), 2, "duplicate events are dropped")
	expect_eq(copy_config.events[0], sqlite.Trace_Event.Statement, "first occurrence keeps its position")
	expect_eq(copy_config.events[1], sqlite.Trace_Event.Profile, "event order is preserved")
	sqlite.trace_config_destroy(&copy_config)

	close_err, close_ok := sqlite.db_close(&app.db)
	expect_no_error(close_err, close_ok, "close through the stored copy")
	expect_eq(len(tracker.bad_free_array), 0, "closing one DB copy must not free trace storage again")
	expect_eq(len(tracker.allocation_map), 0, "DB copies must not leak trace storage")
}

// stmt_get_bool used the 32-bit sqlite3_column_int, so 4294967296 and 0.5 read
// as false. It must agree with SQLite's own truth test (CASE WHEN x).
test_column_get_bool_uses_sqlite_truthiness :: proc() {
	test_db := test_db_open("column_get_bool_uses_sqlite_truthiness")
	defer test_db_close(&test_db)

	sql := "SELECT 4294967296, -4294967296, 0.5, '0.5', 1, 0, 0.0, NULL, 'abc'"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)
	step_expect_row(stmt, sql)

	// The same values under SQLite's `CASE WHEN x THEN 1 ELSE 0 END`.
	expected := [?]bool{true, true, true, true, true, false, false, false, false}
	for want, i in expected {
		expect_eq(sqlite.stmt_get_bool(stmt, i), want, "stmt_get_bool column %d must follow SQLite's truth test", i)
	}

	Flag_Row :: struct {
		flag: bool,
	}
	row := Flag_Row{}
	err, ok := sqlite.db_query_one_struct(test_db.db, "SELECT 4294967296 AS flag", &row)
	expect_no_error(err, ok, "map a 64-bit integer into a bool field")
	expect_true(row.flag, "struct bool fields use the same truth test")
}

Review_String16_Row :: struct {
	id:   i64,
	name: string16,
}

Review_String16_Unmapped_Row :: struct {
	id:   i64,
	note: string16,
}

// A string16 field used to receive a byte-length UTF-8 string, so readers saw
// twice as many bytes as were allocated. UTF-16 fields are rejected like
// cstring fields.
test_row_mapping_rejects_utf16_string_fields :: proc() {
	test_db := test_db_open("row_mapping_rejects_utf16_string_fields")
	defer test_db_close(&test_db)

	row := Review_String16_Row{id = 99}
	err, ok := sqlite.db_query_one_struct(test_db.db, "SELECT 1 AS id, 'hello' AS name", &row)
	expect_error(&err, ok, int(raw.MISUSE), "a mapped string16 field must be rejected")
	expect_eq(row.id, i64(99), "a rejected scan must leave the destination unchanged")
	expect_eq(len(row.name), 0, "a rejected scan must not write the string16 field")

	rows, all_err, all_ok := sqlite.db_query_all_struct(test_db.db, "SELECT 1 AS id, 'hello' AS name", Review_String16_Row)
	expect_error(&all_err, all_ok, int(raw.MISUSE), "db_query_all_struct must reject string16 fields too")
	expect_true(rows == nil, "a rejected query returns no rows")

	unmapped := Review_String16_Unmapped_Row{}
	unmapped_err, unmapped_ok := sqlite.db_query_one_struct(test_db.db, "SELECT 7 AS id", &unmapped)
	expect_no_error(unmapped_err, unmapped_ok, "an unmapped string16 field is ignored like any unmapped field")
	expect_eq(unmapped.id, i64(7), "mapped fields still decode")
}

Review_Reprepare_Row :: struct {
	a: i64,
	b: string,
	c: string,
}

@(private = "file")
reprepare_other_handle: ^raw.Sqlite3
@(private = "file")
reprepare_fired: bool

// Runs at OP_Init of the first sqlite3_step: after db_query_all_struct has
// prepared its statement, before the read transaction starts. It stands in
// for another connection migrating the schema in that window.
@(private = "file")
reprepare_drop_column_on_first_step :: proc "c" (mask: u32, ctx: rawptr, p: rawptr, x: rawptr) -> i32 {
	if !reprepare_fired {
		reprepare_fired = true
		raw.exec(reprepare_other_handle, "ALTER TABLE reprepare_columns DROP COLUMN b", nil, nil, nil)
	}
	return 0
}

// The column index used to be built before the first step. A schema change
// that renumbered `SELECT *` columns then mapped column c's value into b.
test_query_all_struct_maps_columns_after_reprepare :: proc() {
	test_db := test_db_open("query_all_struct_maps_columns_after_reprepare")
	defer test_db_close(&test_db)
	exec_ok(test_db.db, "CREATE TABLE reprepare_columns(a INTEGER, b TEXT, c TEXT)")
	exec_ok(test_db.db, "INSERT INTO reprepare_columns VALUES (1, 'value-of-b', 'value-of-c')")

	empty, empty_err, empty_ok := sqlite.db_query_all_struct(test_db.db, "SELECT * FROM reprepare_columns WHERE 0", Review_Reprepare_Row)
	expect_no_error(empty_err, empty_ok, "zero-row query")
	expect_eq(len(empty), 0, "zero-row query returns no rows")
	delete(empty)

	other, open_err, open_ok := sqlite.db_open(test_db.path)
	expect_no_error(open_err, open_ok, "open second connection")
	defer {
		close_err, close_ok := sqlite.db_close(&other)
		expect_no_error(close_err, close_ok, "close second connection")
	}
	reprepare_other_handle = other.handle
	reprepare_fired = false
	raw.trace_v2(test_db.db.handle, u32(raw.TRACE_STMT), reprepare_drop_column_on_first_step, nil)

	rows, err, ok := sqlite.db_query_all_struct(test_db.db, "SELECT * FROM reprepare_columns", Review_Reprepare_Row)
	raw.trace_v2(test_db.db.handle, 0, nil, nil)
	expect_no_error(err, ok, "query across an automatic re-prepare")
	defer {
		for row in rows {
			delete(row.b)
			delete(row.c)
		}
		delete(rows)
	}

	expect_true(reprepare_fired, "test bug: schema change hook did not run")
	column_count, count_err, count_ok := sqlite.db_scalar_i64(test_db.db, "SELECT count(*) FROM pragma_table_info('reprepare_columns')")
	expect_no_error(count_err, count_ok, "count columns")
	expect_eq(column_count, i64(2), "test bug: column b was not dropped")

	expect_eq(len(rows), 1, "one row")
	expect_eq(rows[0].a, i64(1), "a maps by name")
	expect_eq(rows[0].b, "", "dropped column b has no value")
	expect_eq(rows[0].c, "value-of-c", "c maps to its own column after re-prepare")
}

// stmt_scan_struct built its per-call column index on context.temp_allocator,
// whose frees are no-ops, so every scanned row grew the temp arena.
test_scan_struct_does_not_grow_temp_allocator :: proc() {
	test_db := test_db_open("scan_struct_does_not_grow_temp_allocator")
	defer test_db_close(&test_db)
	exec_ok(test_db.db, "CREATE TABLE scan_rows(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)")
	exec_ok(test_db.db, "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 200) INSERT INTO scan_rows SELECT x, x * 2, x * 3 FROM n")

	sql := "SELECT id, a, b FROM scan_rows ORDER BY id"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	Scan_Row :: struct {
		id: i64,
		a:  i64,
		b:  i64,
	}

	temp_tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&temp_tracker, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&temp_tracker)
	heap_tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap_tracker, context.allocator)
	heap_tracker.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&heap_tracker)

	scanned := 0
	{
		context.temp_allocator = mem.tracking_allocator(&temp_tracker)
		context.allocator = mem.tracking_allocator(&heap_tracker)
		for {
			has_row, step_err, step_ok := sqlite.stmt_next(stmt)
			expect_no_error(step_err, step_ok, "step scan_rows")
			if !has_row {
				break
			}
			row := Scan_Row{}
			scan_err, scan_ok := sqlite.stmt_scan_struct(stmt, &row)
			expect_no_error(scan_err, scan_ok, "scan row")
			expect_eq(row.b, row.id * 3, "scan maps columns")
			scanned += 1
		}
	}

	expect_eq(scanned, 200, "all rows scanned")
	expect_eq(temp_tracker.total_allocation_count, 0, "per-row scans must not allocate from context.temp_allocator")
	expect_eq(heap_tracker.current_memory_allocated, 0, "per-call scratch must be released before stmt_scan_struct returns")
	expect_eq(len(heap_tracker.bad_free_array), 0, "per-call scratch must be freed with its own allocator")
}
