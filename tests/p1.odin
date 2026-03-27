package tests

import "core:fmt"
import sqlite "../sqlite"
import raw "../sqlite/raw/generated"

trace_capture_target: ^[dynamic]string

trace_capture_logger :: proc(event: sqlite.Trace_Event, message: string) {
	if trace_capture_target == nil {
		return
	}
	append(trace_capture_target, fmt.tprintf("%v|%s", event, message))
}

test_structured_error_model :: proc() {
	test_db := test_db_open("p1_structured_error_model")
	defer test_db_close(&test_db)

	err, ok := sqlite.db_exec(test_db.db, "SELECT * FROM p1_missing_table")
	expect_false(ok, "exec against missing table should fail")
	expect_eq(err.code, int(raw.ERROR), "structured error should preserve primary sqlite result code")
	expect_true(err.extended_code != 0, "structured error should preserve extended sqlite result code")
	expect_string_contains(err.message, "no such table", "structured error should preserve sqlite message")
	expect_eq(err.sql, "SELECT * FROM p1_missing_table", "structured error should preserve SQL context")

	err_with_ctx := sqlite.error_with_context(err, "during p1 structured error test")
	expect_true(sqlite.error_has_context(err_with_ctx), "error_with_context should attach context")
	expect_string_contains(sqlite.error_string(err_with_ctx), "context=", "formatted error should include context when present")

	err_with_op := sqlite.error_with_op(err_with_ctx, "exec")
	expect_true(sqlite.error_has_op(err_with_op), "error_with_op should attach operation name")
	expect_string_contains(sqlite.error_string(err_with_op), "op=", "formatted error should include operation when present")

	err_with_sql := sqlite.error_with_sql(sqlite.error_none(), "SELECT 1")
	expect_true(sqlite.error_has_sql(err_with_sql), "error_with_sql should attach sql to an error value")

	expect_eq(sqlite.error_code_name(int(raw.ERROR)), "SQLITE_ERROR", "error_code_name should format known sqlite result names")
	expect_string_contains(sqlite.error_summary(err), "SQLITE_ERROR", "error_summary should include sqlite code name")
	expect_string_contains(sqlite.error_summary(err), "no such table", "error_summary should include sqlite message")
	expect_eq(sqlite.error_string(sqlite.error_none()), "sqlite: ok", "error_string should format ok value")
	expect_true(sqlite.error_is_none(sqlite.error_none()), "error_is_none should detect ok value")
	expect_false(sqlite.error_ok(err), "error_ok should be false for non-ok errors")
}

test_tracing_and_debug_helpers :: proc() {
	test_db := test_db_open("p1_tracing_and_debug_helpers")
	defer test_db_close(&test_db)

	expect_false(sqlite.db_trace_enabled(test_db.db), "tracing should be disabled by default")

	config := sqlite.Trace_Config{
		events              = make([dynamic]sqlite.Trace_Event),
		log_expanded_sql    = true,
		log_errors_only     = false,
		include_row_events  = true,
		include_close_event = true,
	}
	defer delete(config.events)
	append(&config.events, sqlite.Trace_Event.Statement)
	append(&config.events, sqlite.Trace_Event.Profile)

	err, ok := sqlite.db_trace_enable(&test_db.db, config)
	expect_no_error(err, ok, "db_trace_enable should succeed for open database")

	expect_true(sqlite.db_trace_enabled(test_db.db), "tracing should report enabled after registration")

	got_config := sqlite.db_trace_config(test_db.db)
	expect_true(got_config.log_expanded_sql, "trace config should preserve expanded-sql option")
	expect_true(got_config.include_row_events, "trace config should preserve row event option")
	expect_true(got_config.include_close_event, "trace config should preserve close event option")
	expect_eq(len(got_config.events), 2, "trace config should preserve explicit event list")
	expect_eq(got_config.events[0], sqlite.Trace_Event.Statement, "trace config event order should be preserved")
	expect_eq(got_config.events[1], sqlite.Trace_Event.Profile, "trace config event order should be preserved")

	stmt := prepare_ok(test_db.db, "SELECT ?1")
	defer finalize_ok(&stmt, "SELECT ?1")

	bind_i64_ok(&stmt, 1, 42, "SELECT ?1")
	expected_sql := sqlite.stmt_expanded_sql(stmt, context.temp_allocator)
	expect_string_contains(expected_sql, "42", "expanded SQL should reflect bound parameter value")

	captured := make([dynamic]string)
	defer delete(captured)
	trace_capture_target = &captured
	defer trace_capture_target = nil

	sqlite.db_trace_log_stmt(test_db.db, stmt, trace_capture_logger, "before step")
	sqlite.db_trace_log_profile(test_db.db, stmt, 1234, trace_capture_logger)
	sqlite.db_trace_log_row(test_db.db, stmt, trace_capture_logger, "row ready")
	sqlite.db_trace_log_close(test_db.db, trace_capture_logger, "close requested")

	expect_true(len(captured) >= 4, "trace logging helpers should emit configured events")
	expect_string_contains(captured[0], "before step", "statement trace log should include detail")
	expect_string_contains(captured[0], "42", "statement trace log should use expanded SQL when configured")
	expect_string_contains(captured[1], "elapsed_ns=1234", "profile trace log should include elapsed time")
	expect_string_contains(captured[2], "row ready", "row trace log should include detail")
	expect_string_contains(captured[3], "close requested", "close trace log should include detail")

	err, ok = sqlite.db_trace_disable(&test_db.db)
	expect_no_error(err, ok, "db_trace_disable should succeed for open database")
	expect_false(sqlite.db_trace_enabled(test_db.db), "tracing should report disabled after unregister")

	captured_after_disable := len(captured)
	sqlite.db_trace_log_stmt(test_db.db, stmt, trace_capture_logger, "after disable")
	expect_eq(len(captured), captured_after_disable, "trace logging helpers should not emit after tracing is disabled")
}

test_blob_api :: proc() {
	test_db := test_db_open("p1_blob_api")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE blob_items(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO blob_items(payload) VALUES (zeroblob(5))")

	blob, err, ok := sqlite.blob_open(test_db.db, "main", "blob_items", "payload", 1, .ReadWrite)
	expect_no_error(err, ok, "blob_open read-write should succeed for existing zeroblob row")
	defer {
		close_err, close_ok := sqlite.blob_close(&blob)
		expect_no_error(close_err, close_ok, "blob_close should succeed")
	}

	expect_true(sqlite.blob_is_valid(blob), "blob handle should be valid after blob_open")
	expect_eq(sqlite.blob_bytes(blob), 5, "blob_bytes should report opened blob size")

	write_err, write_ok := sqlite.blob_write(blob, []u8{10, 20, 30, 40, 50}, 0)
	expect_no_error(write_err, write_ok, "blob_write should succeed for exact-size write")

	read_back, read_err, read_ok := sqlite.blob_read_all(blob)
	defer delete(read_back)
	expect_no_error(read_err, read_ok, "blob_read_all should succeed")
	expect_eq(len(read_back), 5, "blob_read_all should return full blob size")
	expect_eq(read_back[0], u8(10), "blob data byte 0 should round-trip")
	expect_eq(read_back[1], u8(20), "blob data byte 1 should round-trip")
	expect_eq(read_back[2], u8(30), "blob data byte 2 should round-trip")
	expect_eq(read_back[3], u8(40), "blob data byte 3 should round-trip")
	expect_eq(read_back[4], u8(50), "blob data byte 4 should round-trip")

	exec_ok(test_db.db, "INSERT INTO blob_items(payload) VALUES (x'0908070605')")

	reopen_err, reopen_ok := sqlite.blob_reopen(&blob, 2)
	expect_no_error(reopen_err, reopen_ok, "blob_reopen should succeed for another row in same table")

	read_buf := make([]u8, 3)
	defer delete(read_buf)
	read_n, partial_err, partial_ok := sqlite.blob_read_into(blob, read_buf, 1)
	expect_no_error(partial_err, partial_ok, "blob_read_into should succeed for in-range partial read")
	expect_eq(read_n, 3, "blob_read_into should report number of bytes read")
	expect_eq(read_buf[0], u8(8), "partial read byte 0 should match source blob")
	expect_eq(read_buf[1], u8(7), "partial read byte 1 should match source blob")
	expect_eq(read_buf[2], u8(6), "partial read byte 2 should match source blob")

	read_only_blob, ro_err, ro_ok := sqlite.blob_open(test_db.db, "main", "blob_items", "payload", 2, .ReadOnly)
	expect_no_error(ro_err, ro_ok, "blob_open read-only should succeed for existing row")
	defer {
		close_err, close_ok := sqlite.blob_close(&read_only_blob)
		expect_no_error(close_err, close_ok, "blob_close should succeed for read-only blob")
	}

	write_err, write_ok = sqlite.blob_write(read_only_blob, []u8{1}, 0)
	expect_false(write_ok, "blob_write should fail for read-only handle")
	expect_eq(write_err.code, int(raw.READONLY), "blob_write should report SQLITE_READONLY for read-only handle")
	expect_string_contains(sqlite.error_string(write_err), "blob_write", "blob_write error should include operation context")
}

test_backup_api :: proc() {
	src := test_db_open("p1_backup_api_src")
	defer test_db_close(&src)

	dst := test_db_open("p1_backup_api_dst")
	defer test_db_close(&dst)

	exec_ok(src.db, "CREATE TABLE backup_items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(src.db, "INSERT INTO backup_items(name) VALUES ('alpha'), ('beta'), ('gamma')")

	backup, err, ok := sqlite.backup_init(dst.db, src.db)
	expect_no_error(err, ok, "backup_init should succeed between distinct open databases")
	defer {
		finish_err, finish_ok := sqlite.backup_finish(&backup)
		expect_no_error(finish_err, finish_ok, "backup_finish should succeed after backup")
	}

	expect_true(sqlite.backup_is_valid(backup), "backup handle should be valid after backup_init")

	progress_before := sqlite.backup_progress(backup)
	expect_true(progress_before.remaining_pages >= 0, "backup_progress remaining pages should be non-negative")
	expect_true(progress_before.total_pages >= 0, "backup_progress total pages should be non-negative")

	for {
		step_result, step_err, step_ok := sqlite.backup_step(backup, 1)
		expect_no_error(step_err, step_ok, "backup_step should succeed while copying pages")

		progress := sqlite.backup_progress(backup)
		expect_true(progress.remaining_pages >= 0, "backup_progress remaining pages should stay non-negative")
		expect_true(progress.total_pages >= 0, "backup_progress total pages should stay non-negative")

		if step_result == .Done {
			break
		}

		expect_true(step_result == .Ok || step_result == .Busy || step_result == .Locked, "backup_step should return expected in-progress state")
		if step_result == .Busy || step_result == .Locked {
			test_fail("backup_step returned retryable lock state in single-process smoke test")
		}
	}

	count, scalar_err, scalar_ok := sqlite.db_scalar_i64(dst.db, "SELECT COUNT(*) FROM backup_items")
	expect_no_error(scalar_err, scalar_ok, "destination database should be queryable after backup")
	expect_eq(count, i64(3), "backup should copy all source rows to destination")

	names_stmt := prepare_ok(dst.db, "SELECT name FROM backup_items ORDER BY id")
	defer finalize_ok(&names_stmt, "SELECT name FROM backup_items ORDER BY id")

	step_expect_row(names_stmt, "SELECT name FROM backup_items ORDER BY id")
	expect_eq(sqlite.stmt_get_text(names_stmt, 0, context.temp_allocator), "alpha", "backup should copy first row")

	step_expect_row(names_stmt, "SELECT name FROM backup_items ORDER BY id")
	expect_eq(sqlite.stmt_get_text(names_stmt, 0, context.temp_allocator), "beta", "backup should copy second row")

	step_expect_row(names_stmt, "SELECT name FROM backup_items ORDER BY id")
	expect_eq(sqlite.stmt_get_text(names_stmt, 0, context.temp_allocator), "gamma", "backup should copy third row")

	step_expect_done(names_stmt, "SELECT name FROM backup_items ORDER BY id")
}