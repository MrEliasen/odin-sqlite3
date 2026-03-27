package tests

import raw "../sqlite/raw/generated"
import sqlite "../sqlite"

test_statement_prepare_step_finalize :: proc() {
	test_db := test_db_open("statement_prepare_step_finalize")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO items(name) VALUES ('alpha'), ('beta')")

	sql := "SELECT id, name FROM items ORDER BY id"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	expect_true(sqlite.stmt_is_valid(stmt), "prepared statement should be valid")
	expect_false(sqlite.stmt_is_closed(stmt), "prepared statement should not be closed")

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_column_count(stmt), 2, "column_count should match result set")
	expect_eq(sqlite.stmt_column_name(stmt, 0), "id", "column 0 name should be id")
	expect_eq(sqlite.stmt_column_name(stmt, 1), "name", "column 1 name should be name")
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 1, "first row id should be 1")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "alpha", "first row name should be alpha")

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 2, "second row id should be 2")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "beta", "second row name should be beta")

	step_expect_done(stmt, sql)
}

test_statement_reset_allows_reuse :: proc() {
	test_db := test_db_open("statement_reset_allows_reuse")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE counters(value INTEGER NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO counters(value) VALUES (10), (20), (30)")

	sql := "SELECT value FROM counters ORDER BY value"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 10, "first execution should yield first row")

	reset_ok(&stmt, sql)

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 10, "after reset statement should restart from first row")

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 20, "after reset second row should still be reachable")
}

test_statement_clear_bindings_resets_parameters :: proc() {
	test_db := test_db_open("statement_clear_bindings_resets_parameters")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_i64_ok(&stmt, 1, 123, sql)
	bind_text_ok(&stmt, 2, "hello", sql)

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 123, "bound integer should be returned")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "hello", "bound text should be returned")

	reset_ok(&stmt, sql)
	clear_bindings_ok(&stmt, sql)

	step_expect_row(stmt, sql)
	expect_true(sqlite.stmt_is_null(stmt, 0), "cleared binding should read back as NULL")
	expect_true(sqlite.stmt_is_null(stmt, 1), "cleared binding should read back as NULL")
}

test_statement_sql_and_expanded_sql :: proc() {
	test_db := test_db_open("statement_sql_and_expanded_sql")
	defer test_db_close(&test_db)

	sql := "SELECT ?1 AS first_value, ?2 AS second_value"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	expect_eq(sqlite.stmt_sql(stmt), sql, "stmt_sql should return original SQL text")

	bind_i64_ok(&stmt, 1, 42, sql)
	bind_text_ok(&stmt, 2, "bravo", sql)

	expanded := sqlite.stmt_expanded_sql(stmt, context.temp_allocator)
	expect_true(len(expanded) > 0, "expanded_sql should produce text when available")
	expect_string_contains(expanded, "42", "expanded_sql should contain bound integer")
	expect_string_contains(expanded, "bravo", "expanded_sql should contain bound text")
}

test_statement_readonly_detection :: proc() {
	test_db := test_db_open("statement_readonly_detection")
	defer test_db_close(&test_db)

	read_stmt := prepare_ok(test_db.db, "SELECT 1")
	defer finalize_ok(&read_stmt, "SELECT 1")

	write_stmt := prepare_ok(test_db.db, "CREATE TABLE readonly_check(id INTEGER)")
	defer finalize_ok(&write_stmt, "CREATE TABLE readonly_check(id INTEGER)")

	expect_true(sqlite.stmt_readonly(read_stmt), "SELECT should be readonly")
	expect_false(sqlite.stmt_readonly(write_stmt), "CREATE TABLE should not be readonly")
}

test_statement_data_count_matches_row_state :: proc() {
	test_db := test_db_open("statement_data_count_matches_row_state")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE data_count_test(id INTEGER, name TEXT)")
	exec_ok(test_db.db, "INSERT INTO data_count_test(id, name) VALUES (1, 'one')")

	sql := "SELECT id, name FROM data_count_test"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	expect_eq(sqlite.stmt_data_count(stmt), 0, "data_count should be zero before stepping")

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_data_count(stmt), 2, "data_count should reflect visible columns on row")

	step_expect_done(stmt, sql)
	expect_eq(sqlite.stmt_data_count(stmt), 0, "data_count should be zero after SQLITE_DONE")
}

test_statement_next_reports_row_and_done :: proc() {
	test_db := test_db_open("statement_next_reports_row_and_done")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE next_test(v INTEGER)")
	exec_ok(test_db.db, "INSERT INTO next_test(v) VALUES (7), (8)")

	sql := "SELECT v FROM next_test ORDER BY v"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	has_row, err, ok := sqlite.stmt_next(stmt)
	expect_no_error(err, ok, "stmt_next first row should succeed")
	expect_true(has_row, "stmt_next should report row on first result")
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 7, "first stmt_next row should expose value 7")

	has_row, err, ok = sqlite.stmt_next(stmt)
	expect_no_error(err, ok, "stmt_next second row should succeed")
	expect_true(has_row, "stmt_next should report row on second result")
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 8, "second stmt_next row should expose value 8")

	has_row, err, ok = sqlite.stmt_next(stmt)
	expect_no_error(err, ok, "stmt_next done should succeed")
	expect_false(has_row, "stmt_next should report false on SQLITE_DONE")
}

test_column_reader_types_and_nulls :: proc() {
	test_db := test_db_open("column_reader_types_and_nulls")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE typed_values(i INTEGER, f REAL, t TEXT, b BLOB, n TEXT)")
	exec_ok(test_db.db, "INSERT INTO typed_values(i, f, t, b, n) VALUES (123, 4.5, 'hello', x'01020304', NULL)")

	sql := "SELECT i, f, t, b, n FROM typed_values"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_column_count(stmt), 5, "typed row should expose five columns")

	expect_eq(sqlite.stmt_column_type(stmt, 0), int(raw.INTEGER), "column 0 should be INTEGER")
	expect_eq(sqlite.stmt_column_type(stmt, 1), int(raw.FLOAT), "column 1 should be FLOAT")
	expect_eq(sqlite.stmt_column_type(stmt, 2), int(raw.TEXT), "column 2 should be TEXT")
	expect_eq(sqlite.stmt_column_type(stmt, 3), int(raw.BLOB), "column 3 should be BLOB")
	expect_eq(sqlite.stmt_column_type(stmt, 4), int(raw.NULL), "column 4 should be NULL")

	expect_eq(sqlite.stmt_get_i32(stmt, 0), i32(123), "get_i32 should read integer value")
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 123, "get_i64 should read integer value")
	expect_true(sqlite.stmt_get_bool(stmt, 0), "non-zero integer should read as true")
	expect_eq(sqlite.stmt_get_f64(stmt, 1), 4.5, "get_f64 should read floating point value")
	expect_eq(sqlite.stmt_get_text(stmt, 2, context.temp_allocator), "hello", "get_text should read text value")

	blob := sqlite.stmt_get_blob(stmt, 3, context.temp_allocator)
	expect_eq(len(blob), 4, "blob length should be 4")
	expect_eq(blob[0], u8(0x01), "blob byte 0 should match")
	expect_eq(blob[1], u8(0x02), "blob byte 1 should match")
	expect_eq(blob[2], u8(0x03), "blob byte 2 should match")
	expect_eq(blob[3], u8(0x04), "blob byte 3 should match")

	expect_eq(sqlite.stmt_get_blob_bytes(stmt, 3), 4, "blob byte count should be 4")
	expect_eq(sqlite.stmt_get_text_bytes(stmt, 2), 5, "text byte count should be 5")

	expect_true(sqlite.stmt_is_null(stmt, 4), "NULL column should be reported as null")
	expect_eq(sqlite.stmt_get_text(stmt, 4, context.temp_allocator), "", "NULL text should read back as empty string")
}

test_column_decltype_for_table_columns :: proc() {
	test_db := test_db_open("column_decltype_for_table_columns")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE decltype_test(id INTEGER, score REAL, name TEXT, payload BLOB)")
	exec_ok(test_db.db, "INSERT INTO decltype_test(id, score, name, payload) VALUES (1, 2.5, 'x', x'AA')")

	sql := "SELECT id, score, name, payload FROM decltype_test"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_column_decltype(stmt, 0), "INTEGER", "decltype for id should be INTEGER")
	expect_eq(sqlite.stmt_column_decltype(stmt, 1), "REAL", "decltype for score should be REAL")
	expect_eq(sqlite.stmt_column_decltype(stmt, 2), "TEXT", "decltype for name should be TEXT")
	expect_eq(sqlite.stmt_column_decltype(stmt, 3), "BLOB", "decltype for payload should be BLOB")
}

test_statement_bind_parameter_metadata :: proc() {
	test_db := test_db_open("statement_bind_parameter_metadata")
	defer test_db_close(&test_db)

	sql := "SELECT :id, @name, ?3"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	expect_eq(sqlite.stmt_param_count(stmt), 3, "parameter count should match highest parameter index")
	expect_eq(sqlite.stmt_param_index(stmt, ":id"), 1, "named parameter :id should resolve to index 1")
	expect_eq(sqlite.stmt_param_index(stmt, "@name"), 2, "named parameter @name should resolve to index 2")
	expect_eq(sqlite.stmt_param_name(stmt, 1), ":id", "parameter 1 name should be :id")
	expect_eq(sqlite.stmt_param_name(stmt, 2), "@name", "parameter 2 name should be @name")
	expect_eq(sqlite.stmt_param_name(stmt, 3), "?3", "parameter 3 name should be ?3")
}

test_statement_named_binding_and_reuse :: proc() {
	test_db := test_db_open("statement_named_binding_and_reuse")
	defer test_db_close(&test_db)

	sql := "SELECT :id AS id_value, :name AS name_value"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_named_i64_ok(&stmt, ":id", 99, sql)
	bind_named_text_ok(&stmt, ":name", "delta", sql)

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), 99, "named integer binding should read back correctly")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "delta", "named text binding should read back correctly")

	err, ok := sqlite.stmt_reuse(&stmt)
	expect_no_error(err, ok, "stmt_reuse should reset and clear bindings")

	step_expect_row(stmt, sql)
	expect_true(sqlite.stmt_is_null(stmt, 0), "stmt_reuse should clear first binding")
	expect_true(sqlite.stmt_is_null(stmt, 1), "stmt_reuse should clear second binding")
}

test_statement_invalid_sql_returns_error :: proc() {
	test_db := test_db_open("statement_invalid_sql_returns_error")
	defer test_db_close(&test_db)

	sql := "SELECT FROM"
	stmt, err, ok := sqlite.stmt_prepare(test_db.db, sql)

	expect_false(ok, "invalid SQL should fail during prepare")
	expect_false(sqlite.error_ok(err), "invalid SQL should return wrapper error")
	expect_eq(err.code, int(raw.ERROR), "invalid SQL prepare should return SQLITE_ERROR")
	expect_false(sqlite.stmt_is_valid(stmt), "failed prepare should not return valid statement")
}