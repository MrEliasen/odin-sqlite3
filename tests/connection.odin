package tests

import raw "../sqlite/raw/generated"
import sqlite "../sqlite"

test_connection_open_close :: proc() {
	test_db := test_db_open("connection_open_close")
	defer test_db_close(&test_db)

	expect_true(sqlite.db_is_valid(test_db.db), "db should be valid after open")
	expect_false(sqlite.db_is_closed(test_db.db), "db should not be closed after open")

	err, ok := sqlite.db_close(&test_db.db)
	expect_no_error(err, ok, "db_close should succeed on open db")

	expect_false(sqlite.db_is_valid(test_db.db), "db should be invalid after close")
	expect_true(sqlite.db_is_closed(test_db.db), "db should be closed after close")

	err, ok = sqlite.db_close(&test_db.db)
	expect_no_error(err, ok, "db_close should be idempotent for closed db")
}

test_connection_open_into :: proc() {
	test_db := Test_DB{
		path = make_temp_db_path("connection_open_into"),
	}
	remove_file_if_exists(test_db.path)
	defer remove_file_if_exists(test_db.path)
	defer delete(test_db.path)

	err, ok := sqlite.db_open_into(&test_db.db, test_db.path)
	expect_no_error(err, ok, "db_open_into should open a database")

	expect_true(sqlite.db_is_valid(test_db.db), "db_open_into should populate a valid db")

	close_err, close_ok := sqlite.db_close(&test_db.db)
	expect_no_error(close_err, close_ok, "closing db opened via db_open_into should succeed")
}

test_connection_invalid_open_reports_error :: proc() {
	db, err, ok := sqlite.db_open("")
	defer sqlite.db_close(&db)

	expect_true(ok, "opening with empty path should follow SQLite runtime semantics and succeed")
	expect_true(sqlite.error_ok(err), "opening with empty path should not produce an immediate wrapper error")
	expect_true(sqlite.db_is_valid(db), "empty path open should still yield a valid database handle")

	exec_err, exec_ok := sqlite.db_exec(db, "CREATE TABLE empty_path_runtime_check(id INTEGER PRIMARY KEY)")
	expect_no_error(exec_err, exec_ok, "database opened with empty path should accept SQL execution")

	changes_stmt, stmt_err, stmt_ok := sqlite.stmt_prepare(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'empty_path_runtime_check'")
	expect_no_error(stmt_err, stmt_ok, "sqlite_master verification prepare should succeed for empty path database")
	defer finalize_ok(&changes_stmt, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'empty_path_runtime_check'")

	has_row, next_err, next_ok := sqlite.stmt_next(changes_stmt)
	expect_no_error(next_err, next_ok, "sqlite_master verification query should step successfully")
	expect_true(has_row, "database opened with empty path should reflect created schema")
	expect_eq(sqlite.stmt_get_text(changes_stmt, 0, context.temp_allocator), "empty_path_runtime_check", "created table should be visible in sqlite_master")
}

test_connection_error_string_helpers :: proc() {
	message := sqlite.db_errstr(int(raw.CANTOPEN))
	expect_true(len(message) > 0, "db_errstr should return a non-empty string for known code")
	expect_string_contains(message, "open", "db_errstr for CANTOPEN should mention open/opening")
}

test_connection_busy_timeout_and_extended_errors :: proc() {
	test_db := test_db_open("connection_busy_timeout_and_extended_errors")
	defer test_db_close(&test_db)

	err, ok := sqlite.db_set_busy_timeout(test_db.db, 250)
	expect_no_error(err, ok, "setting busy timeout should succeed")

	err, ok = sqlite.db_set_busy_timeout(test_db.db, 0)
	expect_no_error(err, ok, "disabling busy timeout should succeed")

	err, ok = sqlite.db_set_extended_errors(test_db.db, true)
	expect_no_error(err, ok, "enabling extended result codes should succeed")

	err, ok = sqlite.db_set_extended_errors(test_db.db, false)
	expect_no_error(err, ok, "disabling extended result codes should succeed")

	err, ok = sqlite.db_set_extended_errors(test_db.db, true)
	expect_no_error(err, ok, "re-enabling extended result codes should succeed")
}

test_connection_errmsg_and_errcode_after_sql_error :: proc() {
	test_db := test_db_open("connection_errmsg_and_errcode_after_sql_error")
	defer test_db_close(&test_db)

	err, ok := sqlite.db_exec(test_db.db, "SELECT * FROM table_that_does_not_exist")
	expect_false(ok, "invalid SQL should fail")
	expect_false(sqlite.error_ok(err), "invalid SQL should return a wrapper error")

	msg := sqlite.db_errmsg(test_db.db)
	expect_true(len(msg) > 0, "db_errmsg should return a message after SQL error")
	expect_string_contains(msg, "no such table", "db_errmsg should describe missing table")

	code := sqlite.db_errcode(test_db.db)
	expect_eq(code, int(raw.ERROR), "db_errcode should report SQLITE_ERROR for missing table")

	extended := sqlite.db_extended_errcode(test_db.db)
	expect_eq(extended, int(raw.ERROR), "extended errcode should match SQLITE_ERROR for missing table")
}

test_connection_transaction_state_tracks_autocommit :: proc() {
	test_db := test_db_open("connection_transaction_state_tracks_autocommit")
	defer test_db_close(&test_db)

	expect_false(sqlite.db_in_transaction(test_db.db), "fresh connection should not be in transaction")

	err, ok := sqlite.db_begin(test_db.db)
	expect_no_error(err, ok, "BEGIN should succeed")
	expect_true(sqlite.db_in_transaction(test_db.db), "db should report in_transaction after BEGIN")

	err, ok = sqlite.db_commit(test_db.db)
	expect_no_error(err, ok, "COMMIT should succeed")
	expect_false(sqlite.db_in_transaction(test_db.db), "db should not be in transaction after COMMIT")

	err, ok = sqlite.db_begin_immediate(test_db.db)
	expect_no_error(err, ok, "BEGIN IMMEDIATE should succeed")
	expect_true(sqlite.db_in_transaction(test_db.db), "db should report in_transaction after BEGIN IMMEDIATE")

	err, ok = sqlite.db_rollback(test_db.db)
	expect_no_error(err, ok, "ROLLBACK should succeed")
	expect_false(sqlite.db_in_transaction(test_db.db), "db should not be in transaction after ROLLBACK")
}

test_connection_interrupt_flag_roundtrip :: proc() {
	test_db := test_db_open("connection_interrupt_flag_roundtrip")
	defer test_db_close(&test_db)

	expect_false(sqlite.db_is_interrupted(test_db.db), "fresh connection should not be interrupted")

	sqlite.db_interrupt(test_db.db)

	expect_true(sqlite.db_is_interrupted(test_db.db), "interrupt flag should be visible after db_interrupt")
}