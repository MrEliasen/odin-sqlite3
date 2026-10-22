package tests

import "base:runtime"
import "core:mem"
import sqlite "../sqlite"
import raw "../sqlite/raw/generated"

// Regression tests for allocator ownership and allocation failure.
//
// Statements, statement caches, blobs, and backups outlive the call that
// creates them. They must keep their memory in the allocator that was current
// when they were created, not in whatever context.allocator is current at a
// later bind, cache lookup, or close (for example a per-request arena). An
// allocation failure must be reported as SQLITE_NOMEM rather than turning into
// a NULL bind, a panic, a temporary database, skipped SQL, or a truncated
// result.

run_allocator_tests :: proc() {
	run_test("allocator_bound_text_survives_request_arena_reuse", test_allocator_bound_text_survives_request_arena_reuse)
	run_test("allocator_finalize_in_another_allocator_scope_is_clean", test_allocator_finalize_in_another_allocator_scope_is_clean)
	run_test("allocator_cached_statement_survives_request_arena_reuse", test_allocator_cached_statement_survives_request_arena_reuse)
	run_test("allocator_blob_closed_outside_open_arena_is_clean", test_allocator_blob_closed_outside_open_arena_is_clean)
	run_test("allocator_backup_finished_outside_init_arena_is_clean", test_allocator_backup_finished_outside_init_arena_is_clean)
	run_test("allocator_bind_text_reports_nomem", test_allocator_bind_text_reports_nomem)
	run_test("allocator_bind_blob_reports_nomem", test_allocator_bind_blob_reports_nomem)
	run_test("allocator_commit_reports_nomem_and_keeps_transaction", test_allocator_commit_reports_nomem_and_keeps_transaction)
	run_test("allocator_open_reports_nomem_instead_of_temp_db", test_allocator_open_reports_nomem_instead_of_temp_db)
	run_test("allocator_query_all_struct_reports_nomem_instead_of_truncating", test_allocator_query_all_struct_reports_nomem_instead_of_truncating)
}

// allocator_test_tracker_begin wraps context.allocator so a test can check
// that memory routed through the wrapper was released to the allocator that
// owns it. Bad frees are recorded instead of being forwarded.
allocator_test_tracker_begin :: proc(tracker: ^mem.Tracking_Allocator) -> runtime.Allocator {
	mem.tracking_allocator_init(tracker, context.allocator)
	tracker.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	return mem.tracking_allocator(tracker)
}

allocator_test_tracker_expect_clean :: proc(tracker: ^mem.Tracking_Allocator, message: string) {
	leaks := len(tracker.allocation_map)
	bad_frees := len(tracker.bad_free_array)
	mem.tracking_allocator_destroy(tracker)
	expect_true(leaks == 0 && bad_frees == 0, "%s | leaks=%d bad_frees=%d", message, leaks, bad_frees)
}

// allocator_test_reuse_arena ends a request: the arena is reset and the next
// request overwrites its bytes.
allocator_test_reuse_arena :: proc(arena: ^mem.Arena) {
	free_all(mem.arena_allocator(arena))
	mem.set(raw_data(arena.data), 'X', len(arena.data))
}

allocator_test_failing_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	#partial switch mode {
	case .Free, .Free_All:
		return nil, nil
	case .Query_Features, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Out_Of_Memory
}

// allocator_test_failing returns an allocator whose every allocation fails.
allocator_test_failing :: proc() -> runtime.Allocator {
	return runtime.Allocator{procedure = allocator_test_failing_proc}
}

// allocator_test_select_param runs `SELECT typeof(?1), ?1` and resets the
// statement. sqlite3_reset keeps bindings, so a later run reads them again.
allocator_test_select_param :: proc(stmt: ^sqlite.Stmt) -> (type_name: string, value: string) {
	step_expect_row(stmt^)
	type_name = sqlite.stmt_get_text(stmt^, 0, context.temp_allocator)
	value = sqlite.stmt_get_text(stmt^, 1, context.temp_allocator)
	reset_ok(stmt)
	return
}

test_allocator_bound_text_survives_request_arena_reuse :: proc() {
	tracker: mem.Tracking_Allocator
	context.allocator = allocator_test_tracker_begin(&tracker)

	test_db := test_db_open("allocator_bound_text_survives_request_arena_reuse")
	stmt := prepare_ok(test_db.db, "SELECT typeof(?1), ?1")

	buffer: [4096]u8
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	{
		context.allocator = mem.arena_allocator(&arena)
		bind_text_ok(&stmt, 1, "request-one-value")
	}

	_, first_value := allocator_test_select_param(&stmt)
	expect_eq(first_value, "request-one-value", "bound text should be readable during the request")

	allocator_test_reuse_arena(&arena)

	type_name, value := allocator_test_select_param(&stmt)
	expect_eq(type_name, "text", "bound text must stay text after the request arena is reused")
	expect_eq(value, "request-one-value", "bound text must not live in the request arena")

	finalize_ok(&stmt)
	test_db_close(&test_db)
	allocator_test_tracker_expect_clean(&tracker, "statement memory must be released to the allocator that owns it")
}

test_allocator_finalize_in_another_allocator_scope_is_clean :: proc() {
	tracker: mem.Tracking_Allocator
	context.allocator = allocator_test_tracker_begin(&tracker)

	test_db := test_db_open("allocator_finalize_in_another_allocator_scope_is_clean")
	buffer: [4096]u8
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])

	// Bound inside a request arena, finalized after the request.
	bound_in_arena := prepare_ok(test_db.db, "SELECT ?1, ?2")
	{
		context.allocator = mem.arena_allocator(&arena)
		bind_text_ok(&bound_in_arena, 1, "bound-in-request")
		bind_blob_ok(&bound_in_arena, 2, []u8{1, 2, 3, 4})
	}
	finalize_ok(&bound_in_arena)

	// Bound normally, finalized by a deferred cleanup inside a request arena.
	finalized_in_arena := prepare_ok(test_db.db, "SELECT ?1, ?2")
	bind_text_ok(&finalized_in_arena, 1, "bound-before-request")
	bind_blob_ok(&finalized_in_arena, 2, []u8{5, 6, 7, 8})
	{
		context.allocator = mem.arena_allocator(&arena)
		finalize_ok(&finalized_in_arena)
	}

	test_db_close(&test_db)
	allocator_test_tracker_expect_clean(&tracker, "finalize must release bound copies to the statement's allocator")
}

test_allocator_cached_statement_survives_request_arena_reuse :: proc() {
	tracker: mem.Tracking_Allocator
	context.allocator = allocator_test_tracker_begin(&tracker)

	test_db := test_db_open("allocator_cached_statement_survives_request_arena_reuse")
	cache := sqlite.cache_init()
	sql :: "SELECT typeof(?1), ?1"

	buffer: [8192]u8
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	{
		context.allocator = mem.arena_allocator(&arena)
		stmt, err, ok := sqlite.db_prepare_cached(test_db.db, &cache, sql)
		expect_no_error(err, ok, "cached prepare during the first request should succeed")
		bind_text_ok(stmt, 1, "first request")
		_, value := allocator_test_select_param(stmt)
		expect_eq(value, "first request", "cached statement should run during the first request")
	}

	allocator_test_reuse_arena(&arena)

	stmt, err, ok := sqlite.db_prepare_cached(test_db.db, &cache, sql)
	expect_no_error(err, ok, "cached prepare after the request arena is reused should succeed")
	expect_eq(sqlite.cache_count(cache), 1, "one SQL string must stay one cache entry after the request arena is reused")
	bind_text_ok(stmt, 1, "second request")
	_, value := allocator_test_select_param(stmt)
	expect_eq(value, "second request", "cached statement should run during the second request")

	destroy_err, destroy_ok := sqlite.cache_destroy(&cache)
	expect_no_error(destroy_err, destroy_ok, "cache_destroy should succeed")
	expect_true(raw.next_stmt(test_db.db.handle, nil) == nil, "cache_destroy must finalize every statement the cache prepared")

	test_db_close(&test_db)
	allocator_test_tracker_expect_clean(&tracker, "cache memory must be released to the cache's allocator")
}

test_allocator_blob_closed_outside_open_arena_is_clean :: proc() {
	tracker: mem.Tracking_Allocator
	context.allocator = allocator_test_tracker_begin(&tracker)

	test_db := test_db_open("allocator_blob_closed_outside_open_arena_is_clean")
	exec_ok(test_db.db, "CREATE TABLE allocator_blobs(id INTEGER PRIMARY KEY, data BLOB)")
	exec_ok(test_db.db, "INSERT INTO allocator_blobs(id, data) VALUES (1, zeroblob(16))")

	buffer: [4096]u8
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	blob: sqlite.Blob
	{
		context.allocator = mem.arena_allocator(&arena)
		opened, err, ok := sqlite.blob_open(test_db.db, "main", "allocator_blobs", "data", 1)
		expect_no_error(err, ok, "blob_open inside the request arena should succeed")
		blob = opened
	}
	expect_eq(sqlite.blob_bytes(blob), 16, "blob handle should be usable after the request scope")

	close_err, close_ok := sqlite.blob_close(&blob)
	expect_no_error(close_err, close_ok, "blob_close should succeed")

	test_db_close(&test_db)
	allocator_test_tracker_expect_clean(&tracker, "blob_close must release names to the allocator that cloned them")
}

test_allocator_backup_finished_outside_init_arena_is_clean :: proc() {
	tracker: mem.Tracking_Allocator
	context.allocator = allocator_test_tracker_begin(&tracker)

	src := test_db_open("allocator_backup_finished_outside_init_arena_src")
	dst := test_db_open("allocator_backup_finished_outside_init_arena_dst")
	exec_ok(src.db, "CREATE TABLE allocator_backup(id INTEGER PRIMARY KEY, name TEXT)")
	exec_ok(src.db, "INSERT INTO allocator_backup(name) VALUES ('copied')")

	buffer: [4096]u8
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	backup: sqlite.Backup
	{
		context.allocator = mem.arena_allocator(&arena)
		started, err, ok := sqlite.backup_init(dst.db, src.db)
		expect_no_error(err, ok, "backup_init inside the request arena should succeed")
		backup = started
	}

	_, step_err, step_ok := sqlite.backup_step_all(&backup)
	expect_no_error(step_err, step_ok, "backup_step_all should copy every page")
	finish_err, finish_ok := sqlite.backup_finish(&backup)
	expect_no_error(finish_err, finish_ok, "backup_finish should succeed")

	count, count_err, count_ok := sqlite.db_scalar_i64(dst.db, "SELECT COUNT(*) FROM allocator_backup")
	expect_no_error(count_err, count_ok, "destination should be readable after backup")
	expect_eq(count, i64(1), "backup should copy the source row")

	test_db_close(&dst)
	test_db_close(&src)
	allocator_test_tracker_expect_clean(&tracker, "backup_finish must release names to the allocator that cloned them")
}

test_allocator_bind_text_reports_nomem :: proc() {
	test_db := test_db_open("allocator_bind_text_reports_nomem")
	defer test_db_close(&test_db)

	large := make([]u8, 64 * 1024)
	defer delete(large)
	for i in 0 ..< len(large) {
		large[i] = 'a'
	}

	// The statement is prepared inside a small request arena, which becomes its
	// allocator; the arena can hold the statement but not the large value.
	buffer: [4096]u8
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	{
		context.allocator = mem.arena_allocator(&arena)
		stmt := prepare_ok(test_db.db, "SELECT typeof(?1), length(?1)")
		defer finalize_ok(&stmt)

		err, ok := sqlite.stmt_bind_text(&stmt, 1, string(large))
		expect_error(&err, ok, int(raw.NOMEM), "stmt_bind_text must report allocation failure instead of binding NULL")

		bind_text_ok(&stmt, 1, "small")
		step_expect_row(stmt)
		expect_eq(sqlite.stmt_get_text(stmt, 0, context.temp_allocator), "text", "statement should stay usable after a failed bind")
		expect_eq(sqlite.stmt_get_i64(stmt, 1), i64(5), "statement should bind the value that fits")
	}
}

test_allocator_bind_blob_reports_nomem :: proc() {
	test_db := test_db_open("allocator_bind_blob_reports_nomem")
	defer test_db_close(&test_db)

	large := make([]u8, 64 * 1024)
	defer delete(large)

	buffer: [4096]u8
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	{
		context.allocator = mem.arena_allocator(&arena)
		stmt := prepare_ok(test_db.db, "SELECT typeof(?1), length(?1)")
		defer finalize_ok(&stmt)

		err, ok := sqlite.stmt_bind_blob(&stmt, 1, large)
		expect_error(&err, ok, int(raw.NOMEM), "stmt_bind_blob must report allocation failure")

		bind_blob_ok(&stmt, 1, []u8{1, 2, 3})
		step_expect_row(stmt)
		expect_eq(sqlite.stmt_get_text(stmt, 0, context.temp_allocator), "blob", "statement should stay usable after a failed bind")
		expect_eq(sqlite.stmt_get_i64(stmt, 1), i64(3), "statement should bind the value that fits")
	}
}

test_allocator_commit_reports_nomem_and_keeps_transaction :: proc() {
	test_db := test_db_open("allocator_commit_reports_nomem_and_keeps_transaction")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE allocator_tx(id INTEGER PRIMARY KEY)")
	begin_err, begin_ok := sqlite.db_begin(test_db.db)
	expect_no_error(begin_err, begin_ok, "BEGIN should succeed")
	exec_ok(test_db.db, "INSERT INTO allocator_tx(id) VALUES (1)")

	commit_err: sqlite.Error
	commit_ok: bool
	{
		context.allocator = allocator_test_failing()
		commit_err, commit_ok = sqlite.db_commit(test_db.db)
	}
	expect_error(&commit_err, commit_ok, int(raw.NOMEM), "db_commit must report allocation failure instead of skipping COMMIT")
	expect_true(sqlite.db_in_transaction(test_db.db), "a COMMIT that never ran must leave the transaction open")

	commit_err, commit_ok = sqlite.db_commit(test_db.db)
	expect_no_error(commit_err, commit_ok, "COMMIT should succeed once memory is available")
	count, count_err, count_ok := sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM allocator_tx")
	expect_no_error(count_err, count_ok, "count after commit should succeed")
	expect_eq(count, i64(1), "the committed row should persist")
}

test_allocator_open_reports_nomem_instead_of_temp_db :: proc() {
	path := make_temp_db_path("allocator_open_reports_nomem_instead_of_temp_db")
	defer delete(path)
	remove_file_if_exists(path)

	db: sqlite.DB
	err: sqlite.Error
	ok: bool
	{
		context.allocator = allocator_test_failing()
		db, err, ok = sqlite.db_open(path)
	}
	expect_error(&err, ok, int(raw.NOMEM), "db_open must report allocation failure instead of opening a temporary database")
	expect_false(sqlite.db_is_valid(db), "a failed db_open must not return a connection")
}

Allocator_Test_Person :: struct {
	id:   i64,
	name: string,
}

test_allocator_query_all_struct_reports_nomem_instead_of_truncating :: proc() {
	test_db := test_db_open("allocator_query_all_struct_reports_nomem_instead_of_truncating")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE allocator_people(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(test_db.db, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200) INSERT INTO allocator_people(id, name) SELECT i, 'person-' || i FROM n")
	sql :: "SELECT id, name FROM allocator_people ORDER BY id"

	// 2 KiB holds only part of the 200-row result.
	buffer: [2048]u8
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	rows, err, ok := sqlite.db_query_all_struct(test_db.db, sql, Allocator_Test_Person, allocator = mem.arena_allocator(&arena))
	expect_error(&err, ok, int(raw.NOMEM), "db_query_all_struct must report allocation failure instead of returning a truncated result")
	expect_eq(len(rows), 0, "a failed db_query_all_struct must not return rows")

	all_rows, all_err, all_ok := sqlite.db_query_all_struct(test_db.db, sql, Allocator_Test_Person, allocator = context.temp_allocator)
	expect_no_error(all_err, all_ok, "the same query should succeed with an allocator that can hold the result")
	expect_eq(len(all_rows), 200, "the complete result should contain every row")
}
