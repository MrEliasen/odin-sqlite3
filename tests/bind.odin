package tests

import raw "../sqlite/raw/generated"
import sqlite "../sqlite"

test_bind_batch_positional_args :: proc() {
	test_db := test_db_open("bind_batch_positional_args")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2, ?3, ?4"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	err, ok := sqlite.stmt_bind_args(
		&stmt,
		sqlite.bind_arg_i64(42),
		sqlite.bind_arg_text("alice"),
		sqlite.bind_arg_bool(true),
		sqlite.bind_arg_f64(9.5),
	)
	expect_no_error(err, ok, "stmt_bind_args should bind multiple positional args")

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(42), "batch bind should populate first positional integer")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "alice", "batch bind should populate second positional text")
	expect_true(sqlite.stmt_get_bool(stmt, 2), "batch bind should populate third positional bool")
	expect_eq(sqlite.stmt_get_f64(stmt, 3), 9.5, "batch bind should populate fourth positional float")
}

test_bind_batch_positional_args_slice :: proc() {
	test_db := test_db_open("bind_batch_positional_args_slice")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2, ?3"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	args := []sqlite.Bind_Arg{
		sqlite.bind_arg_i32(7),
		sqlite.bind_arg_text("slice"),
		sqlite.bind_arg_blob([]u8{1, 2, 3}),
	}

	err, ok := sqlite.stmt_bind_args_slice(&stmt, args)
	expect_no_error(err, ok, "stmt_bind_args_slice should bind a slice of positional args")

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i32(stmt, 0), i32(7), "slice batch bind should populate first positional integer")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "slice", "slice batch bind should populate second positional text")

	blob := sqlite.stmt_get_blob(stmt, 2, context.temp_allocator)
	expect_eq(len(blob), 3, "slice batch bind should populate third positional blob")
	expect_eq(blob[0], u8(1), "slice batch bind blob byte 0 should match")
	expect_eq(blob[1], u8(2), "slice batch bind blob byte 1 should match")
	expect_eq(blob[2], u8(3), "slice batch bind blob byte 2 should match")
}

test_bind_batch_positional_args_allows_fewer_parameters :: proc() {
	test_db := test_db_open("bind_batch_positional_args_allows_fewer_parameters")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2, ?3"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	err, ok := sqlite.stmt_bind_args(
		&stmt,
		sqlite.bind_arg_i64(11),
		sqlite.bind_arg_text("partial"),
	)
	expect_no_error(err, ok, "stmt_bind_args should allow fewer args than parameters")

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(11), "fewer-args batch bind should populate first positional parameter")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "partial", "fewer-args batch bind should populate second positional parameter")
	expect_true(sqlite.stmt_is_null(stmt, 2), "fewer-args batch bind should leave remaining parameters unbound")
}

test_bind_batch_positional_args_errors_on_too_many_parameters :: proc() {
	test_db := test_db_open("bind_batch_positional_args_errors_on_too_many_parameters")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	err, ok := sqlite.stmt_bind_args(
		&stmt,
		sqlite.bind_arg_i64(1),
		sqlite.bind_arg_i64(2),
		sqlite.bind_arg_i64(3),
	)
	expect_false(ok, "stmt_bind_args should fail when more args than parameters are supplied")
	expect_eq(err.code, int(raw.RANGE), "too many positional args should report SQLITE_RANGE")
	expect_string_contains(sqlite.error_string(err), "stmt_bind_args", "too many positional args error should include operation context")
}

test_bind_batch_positional_args_does_not_auto_clear_bindings :: proc() {
	test_db := test_db_open("bind_batch_positional_args_does_not_auto_clear_bindings")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2, ?3"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	err, ok := sqlite.stmt_bind_args(
		&stmt,
		sqlite.bind_arg_i64(100),
		sqlite.bind_arg_text("kept"),
		sqlite.bind_arg_bool(true),
	)
	expect_no_error(err, ok, "initial stmt_bind_args call should succeed")

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(100), "initial batch bind should populate first value")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "kept", "initial batch bind should populate second value")
	expect_true(sqlite.stmt_get_bool(stmt, 2), "initial batch bind should populate third value")

	reset_ok(&stmt, sql)

	err, ok = sqlite.stmt_bind_args(
		&stmt,
		sqlite.bind_arg_i64(200),
	)
	expect_no_error(err, ok, "second stmt_bind_args call should succeed without auto-clearing old bindings")

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(200), "second batch bind should overwrite first positional parameter")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "kept", "second batch bind should preserve previous second parameter when not auto-cleared")
	expect_true(sqlite.stmt_get_bool(stmt, 2), "second batch bind should preserve previous third parameter when not auto-cleared")
}

test_bind_primitive_parameters :: proc() {
	test_db := test_db_open("bind_primitive_parameters")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2, ?3, ?4"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_i32_ok(&stmt, 1, 12, sql)
	bind_i64_ok(&stmt, 2, 9876543210, sql)
	bind_f64_ok(&stmt, 3, 3.25, sql)

	err, ok := sqlite.stmt_bind_bool(&stmt, 4, true)
	expect_no_error(err, ok, "bind_bool should succeed for sql: %q", sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_column_type(stmt, 0), int(raw.INTEGER), "bound i32 should read back as INTEGER")
	expect_eq(sqlite.stmt_column_type(stmt, 1), int(raw.INTEGER), "bound i64 should read back as INTEGER")
	expect_eq(sqlite.stmt_column_type(stmt, 2), int(raw.FLOAT), "bound f64 should read back as FLOAT")
	expect_eq(sqlite.stmt_column_type(stmt, 3), int(raw.INTEGER), "bound bool should read back as INTEGER")

	expect_eq(sqlite.stmt_get_i32(stmt, 0), i32(12), "bound i32 should round-trip")
	expect_eq(sqlite.stmt_get_i64(stmt, 1), i64(9876543210), "bound i64 should round-trip")
	expect_eq(sqlite.stmt_get_f64(stmt, 2), 3.25, "bound f64 should round-trip")
	expect_true(sqlite.stmt_get_bool(stmt, 3), "bound bool true should round-trip")
}

test_bind_null_parameter :: proc() {
	test_db := test_db_open("bind_null_parameter")
	defer test_db_close(&test_db)

	sql := "SELECT ?1"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_null_ok(&stmt, 1, sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_column_type(stmt, 0), int(raw.NULL), "bound null should read back as NULL")
	expect_true(sqlite.stmt_is_null(stmt, 0), "bound null should be reported as null")
	expect_eq(sqlite.stmt_get_text(stmt, 0, context.temp_allocator), "", "NULL text projection should read back as empty string")
}

test_bind_text_parameter_roundtrip :: proc() {
	test_db := test_db_open("bind_text_parameter_roundtrip")
	defer test_db_close(&test_db)

	sql := "SELECT ?1"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_text_ok(&stmt, 1, "hello world", sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_column_type(stmt, 0), int(raw.TEXT), "bound text should read back as TEXT")
	expect_eq(sqlite.stmt_get_text(stmt, 0, context.temp_allocator), "hello world", "bound text should round-trip")
	expect_eq(sqlite.stmt_get_text_bytes(stmt, 0), 11, "text byte count should match UTF-8 byte length")
}

test_bind_empty_text_parameter_roundtrip :: proc() {
	test_db := test_db_open("bind_empty_text_parameter_roundtrip")
	defer test_db_close(&test_db)

	sql := "SELECT ?1"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_text_ok(&stmt, 1, "", sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_column_type(stmt, 0), int(raw.TEXT), "empty text should still be TEXT")
	expect_eq(sqlite.stmt_get_text(stmt, 0, context.temp_allocator), "", "empty bound text should round-trip")
	expect_eq(sqlite.stmt_get_text_bytes(stmt, 0), 0, "empty bound text should have zero bytes")
}

test_bind_blob_parameter_roundtrip :: proc() {
	test_db := test_db_open("bind_blob_parameter_roundtrip")
	defer test_db_close(&test_db)

	sql := "SELECT ?1"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	payload := []u8{0x10, 0x20, 0x30, 0x40, 0x50}
	bind_blob_ok(&stmt, 1, payload, sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_column_type(stmt, 0), int(raw.BLOB), "bound blob should read back as BLOB")

	got := sqlite.stmt_get_blob(stmt, 0, context.temp_allocator)
	expect_eq(len(got), len(payload), "blob length should round-trip")
	expect_eq(sqlite.stmt_get_blob_bytes(stmt, 0), len(payload), "blob byte count should round-trip")

	for i := 0; i < len(payload); i += 1 {
		expect_eq(got[i], payload[i], "blob byte %v should round-trip", i)
	}
}

test_bind_empty_blob_parameter_roundtrip :: proc() {
	test_db := test_db_open("bind_empty_blob_parameter_roundtrip")
	defer test_db_close(&test_db)

	sql := "SELECT ?1"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_blob_ok(&stmt, 1, []u8{}, sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_column_type(stmt, 0), int(raw.NULL), "empty blob currently binds as NULL under observed SQLite runtime behavior")

	got := sqlite.stmt_get_blob(stmt, 0, context.temp_allocator)
	expect_true(got == nil, "empty blob currently reads back as nil when SQLite reports NULL")
	expect_eq(sqlite.stmt_get_blob_bytes(stmt, 0), 0, "empty blob byte count should be zero")
	expect_true(sqlite.stmt_is_null(stmt, 0), "empty blob binding should currently be treated as NULL by the runtime")
}

test_bind_zeroblob_parameter_roundtrip :: proc() {
	test_db := test_db_open("bind_zeroblob_parameter_roundtrip")
	defer test_db_close(&test_db)

	sql := "SELECT ?1"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	err, ok := sqlite.stmt_bind_zeroblob(&stmt, 1, 6)
	expect_no_error(err, ok, "bind_zeroblob should succeed for sql: %q", sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_column_type(stmt, 0), int(raw.BLOB), "zeroblob should read back as BLOB")
	expect_eq(sqlite.stmt_get_blob_bytes(stmt, 0), 6, "zeroblob byte count should match requested size")

	got := sqlite.stmt_get_blob(stmt, 0, context.temp_allocator)
	expect_eq(len(got), 6, "zeroblob length should match requested size")
	for i := 0; i < len(got); i += 1 {
		expect_eq(got[i], u8(0), "zeroblob byte %v should be zero", i)
	}
}

test_bind_named_parameters_roundtrip :: proc() {
	test_db := test_db_open("bind_named_parameters_roundtrip")
	defer test_db_close(&test_db)

	sql := "SELECT :id, @name, $score, :flag"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_named_i64_ok(&stmt, ":id", 77, sql)
	bind_named_text_ok(&stmt, "@name", "echo", sql)

	err, ok := sqlite.stmt_bind_named_f64(&stmt, "$score", 8.5)
	expect_no_error(err, ok, "bind_named_f64 should succeed for sql: %q", sql)

	err, ok = sqlite.stmt_bind_named_bool(&stmt, ":flag", true)
	expect_no_error(err, ok, "bind_named_bool should succeed for sql: %q", sql)

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_get_i64(stmt, 0), 77, "named i64 should round-trip")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "echo", "named text should round-trip")
	expect_eq(sqlite.stmt_get_f64(stmt, 2), 8.5, "named f64 should round-trip")
	expect_true(sqlite.stmt_get_bool(stmt, 3), "named bool should round-trip")
}

test_bind_generic_bind_arg_roundtrip :: proc() {
	test_db := test_db_open("bind_generic_bind_arg_roundtrip")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	err, ok := sqlite.stmt_bind(&stmt, 1, sqlite.bind_arg_null())
	expect_no_error(err, ok, "stmt_bind null should succeed")

	err, ok = sqlite.stmt_bind(&stmt, 2, sqlite.bind_arg_i32(21))
	expect_no_error(err, ok, "stmt_bind i32 should succeed")

	err, ok = sqlite.stmt_bind(&stmt, 3, sqlite.bind_arg_i64(123456789))
	expect_no_error(err, ok, "stmt_bind i64 should succeed")

	err, ok = sqlite.stmt_bind(&stmt, 4, sqlite.bind_arg_f64(6.75))
	expect_no_error(err, ok, "stmt_bind f64 should succeed")

	err, ok = sqlite.stmt_bind(&stmt, 5, sqlite.bind_arg_bool(false))
	expect_no_error(err, ok, "stmt_bind bool should succeed")

	err, ok = sqlite.stmt_bind(&stmt, 6, sqlite.bind_arg_text("foxtrot"))
	expect_no_error(err, ok, "stmt_bind text should succeed")

	err, ok = sqlite.stmt_bind(&stmt, 7, sqlite.bind_arg_blob([]u8{1, 2, 3}))
	expect_no_error(err, ok, "stmt_bind blob should succeed")

	step_expect_row(stmt, sql)

	expect_true(sqlite.stmt_is_null(stmt, 0), "generic null bind should read back as NULL")
	expect_eq(sqlite.stmt_get_i32(stmt, 1), i32(21), "generic i32 bind should round-trip")
	expect_eq(sqlite.stmt_get_i64(stmt, 2), i64(123456789), "generic i64 bind should round-trip")
	expect_eq(sqlite.stmt_get_f64(stmt, 3), 6.75, "generic f64 bind should round-trip")
	expect_false(sqlite.stmt_get_bool(stmt, 4), "generic bool bind should round-trip")
	expect_eq(sqlite.stmt_get_text(stmt, 5, context.temp_allocator), "foxtrot", "generic text bind should round-trip")

	blob := sqlite.stmt_get_blob(stmt, 6, context.temp_allocator)
	expect_eq(len(blob), 3, "generic blob bind length should round-trip")
	expect_eq(blob[0], u8(1), "generic blob byte 0 should round-trip")
	expect_eq(blob[1], u8(2), "generic blob byte 1 should round-trip")
	expect_eq(blob[2], u8(3), "generic blob byte 2 should round-trip")
}

test_bind_named_generic_bind_arg_roundtrip :: proc() {
	test_db := test_db_open("bind_named_generic_bind_arg_roundtrip")
	defer test_db_close(&test_db)

	sql := "SELECT :a, :b, :c"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	err, ok := sqlite.stmt_bind_named(&stmt, ":a", sqlite.bind_arg_i64(5))
	expect_no_error(err, ok, "stmt_bind_named i64 should succeed")

	err, ok = sqlite.stmt_bind_named(&stmt, ":b", sqlite.bind_arg_text("golf"))
	expect_no_error(err, ok, "stmt_bind_named text should succeed")

	err, ok = sqlite.stmt_bind_named(&stmt, ":c", sqlite.bind_arg_null())
	expect_no_error(err, ok, "stmt_bind_named null should succeed")

	step_expect_row(stmt, sql)

	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(5), "generic named i64 bind should round-trip")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "golf", "generic named text bind should round-trip")
	expect_true(sqlite.stmt_is_null(stmt, 2), "generic named null bind should round-trip")
}

test_bind_reuse_does_not_leave_stale_parameters :: proc() {
	test_db := test_db_open("bind_reuse_does_not_leave_stale_parameters")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_i64_ok(&stmt, 1, 100, sql)
	bind_text_ok(&stmt, 2, "hotel", sql)

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(100), "first execution should return first bound value")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "hotel", "first execution should return second bound value")

	err, ok := sqlite.stmt_reuse(&stmt)
	expect_no_error(err, ok, "stmt_reuse should succeed")

	step_expect_row(stmt, sql)
	expect_true(sqlite.stmt_is_null(stmt, 0), "reuse should clear first bound parameter")
	expect_true(sqlite.stmt_is_null(stmt, 1), "reuse should clear second bound parameter")
}

test_bind_reset_preserves_bindings_until_cleared :: proc() {
	test_db := test_db_open("bind_reset_preserves_bindings_until_cleared")
	defer test_db_close(&test_db)

	sql := "SELECT ?1, ?2"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	bind_i64_ok(&stmt, 1, 33, sql)
	bind_text_ok(&stmt, 2, "india", sql)

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(33), "first execution should return bound integer")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "india", "first execution should return bound text")

	reset_ok(&stmt, sql)

	step_expect_row(stmt, sql)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(33), "reset should preserve integer binding")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "india", "reset should preserve text binding")

	clear_bindings_ok(&stmt, sql)
	reset_ok(&stmt, sql)

	step_expect_row(stmt, sql)
	expect_true(sqlite.stmt_is_null(stmt, 0), "clear_bindings should clear integer binding")
	expect_true(sqlite.stmt_is_null(stmt, 1), "clear_bindings should clear text binding")
}

test_bind_invalid_index_returns_range_error :: proc() {
	test_db := test_db_open("bind_invalid_index_returns_range_error")
	defer test_db_close(&test_db)

	sql := "SELECT ?1"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	err, ok := sqlite.stmt_bind_i64(&stmt, 0, 1)
	expect_error(err, ok, int(raw.MISUSE), "binding at index 0 should fail with misuse in wrapper")

	err, ok = sqlite.stmt_bind_i64(&stmt, 2, 1)
	expect_error(err, ok, int(raw.RANGE), "binding past parameter count should fail with SQLITE_RANGE")
}

test_bind_missing_named_parameter_returns_range_error :: proc() {
	test_db := test_db_open("bind_missing_named_parameter_returns_range_error")
	defer test_db_close(&test_db)

	sql := "SELECT :present"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	err, ok := sqlite.stmt_bind_named_i64(&stmt, ":missing", 10)
	expect_error(err, ok, int(raw.RANGE), "binding missing named parameter should fail with SQLITE_RANGE")
}