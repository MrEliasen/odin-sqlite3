package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sqlite "../sqlite"

Test_DB :: struct {
	path: string,
	db:   sqlite.DB,
}

test_fail :: proc(message: string, args: ..any) -> ! {
	panic(fmt.tprintf(message, ..args))
}

expect_true :: proc(value: bool, message: string, args: ..any) {
	if !value {
		test_fail(message, ..args)
	}
}

expect_false :: proc(value: bool, message: string, args: ..any) {
	if value {
		test_fail(message, ..args)
	}
}

expect_eq :: proc(actual, expected: $T, message: string, args: ..any) {
	if actual != expected {
		prefix := fmt.tprintf(message, ..args)
		test_fail("%s | actual=%v expected=%v", prefix, actual, expected)
	}
}

expect_ne :: proc(actual, expected: $T, message: string, args: ..any) {
	if actual == expected {
		prefix := fmt.tprintf(message, ..args)
		test_fail("%s | value=%v", prefix, actual)
	}
}

expect_no_error :: proc(err: sqlite.Error, ok: bool, message: string, args: ..any) {
	if !ok {
		prefix := fmt.tprintf(message, ..args)
		test_fail("%s | %s", prefix, sqlite.error_string(err))
	}
}

expect_error :: proc(err: sqlite.Error, ok: bool, expected_code: int, message: string, args: ..any) {
	if ok {
		prefix := fmt.tprintf(message, ..args)
		test_fail("%s | expected error code=%v but call succeeded", prefix, expected_code)
	}
	if err.code != expected_code {
		prefix := fmt.tprintf(message, ..args)
		test_fail("%s | actual error=%s expected_code=%v", prefix, sqlite.error_string(err), expected_code)
	}
}

expect_step :: proc(actual: sqlite.Step_Result, expected: sqlite.Step_Result, message: string, args: ..any) {
	if actual != expected {
		prefix := fmt.tprintf(message, ..args)
		test_fail("%s | actual step=%v expected=%v", prefix, actual, expected)
	}
}

expect_string_contains :: proc(haystack: string, needle: string, message: string, args: ..any) {
	if needle == "" {
		test_fail("test bug: needle must not be empty")
	}
	if !contains_string(haystack, needle) {
		prefix := fmt.tprintf(message, ..args)
		test_fail("%s | did not find %q in %q", prefix, needle, haystack)
	}
}

contains_string :: proc(haystack: string, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i := 0; i <= len(haystack)-len(needle); i += 1 {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

make_temp_db_path :: proc(test_name: string) -> string {
	base_dir, temp_err := os.temp_directory(context.allocator)
	expect_true(temp_err == os.ERROR_NONE, "failed to get temp dir: %v", temp_err)
	expect_true(len(base_dir) > 0, "failed to get temp dir")
	defer delete(base_dir)

	safe_name := sanitize_name(test_name)
	defer delete(safe_name)
	joined_path, join_err := filepath.join({base_dir, fmt.tprintf("odin_sqlite_%s.sqlite3", safe_name)}, context.allocator)
	expect_true(join_err == nil, "failed to join temp db path: %v", join_err)
	return joined_path
}

sanitize_name :: proc(name: string) -> string {
	if len(name) == 0 {
		return strings.clone("unnamed")
	}

	out: [dynamic]u8
	for ch in name {
		if (ch >= 'a' && ch <= 'z') ||
		   (ch >= 'A' && ch <= 'Z') ||
		   (ch >= '0' && ch <= '9') {
			append(&out, u8(ch))
		} else {
			append(&out, u8('_'))
		}
	}

	return string(out[:])
}

remove_file_if_exists :: proc(path: string) {
	if path == "" {
		return
	}

	_, stat_err := os.stat(path, context.temp_allocator)
	if stat_err != nil {
		return
	}

	remove_err := os.remove(path)
	if remove_err != os.ERROR_NONE {
		test_fail("failed removing file %q: %v", path, remove_err)
	}
}

test_db_open :: proc(test_name: string) -> Test_DB {
	path := make_temp_db_path(test_name)
	remove_file_if_exists(path)

	db, err, ok := sqlite.db_open(path)
	expect_no_error(err, ok, "opening temp db for %q", test_name)

	return Test_DB{
		path = path,
		db   = db,
	}
}

test_db_close :: proc(test_db: ^Test_DB) {
	if test_db == nil {
		return
	}

	err, ok := sqlite.db_close(&test_db.db)
	expect_no_error(err, ok, "closing temp db %q", test_db.path)

	remove_file_if_exists(test_db.path)
	delete(test_db.path)
	test_db.path = ""
}

test_db_reopen :: proc(test_db: ^Test_DB) {
	expect_true(test_db != nil, "test bug: test_db must not be nil")

	err, ok := sqlite.db_close(&test_db.db)
	expect_no_error(err, ok, "closing db before reopen %q", test_db.path)

	db, open_err, open_ok := sqlite.db_open(test_db.path)
	expect_no_error(open_err, open_ok, "reopening db %q", test_db.path)
	test_db.db = db
}

exec_ok :: proc(db: sqlite.DB, sql: string) {
	err, ok := sqlite.db_exec(db, sql)
	expect_no_error(err, ok, "exec failed for sql: %q", sql)
}

prepare_ok :: proc(db: sqlite.DB, sql: string) -> sqlite.Stmt {
	stmt, err, ok := sqlite.stmt_prepare(db, sql)
	expect_no_error(err, ok, "prepare failed for sql: %q", sql)
	return stmt
}

finalize_ok :: proc(stmt: ^sqlite.Stmt, sql: string = "") {
	err, ok := sqlite.stmt_finalize(stmt)
	expect_no_error(err, ok, "finalize failed for sql: %q", sql)
}

reset_ok :: proc(stmt: ^sqlite.Stmt, sql: string = "") {
	err, ok := sqlite.stmt_reset(stmt)
	expect_no_error(err, ok, "reset failed for sql: %q", sql)
}

clear_bindings_ok :: proc(stmt: ^sqlite.Stmt, sql: string = "") {
	err, ok := sqlite.stmt_clear_bindings(stmt)
	expect_no_error(err, ok, "clear_bindings failed for sql: %q", sql)
}

step_expect_row :: proc(stmt: sqlite.Stmt, sql: string = "") {
	result, err, ok := sqlite.stmt_step(stmt)
	expect_no_error(err, ok, "step failed for sql: %q", sql)
	expect_step(result, .Row, "expected row for sql: %q", sql)
}

step_expect_done :: proc(stmt: sqlite.Stmt, sql: string = "") {
	result, err, ok := sqlite.stmt_step(stmt)
	expect_no_error(err, ok, "step failed for sql: %q", sql)
	expect_step(result, .Done, "expected done for sql: %q", sql)
}

bind_i64_ok :: proc(stmt: ^sqlite.Stmt, index: int, value: i64, sql: string = "") {
	err, ok := sqlite.stmt_bind_i64(stmt, index, value)
	expect_no_error(err, ok, "bind_i64 failed at index=%v for sql: %q", index, sql)
}

bind_i32_ok :: proc(stmt: ^sqlite.Stmt, index: int, value: i32, sql: string = "") {
	err, ok := sqlite.stmt_bind_i32(stmt, index, value)
	expect_no_error(err, ok, "bind_i32 failed at index=%v for sql: %q", index, sql)
}

bind_f64_ok :: proc(stmt: ^sqlite.Stmt, index: int, value: f64, sql: string = "") {
	err, ok := sqlite.stmt_bind_f64(stmt, index, value)
	expect_no_error(err, ok, "bind_f64 failed at index=%v for sql: %q", index, sql)
}

bind_text_ok :: proc(stmt: ^sqlite.Stmt, index: int, value: string, sql: string = "") {
	err, ok := sqlite.stmt_bind_text(stmt, index, value)
	expect_no_error(err, ok, "bind_text failed at index=%v for sql: %q", index, sql)
}

bind_blob_ok :: proc(stmt: ^sqlite.Stmt, index: int, value: []u8, sql: string = "") {
	err, ok := sqlite.stmt_bind_blob(stmt, index, value)
	expect_no_error(err, ok, "bind_blob failed at index=%v for sql: %q", index, sql)
}

bind_null_ok :: proc(stmt: ^sqlite.Stmt, index: int, sql: string = "") {
	err, ok := sqlite.stmt_bind_null(stmt, index)
	expect_no_error(err, ok, "bind_null failed at index=%v for sql: %q", index, sql)
}

bind_named_i64_ok :: proc(stmt: ^sqlite.Stmt, name: string, value: i64, sql: string = "") {
	err, ok := sqlite.stmt_bind_named_i64(stmt, name, value)
	expect_no_error(err, ok, "bind_named_i64 failed for %q sql: %q", name, sql)
}

bind_named_text_ok :: proc(stmt: ^sqlite.Stmt, name: string, value: string, sql: string = "") {
	err, ok := sqlite.stmt_bind_named_text(stmt, name, value)
	expect_no_error(err, ok, "bind_named_text failed for %q sql: %q", name, sql)
}