package engine_runtime

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import raw "../../../sqlite/raw/generated"

DEFAULT_OPEN_FLAGS :: i32(raw.OPEN_READWRITE | raw.OPEN_CREATE | raw.OPEN_URI | raw.OPEN_FULLMUTEX)

empty_blob_sentinel: u8

fail :: proc(message: string, args: ..any) -> ! {
	panic(fmt.tprintf(message, ..args))
}

expect :: proc(condition: bool, message: string, args: ..any) {
	if !condition {
		fail(message, ..args)
	}
}

expect_eq :: proc(actual, expected: $T, message: string, args: ..any) {
	if actual != expected {
		prefix := fmt.tprintf(message, ..args)
		fail("%s | actual=%v expected=%v", prefix, actual, expected)
	}
}

primary_code :: proc(code: i32) -> i32 {
	return code & 0xff
}

expect_rc :: proc(actual, expected: i32, operation: string) {
	if actual != expected {
		fail("%s | actual SQLite code=%d expected=%d", operation, actual, expected)
	}
}

expect_primary_rc :: proc(actual, expected: i32, operation: string) {
	if primary_code(actual) != expected {
		fail(
			"%s | actual SQLite code=%d primary=%d expected primary=%d",
			operation,
			actual,
			primary_code(actual),
			expected,
		)
	}
}

cstring_equals :: proc(value: cstring, expected: string) -> bool {
	if value == nil {
		return false
	}
	return string(value) == expected
}

open_db_with_flags :: proc(path: string, flags: i32) -> ^raw.Sqlite3 {
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	db: ^raw.Sqlite3
	rc := raw.open_v2(c_path, &db, flags, nil)
	if rc != raw.OK {
		if db != nil {
			_ = raw.close_v2(db)
		}
		fail("sqlite3_open_v2(%q) failed with code=%d", path, rc)
	}
	expect(db != nil, "sqlite3_open_v2(%q) returned SQLITE_OK with a nil handle", path)
	expect_rc(raw.extended_result_codes(db, 1), raw.OK, "enable extended result codes")
	return db
}

open_db :: proc(path: string) -> ^raw.Sqlite3 {
	return open_db_with_flags(path, DEFAULT_OPEN_FLAGS)
}

close_db :: proc(db: ^^raw.Sqlite3) {
	if db == nil || db^ == nil {
		return
	}
	rc := raw.close(db^)
	expect_rc(rc, raw.OK, "sqlite3_close")
	db^ = nil
}

exec_rc :: proc(db: ^raw.Sqlite3, sql: string) -> i32 {
	c_sql := strings.clone_to_cstring(sql)
	defer delete(c_sql)

	error_message: cstring
	rc := raw.exec(db, c_sql, nil, nil, &error_message)
	if error_message != nil {
		raw.free(rawptr(error_message))
	}
	return rc
}

exec_ok :: proc(db: ^raw.Sqlite3, sql: string) {
	expect_rc(exec_rc(db, sql), raw.OK, fmt.tprintf("sqlite3_exec(%q)", sql))
}

prepare_rc :: proc(db: ^raw.Sqlite3, sql: string, statement: ^^raw.Stmt) -> i32 {
	c_sql := strings.clone_to_cstring(sql)
	defer delete(c_sql)
	return raw.prepare_v2(db, c_sql, i32(len(sql)), statement, nil)
}

prepare_ok :: proc(db: ^raw.Sqlite3, sql: string) -> ^raw.Stmt {
	statement: ^raw.Stmt
	rc := prepare_rc(db, sql, &statement)
	expect_rc(rc, raw.OK, fmt.tprintf("sqlite3_prepare_v2(%q)", sql))
	expect(statement != nil, "sqlite3_prepare_v2(%q) returned SQLITE_OK with a nil statement", sql)
	return statement
}

finalize_ok :: proc(statement: ^^raw.Stmt) {
	if statement == nil || statement^ == nil {
		return
	}
	rc := raw.finalize(statement^)
	expect_rc(rc, raw.OK, "sqlite3_finalize")
	statement^ = nil
}

bind_i64_ok :: proc(statement: ^raw.Stmt, index: i32, value: i64) {
	expect_rc(raw.bind_int64(statement, index, raw.Int64(value)), raw.OK, "sqlite3_bind_int64")
}

bind_double_ok :: proc(statement: ^raw.Stmt, index: i32, value: f64) {
	expect_rc(raw.bind_double(statement, index, value), raw.OK, "sqlite3_bind_double")
}

bind_null_ok :: proc(statement: ^raw.Stmt, index: i32) {
	expect_rc(raw.bind_null(statement, index), raw.OK, "sqlite3_bind_null")
}

bind_text_ok :: proc(statement: ^raw.Stmt, index: i32, value: string) {
	c_value := strings.clone_to_cstring(value)
	defer delete(c_value)
	rc := raw.bind_text64(
		statement,
		index,
		c_value,
		raw.Uint64(len(value)),
		raw.TRANSIENT,
		u8(raw.UTF8),
	)
	expect_rc(rc, raw.OK, "sqlite3_bind_text64")
}

bind_blob_ok :: proc(statement: ^raw.Stmt, index: i32, value: []u8) {
	pointer := rawptr(&empty_blob_sentinel)
	if len(value) > 0 {
		pointer = rawptr(&value[0])
	}
	rc := raw.bind_blob64(statement, index, pointer, raw.Uint64(len(value)), raw.TRANSIENT)
	expect_rc(rc, raw.OK, "sqlite3_bind_blob64")
}

step_row :: proc(statement: ^raw.Stmt) {
	expect_rc(raw.step(statement), raw.ROW, "sqlite3_step expected SQLITE_ROW")
}

step_done :: proc(statement: ^raw.Stmt) {
	expect_rc(raw.step(statement), raw.DONE, "sqlite3_step expected SQLITE_DONE")
}

expect_column_text :: proc(statement: ^raw.Stmt, column: i32, expected: string) {
	expect_eq(raw.column_type(statement, column), raw.TEXT, "column type must be SQLITE_TEXT")
	byte_count := int(raw.column_bytes(statement, column))
	expect_eq(byte_count, len(expected), "text byte count")
	pointer := raw.column_text(statement, column)
	expect(pointer != nil, "non-NULL text value must expose a byte pointer")
	actual := string(([^]u8)(pointer)[:byte_count])
	expect_eq(actual, expected, "text bytes")
}

expect_column_blob :: proc(statement: ^raw.Stmt, column: i32, expected: []u8) {
	expect_eq(raw.column_type(statement, column), raw.BLOB, "column type must be SQLITE_BLOB")
	byte_count := int(raw.column_bytes(statement, column))
	expect_eq(byte_count, len(expected), "blob byte count")
	if byte_count == 0 {
		return
	}
	pointer := raw.column_blob(statement, column)
	expect(pointer != nil, "non-empty blob value must expose a byte pointer")
	actual := ([^]u8)(pointer)[:byte_count]
	for byte, index in actual {
		expect_eq(byte, expected[index], "blob byte %d", index)
	}
}

query_i64 :: proc(db: ^raw.Sqlite3, sql: string) -> i64 {
	statement := prepare_ok(db, sql)
	defer finalize_ok(&statement)
	step_row(statement)
	value := i64(raw.column_int64(statement, 0))
	step_done(statement)
	return value
}

query_text :: proc(db: ^raw.Sqlite3, sql: string) -> string {
	statement := prepare_ok(db, sql)
	defer finalize_ok(&statement)
	step_row(statement)
	pointer := raw.column_text(statement, 0)
	expect(pointer != nil, "query %q returned NULL text", sql)
	byte_count := int(raw.column_bytes(statement, 0))
	value := strings.clone(string(([^]u8)(pointer)[:byte_count]))
	step_done(statement)
	return value
}

query_count_by_name :: proc(db: ^raw.Sqlite3, name: string) -> i64 {
	statement := prepare_ok(db, "SELECT count(*) FROM sqlite_master WHERE name=?1")
	defer finalize_ok(&statement)
	bind_text_ok(statement, 1, name)
	step_row(statement)
	count := i64(raw.column_int64(statement, 0))
	step_done(statement)
	return count
}

insert_i64 :: proc(db: ^raw.Sqlite3, sql: string, value: i64) -> i32 {
	statement := prepare_ok(db, sql)
	bind_i64_ok(statement, 1, value)
	rc := raw.step(statement)
	finalize_rc := raw.finalize(statement)
	if rc == raw.DONE {
		expect_rc(finalize_rc, raw.OK, "finalize successful integer statement")
	} else {
		expect_primary_rc(finalize_rc, primary_code(rc), "finalize failed integer statement")
	}
	return rc
}

make_temp_db_path :: proc(name: string) -> string {
	base, temp_error := os.temp_directory(context.allocator)
	expect(temp_error == os.ERROR_NONE, "could not resolve temporary directory: %v", temp_error)
	defer delete(base)

	path, join_error := filepath.join(
		{base, fmt.tprintf("odin_sqlite_engine_runtime_%s.sqlite3", name)},
		context.allocator,
	)
	expect(join_error == nil, "could not build temporary database path: %v", join_error)
	return path
}

remove_if_present :: proc(path: string) {
	_, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		return
	}
	remove_error := os.remove(path)
	expect(remove_error == os.ERROR_NONE, "could not remove temporary SQLite file %q: %v", path, remove_error)
}

remove_db_files :: proc(path: string) {
	remove_if_present(path)
	remove_if_present(fmt.tprintf("%s-journal", path))
	remove_if_present(fmt.tprintf("%s-wal", path))
	remove_if_present(fmt.tprintf("%s-shm", path))
}

run_contract :: proc(name: string, contract: proc()) {
	fmt.printf("RUN  %s\n", name)
	contract()
	fmt.printf("PASS %s\n", name)
}

run_all_contracts :: proc() {
	require_pinned_runtime()
	run_contract("prepare_tail_bind_reset_clear_and_metadata", test_prepare_tail_bind_reset_clear_and_metadata)
	run_contract("schema_change_auto_reprepare", test_schema_change_auto_reprepare)
	run_contract("exact_text_blob_null_transport", test_exact_text_blob_null_transport)
	run_contract("numeric_boundaries_and_conversion", test_numeric_boundaries_and_conversion)
	run_contract("file_persistence_and_uri_modes", test_file_persistence_and_uri_modes)
	run_contract("memory_isolation_and_named_shared_memory", test_memory_isolation_and_named_shared_memory)
	run_contract("transaction_isolation_locking_and_busy_timeout", test_transaction_isolation_locking_and_busy_timeout)
	run_contract("wal_snapshot_visibility_and_checkpoint", test_wal_snapshot_visibility_and_checkpoint)
	run_contract("progress_interrupt_and_recovery", test_progress_interrupt_and_recovery)
	run_contract("scalar_aggregate_function_registration", test_scalar_aggregate_function_registration)
	run_contract("collation_authorizer_and_teardown", test_collation_authorizer_and_teardown)
	run_contract("backup_roundtrip_and_progress", test_backup_roundtrip_and_progress)
	run_contract("incremental_blob_bounds_and_reopen", test_incremental_blob_bounds_and_reopen)
	run_contract("serialize_deserialize_readonly_ownership", test_serialize_deserialize_readonly_ownership)
}

main :: proc() {
	tracking_allocator: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking_allocator, context.allocator)
	context.allocator = mem.tracking_allocator(&tracking_allocator)

	fmt.println("== SQLite engine runtime feature contracts ==")
	run_all_contracts()
	fmt.println("== all SQLite engine runtime contracts passed ==")

	leak_count := len(tracking_allocator.allocation_map)
	bad_free_count := len(tracking_allocator.bad_free_array)
	if leak_count > 0 {
		fmt.eprintf("=== %d allocations not freed ===\n", leak_count)
		for _, entry in tracking_allocator.allocation_map {
			fmt.eprintf("- %d bytes @ %v\n", entry.size, entry.location)
		}
	}
	if bad_free_count > 0 {
		fmt.eprintf("=== %d incorrect frees ===\n", bad_free_count)
		for entry in tracking_allocator.bad_free_array {
			fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
		}
	}
	mem.tracking_allocator_destroy(&tracking_allocator)
	if leak_count > 0 || bad_free_count > 0 {
		os.exit(1)
	}
	os.exit(0)
}
