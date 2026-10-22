package tests

import "core:mem"
import sqlite "../sqlite"

// Regression tests for defects found in the wrapper review: DB copies sharing
// trace storage and 32-bit boolean reads.

run_review_regression_tests :: proc() {
	run_test("trace_config_survives_db_copies", test_trace_config_survives_db_copies)
	run_test("column_get_bool_uses_sqlite_truthiness", test_column_get_bool_uses_sqlite_truthiness)
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
