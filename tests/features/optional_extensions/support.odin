package optional_extensions

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import raw "../../../sqlite/raw/generated"

HAS_NORMALIZE_PROFILE :: #config(SQLITE_HAS_NORMALIZE_API, false)
HAS_PREUPDATE_PROFILE :: #config(SQLITE_HAS_PREUPDATE_API, false)
HAS_SESSION_PROFILE :: #config(SQLITE_HAS_SESSION_API, false)
HAS_COLUMN_METADATA_PROFILE :: #config(SQLITE_HAS_COLUMN_METADATA_API, false)
HAS_UNLOCK_NOTIFY_PROFILE :: #config(SQLITE_HAS_UNLOCK_NOTIFY_API, false)
HAS_STMT_SCANSTATUS_PROFILE :: #config(SQLITE_HAS_STMT_SCANSTATUS_API, false)
HAS_SNAPSHOT_PROFILE :: #config(SQLITE_HAS_SNAPSHOT_API, false)

ALL_FEATURE_BINDING_PROFILE :: (
	HAS_NORMALIZE_PROFILE &&
	HAS_PREUPDATE_PROFILE &&
	HAS_SESSION_PROFILE &&
	HAS_COLUMN_METADATA_PROFILE &&
	HAS_UNLOCK_NOTIFY_PROFILE &&
	HAS_STMT_SCANSTATUS_PROFILE &&
	HAS_SNAPSHOT_PROFILE
)

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

contains :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for index := 0; index <= len(haystack)-len(needle); index += 1 {
		if haystack[index:index+len(needle)] == needle {
			return true
		}
	}
	return false
}

expect_contains :: proc(haystack, needle, message: string) {
	expect(contains(haystack, needle), "%s | missing %q in %q", message, needle, haystack)
}

expect_rc :: proc(actual, expected: i32, operation: string) {
	expect_equal(actual, expected, "%s returned an unexpected SQLite result code", operation)
}

primary_rc :: proc(rc: i32) -> i32 {
	return rc & 0xff
}

db_error :: proc(db: ^raw.Sqlite3) -> string {
	if db == nil {
		return "<nil database>"
	}
	message := raw.errmsg(db)
	if message == nil {
		return "<no SQLite error message>"
	}
	return string(message)
}

open_db :: proc(path: string, flags: i32 = raw.OPEN_READWRITE | raw.OPEN_CREATE | raw.OPEN_URI | raw.OPEN_FULLMUTEX) -> ^raw.Sqlite3 {
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	db: ^raw.Sqlite3
	rc := raw.open_v2(c_path, &db, flags, nil)
	if rc != raw.OK {
		message := db_error(db)
		if db != nil {
			_ = raw.close_v2(db)
		}
		fail("sqlite3_open_v2(%q) failed: rc=%d message=%s", path, rc, message)
	}
	expect_rc(raw.extended_result_codes(db, 1), raw.OK, "sqlite3_extended_result_codes")
	return db
}

close_db :: proc(db: ^^raw.Sqlite3) {
	if db == nil || db^ == nil {
		return
	}
	rc := raw.close_v2(db^)
	expect_rc(rc, raw.OK, "sqlite3_close_v2")
	db^ = nil
}

exec_rc :: proc(db: ^raw.Sqlite3, sql: string) -> i32 {
	c_sql := strings.clone_to_cstring(sql)
	defer delete(c_sql)
	return raw.exec(db, c_sql, nil, nil, nil)
}

exec_ok :: proc(db: ^raw.Sqlite3, sql: string) {
	rc := exec_rc(db, sql)
	if rc != raw.OK {
		fail("sqlite3_exec failed: rc=%d message=%s sql=%q", rc, db_error(db), sql)
	}
}

prepare_rc :: proc(db: ^raw.Sqlite3, sql: string, stmt: ^^raw.Stmt) -> i32 {
	c_sql := strings.clone_to_cstring(sql)
	defer delete(c_sql)
	return raw.prepare_v2(db, c_sql, i32(len(sql)), stmt, nil)
}

prepare_ok :: proc(db: ^raw.Sqlite3, sql: string) -> ^raw.Stmt {
	stmt: ^raw.Stmt
	rc := prepare_rc(db, sql, &stmt)
	if rc != raw.OK {
		fail("sqlite3_prepare_v2 failed: rc=%d message=%s sql=%q", rc, db_error(db), sql)
	}
	expect(stmt != nil, "sqlite3_prepare_v2 returned SQLITE_OK with a nil statement")
	return stmt
}

finalize_ok :: proc(stmt: ^^raw.Stmt) {
	if stmt == nil || stmt^ == nil {
		return
	}
	rc := raw.finalize(stmt^)
	expect_rc(rc, raw.OK, "sqlite3_finalize")
	stmt^ = nil
}

reset_ok :: proc(stmt: ^raw.Stmt) {
	expect_rc(raw.reset(stmt), raw.OK, "sqlite3_reset")
}

step_row :: proc(stmt: ^raw.Stmt) {
	expect_rc(raw.step(stmt), raw.ROW, "sqlite3_step(row)")
}

step_done :: proc(stmt: ^raw.Stmt) {
	expect_rc(raw.step(stmt), raw.DONE, "sqlite3_step(done)")
}

bind_i64 :: proc(stmt: ^raw.Stmt, index: i32, value: i64) {
	expect_rc(raw.bind_int64(stmt, index, raw.Int64(value)), raw.OK, "sqlite3_bind_int64")
}

bind_f64 :: proc(stmt: ^raw.Stmt, index: i32, value: f64) {
	expect_rc(raw.bind_double(stmt, index, value), raw.OK, "sqlite3_bind_double")
}

bind_null :: proc(stmt: ^raw.Stmt, index: i32) {
	expect_rc(raw.bind_null(stmt, index), raw.OK, "sqlite3_bind_null")
}

bind_text :: proc(stmt: ^raw.Stmt, index: i32, value: string) {
	c_value := strings.clone_to_cstring(value)
	defer delete(c_value)
	expect_rc(raw.bind_text(stmt, index, c_value, i32(len(value)), raw.TRANSIENT), raw.OK, "sqlite3_bind_text")
}

bind_blob :: proc(stmt: ^raw.Stmt, index: i32, value: []u8) {
	if len(value) == 0 {
		expect_rc(raw.bind_zeroblob(stmt, index, 0), raw.OK, "sqlite3_bind_zeroblob(empty)")
		return
	}
	expect_rc(raw.bind_blob(stmt, index, raw_data(value), i32(len(value)), raw.TRANSIENT), raw.OK, "sqlite3_bind_blob")
}

column_text_copy :: proc(stmt: ^raw.Stmt, index: i32) -> string {
	value := raw.column_text(stmt, index)
	if value == nil {
		return ""
	}
	count := raw.column_bytes(stmt, index)
	if count <= 0 {
		return strings.clone("")
	}
	bytes := ([^]u8)(value)[:count]
	out := make([]u8, count)
	copy(out, bytes)
	return string(out)
}

scalar_i64 :: proc(db: ^raw.Sqlite3, sql: string) -> i64 {
	stmt := prepare_ok(db, sql)
	defer finalize_ok(&stmt)
	step_row(stmt)
	value := i64(raw.column_int64(stmt, 0))
	step_done(stmt)
	return value
}

scalar_text :: proc(db: ^raw.Sqlite3, sql: string) -> string {
	stmt := prepare_ok(db, sql)
	defer finalize_ok(&stmt)
	step_row(stmt)
	value := column_text_copy(stmt, 0)
	step_done(stmt)
	return value
}

temp_db_path :: proc(name: string) -> string {
	directory, err := os.temp_directory(context.allocator)
	expect(err == os.ERROR_NONE, "could not obtain temporary directory: %v", err)
	defer delete(directory)
	path, join_err := filepath.join({directory, name}, context.allocator)
	expect(join_err == nil, "could not construct temporary database path: %v", join_err)
	return path
}

remove_if_present :: proc(path: string) {
	_, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return
	}
	remove_err := os.remove(path)
	expect(remove_err == os.ERROR_NONE, "could not remove temporary file %q: %v", path, remove_err)
}

clean_db_files :: proc(path: string) {
	wal := strings.concatenate({path, "-wal"})
	defer delete(wal)
	shm := strings.concatenate({path, "-shm"})
	defer delete(shm)
	journal := strings.concatenate({path, "-journal"})
	defer delete(journal)
	remove_if_present(wal)
	remove_if_present(shm)
	remove_if_present(journal)
	remove_if_present(path)
}

run_case :: proc(name: string, body: proc()) {
	fmt.printf("RUN  %s\n", name)
	body()
	fmt.printf("PASS %s\n", name)
}

require_all_feature_sqlite :: proc() {
	expect_equal(raw.libversion_number(), i32(raw.VERSION_NUMBER), "qualification library/header version mismatch")
	expect_equal(string(raw.sourceid()), string(raw.SOURCE_ID), "qualification library/header source-id mismatch")
	expect(raw.threadsafe() != 0, "all-feature SQLite must be built with SQLITE_THREADSAFE")

	required := [?]cstring{
		"ENABLE_NORMALIZE",
		"ENABLE_PREUPDATE_HOOK",
		"ENABLE_SESSION",
		"ENABLE_COLUMN_METADATA",
		"ENABLE_UNLOCK_NOTIFY",
		"ENABLE_STMT_SCANSTATUS",
		"ENABLE_SNAPSHOT",
		"ENABLE_FTS5",
		"ENABLE_RTREE",
	}
	for option in required {
		expect(raw.compileoption_used(option) != 0, "all-feature SQLite is missing compile option %s", string(option))
	}
	expect(raw.compileoption_used("OMIT_JSON") == 0, "all-feature SQLite unexpectedly omits JSON")
}
