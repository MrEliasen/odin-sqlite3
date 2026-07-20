package main

import sqlite "../../../sqlite"
import "core:fmt"
import "core:os"
import "core:path/filepath"

Fixture :: struct {
	path: string,
	db:   sqlite.DB,
}

fail :: proc(message: string, args: ..any) -> ! {
	panic(fmt.tprintf(message, ..args))
}

expect :: proc(condition: bool, message: string, args: ..any) {
	if !condition {
		fail(message, ..args)
	}
}

expect_equal :: proc(actual, expected: $T, message: string, args: ..any) {
	if actual != expected {
		prefix := fmt.tprintf(message, ..args)
		fail("%s | actual=%v expected=%v", prefix, actual, expected)
	}
}

expect_bytes_equal :: proc(actual, expected: []u8, message: string) {
	expect_equal(len(actual), len(expected), "%s length", message)
	for value, index in expected {
		expect_equal(actual[index], value, "%s byte %d", message, index)
	}
}

expect_text_bytes_equal :: proc(actual, expected: string, message: string) {
	expect_equal(len(actual), len(expected), "%s byte length", message)
	for value, index in expected {
		expect_equal(actual[index], u8(value), "%s byte %d", message, index)
	}
}

contains_text :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for index := 0; index <= len(haystack) - len(needle); index += 1 {
		if haystack[index:index + len(needle)] == needle {
			return true
		}
	}
	return false
}

expect_contains :: proc(haystack, needle, message: string) {
	expect(contains_text(haystack, needle), "%s | missing %q in %q", message, needle, haystack)
}

remove_if_present :: proc(path: string) {
	_, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		return
	}
	remove_error := os.remove(path)
	expect(remove_error == os.ERROR_NONE, "could not remove %q: %v", path, remove_error)
}

remove_fixture_files :: proc(path: string) {
	remove_if_present(path)
	remove_if_present(fmt.tprintf("%s-journal", path))
	remove_if_present(fmt.tprintf("%s-wal", path))
	remove_if_present(fmt.tprintf("%s-shm", path))
}

open_fixture :: proc(name: string) -> Fixture {
	temp_dir, temp_error := os.temp_directory(context.allocator)
	expect(temp_error == os.ERROR_NONE, "could not resolve temporary directory: %v", temp_error)
	defer delete(temp_dir)

	path, join_error := filepath.join(
		{temp_dir, fmt.tprintf("odin_sqlite_sql_language_%s.sqlite3", name)},
		context.allocator,
	)
	expect(join_error == nil, "could not construct temporary database path: %v", join_error)
	remove_fixture_files(path)

	db, open_error, ok := sqlite.db_open(path)
	expect_no_error(open_error, ok, "open fixture %q", name)
	return Fixture{path = path, db = db}
}

close_fixture :: proc(fixture: ^Fixture) {
	if fixture == nil {
		return
	}
	close_error, ok := sqlite.db_close(&fixture.db)
	expect_no_error(close_error, ok, "close fixture %q", fixture.path)
	remove_fixture_files(fixture.path)
	delete(fixture.path)
	fixture.path = ""
}

reopen_fixture :: proc(fixture: ^Fixture) {
	expect(fixture != nil, "fixture must not be nil")
	close_error, close_ok := sqlite.db_close(&fixture.db)
	expect_no_error(close_error, close_ok, "close fixture before reopen")
	db, open_error, open_ok := sqlite.db_open(fixture.path)
	expect_no_error(open_error, open_ok, "reopen fixture")
	fixture.db = db
}

expect_no_error :: proc(err: sqlite.Error, ok: bool, message: string, args: ..any) {
	if !ok {
		prefix := fmt.tprintf(message, ..args)
		fail("%s | %s", prefix, sqlite.error_string(err))
	}
}

exec_ok :: proc(db: sqlite.DB, sql: string) {
	err, ok := sqlite.db_exec(db, sql)
	expect_no_error(err, ok, "execute SQL %q", sql)
}

exec_fails :: proc(db: sqlite.DB, sql: string, expected_primary: int) {
	err, ok := sqlite.db_exec(db, sql)
	defer sqlite.error_destroy(&err)
	expect(!ok, "SQL unexpectedly succeeded: %q", sql)
	expect_equal(err.code, expected_primary, "primary result code for %q", sql)
}

prepare_ok :: proc(db: sqlite.DB, sql: string) -> sqlite.Stmt {
	stmt, err, ok := sqlite.stmt_prepare(db, sql)
	expect_no_error(err, ok, "prepare SQL %q", sql)
	return stmt
}

prepare_fails :: proc(db: sqlite.DB, sql: string, expected_primary: int) {
	stmt, err, ok := sqlite.stmt_prepare(db, sql)
	_ = stmt
	defer sqlite.error_destroy(&err)
	expect(!ok, "SQL unexpectedly prepared: %q", sql)
	expect_equal(err.code, expected_primary, "prepare result code for %q", sql)
}

finalize_ok :: proc(stmt: ^sqlite.Stmt) {
	err, ok := sqlite.stmt_finalize(stmt)
	expect_no_error(err, ok, "finalize statement")
}

finalize_after_failure :: proc(stmt: ^sqlite.Stmt) {
	err, _ := sqlite.stmt_finalize(stmt)
	sqlite.error_destroy(&err)
}

reset_ok :: proc(stmt: ^sqlite.Stmt) {
	err, ok := sqlite.stmt_reset(stmt)
	expect_no_error(err, ok, "reset statement")
}

clear_ok :: proc(stmt: ^sqlite.Stmt) {
	err, ok := sqlite.stmt_clear_bindings(stmt)
	expect_no_error(err, ok, "clear bindings")
}

step_row :: proc(stmt: sqlite.Stmt) {
	result, err, ok := sqlite.stmt_step(stmt)
	expect_no_error(err, ok, "step for row")
	expect_equal(result, sqlite.Step_Result.Row, "statement must yield a row")
}

step_done :: proc(stmt: sqlite.Stmt) {
	result, err, ok := sqlite.stmt_step(stmt)
	expect_no_error(err, ok, "step for completion")
	expect_equal(result, sqlite.Step_Result.Done, "statement must be complete")
}

step_fails :: proc(stmt: sqlite.Stmt, expected_primary: int, expected_extended: int = 0) {
	_, err, ok := sqlite.stmt_step(stmt)
	defer sqlite.error_destroy(&err)
	expect(!ok, "statement unexpectedly succeeded")
	expect_equal(err.code, expected_primary, "statement primary result code")
	if expected_extended != 0 {
		expect_equal(err.extended_code, expected_extended, "statement extended result code")
	}
}

bind_i64 :: proc(stmt: ^sqlite.Stmt, index: int, value: i64) {
	err, ok := sqlite.stmt_bind_i64(stmt, index, value)
	expect_no_error(err, ok, "bind i64 at index %d", index)
}

bind_f64 :: proc(stmt: ^sqlite.Stmt, index: int, value: f64) {
	err, ok := sqlite.stmt_bind_f64(stmt, index, value)
	expect_no_error(err, ok, "bind f64 at index %d", index)
}

bind_text :: proc(stmt: ^sqlite.Stmt, index: int, value: string) {
	err, ok := sqlite.stmt_bind_text(stmt, index, value)
	expect_no_error(err, ok, "bind text at index %d", index)
}

bind_blob :: proc(stmt: ^sqlite.Stmt, index: int, value: []u8) {
	err, ok := sqlite.stmt_bind_blob(stmt, index, value)
	expect_no_error(err, ok, "bind blob at index %d", index)
}

bind_null :: proc(stmt: ^sqlite.Stmt, index: int) {
	err, ok := sqlite.stmt_bind_null(stmt, index)
	expect_no_error(err, ok, "bind NULL at index %d", index)
}

reuse :: proc(stmt: ^sqlite.Stmt) {
	reset_ok(stmt)
	clear_ok(stmt)
}
