package tests

import "core:fmt"
import "core:sync"
import "core:thread"
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
	defer delete(test_db.path)
	defer remove_file_if_exists(test_db.path)

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
	defer sqlite.error_destroy(&err)
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

test_connection_rejects_narrowing_wraps :: proc() {
	bad_db, open_err, open_ok := sqlite.db_open(":memory:", int(max(i32)) + 1)
	_ = bad_db
	expect_error(&open_err, open_ok, int(raw.RANGE), "open flags outside i32 must not wrap")

	test_db := test_db_open("connection_rejects_narrowing_wraps")
	defer test_db_close(&test_db)
	timeout_err, timeout_ok := sqlite.db_set_busy_timeout(test_db.db, int(max(i32)) + 1)
	expect_error(&timeout_err, timeout_ok, int(raw.RANGE), "busy timeout outside i32 must not wrap")
}

// db_close uses sqlite3_close_v2: while a statement is still open the
// connection becomes a zombie, and finalizing its last statement frees it
// inside sqlite3_finalize. stmt_finalize must not read the connection after
// that. SQLite treats a zombie connection as invalid (sqlite3_errcode and
// sqlite3_errmsg report MISUSE), so the step's "integer overflow" text is no
// longer available and the error falls back to the generic text for its code.
// The use-after-free itself is only visible to AddressSanitizer with an
// ASan-instrumented SQLite library.
test_connection_finalize_after_close_reports_failure :: proc() {
	db, open_err, open_ok := sqlite.db_open(":memory:")
	expect_no_error(open_err, open_ok, "opening in-memory db should succeed")

	sql :: "SELECT abs(?1)"
	stmt := prepare_ok(db, sql)
	bind_i64_ok(&stmt, 1, min(i64), sql)
	_, step_err, step_ok := sqlite.stmt_step(stmt)
	expect_error(&step_err, step_ok, int(raw.ERROR), "abs(min(i64)) should fail with integer overflow")

	close_err, close_ok := sqlite.db_close(&db)
	expect_no_error(close_err, close_ok, "db_close should succeed and leave a zombie while the statement is open")

	fin_err, fin_ok := sqlite.stmt_finalize(&stmt)
	defer sqlite.error_destroy(&fin_err)
	expect_false(fin_ok, "finalize should report the failed step's error")
	expect_eq(fin_err.code, int(raw.ERROR), "finalize error code: %s", sqlite.error_string(fin_err))
	expect_eq(fin_err.extended_code, int(raw.ERROR), "finalize extended code: %s", sqlite.error_string(fin_err))
	expect_eq(fin_err.message, sqlite.db_errstr(int(raw.ERROR)), "finalize of a closed connection's statement can only report the generic text")
	expect_false(sqlite.stmt_is_valid(stmt), "statement should be invalid after finalize")

	again_err, again_ok := sqlite.stmt_finalize(&stmt)
	expect_no_error(again_err, again_ok, "second finalize should be a no-op")
}

// Same lifetime as above, reached through the statement cache: cache_destroy
// finalizes the last statement of a closed connection.
test_connection_cache_destroy_after_close_reports_failure :: proc() {
	db, open_err, open_ok := sqlite.db_open(":memory:")
	expect_no_error(open_err, open_ok, "opening in-memory db should succeed")

	cache := sqlite.cache_init()
	sql :: "SELECT abs(?1)"
	stmt, prep_err, prep_ok := sqlite.db_prepare_cached(db, &cache, sql)
	expect_no_error(prep_err, prep_ok, "cached prepare should succeed")
	bind_i64_ok(stmt, 1, min(i64), sql)
	_, step_err, step_ok := sqlite.stmt_step(stmt^)
	expect_error(&step_err, step_ok, int(raw.ERROR), "abs(min(i64)) should fail with integer overflow")

	close_err, close_ok := sqlite.db_close(&db)
	expect_no_error(close_err, close_ok, "db_close should succeed and leave a zombie while the cached statement is open")

	destroy_err, destroy_ok := sqlite.cache_destroy(&cache)
	defer sqlite.error_destroy(&destroy_err)
	expect_false(destroy_ok, "cache_destroy should report the finalize error")
	expect_eq(destroy_err.code, int(raw.ERROR), "cache_destroy error code: %s", sqlite.error_string(destroy_err))
	expect_eq(destroy_err.message, sqlite.db_errstr(int(raw.ERROR)), "finalize of a closed connection's statement can only report the generic text")
	expect_eq(sqlite.cache_count(cache), 0, "cache should be empty after destroy")
}

// sqlite3_blob_close finalizes the blob's statement. When the connection was
// already closed with db_close, that frees the connection, so blob_close must
// build its error without reading it. A vetoing commit hook makes the implicit
// commit at blob_close fail, so there is an error to report.
test_connection_blob_close_after_close_reports_commit_failure :: proc() {
	test_db := test_db_open("connection_blob_close_after_close")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE blob_zombie(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO blob_zombie(payload) VALUES (zeroblob(4))")

	blob, open_err, open_ok := sqlite.blob_open(test_db.db, "main", "blob_zombie", "payload", 1, .ReadWrite)
	expect_no_error(open_err, open_ok, "blob_open read-write should succeed")
	write_err, write_ok := sqlite.blob_write(blob, []u8{1, 2, 3, 4})
	expect_no_error(write_err, write_ok, "blob_write should succeed")

	raw.commit_hook(test_db.db.handle, proc "c" (_: rawptr) -> i32 { return 1 }, nil)

	close_err, close_ok := sqlite.db_close(&test_db.db)
	expect_no_error(close_err, close_ok, "db_close should succeed and leave a zombie while the blob is open")

	blob_err, blob_ok := sqlite.blob_close(&blob)
	defer sqlite.error_destroy(&blob_err)
	expect_false(blob_ok, "blob_close should report the vetoed commit")
	expect_eq(blob_err.code, int(raw.CONSTRAINT), "blob_close error code: %s", sqlite.error_string(blob_err))
	expect_eq(blob_err.extended_code, int(raw.CONSTRAINT_COMMITHOOK), "blob_close extended code: %s", sqlite.error_string(blob_err))
	expect_false(sqlite.blob_is_valid(blob), "blob should be invalid after blob_close")

	test_db_reopen(&test_db)
	payload, payload_err, payload_ok := sqlite.db_scalar_text(test_db.db, "SELECT hex(payload) FROM blob_zombie WHERE id = 1", allocator = context.temp_allocator)
	expect_no_error(payload_err, payload_ok, "reading the payload back should succeed")
	expect_eq(payload, "00000000", "the vetoed blob write must have been rolled back")
}

// One connection shared by several threads (the default FULLMUTEX mode). Each
// thread runs calls that fail with its own long "no such table" message, and
// error_from_db must read the connection's error state while no other thread
// can change it. Another thread's next call frees the message buffer (copying
// it afterwards is a use-after-free: garbage here, an ASan report under
// -sanitize:address) and clears the error code while it runs (the Error then
// falls back to the generic text). Messages over 1 KiB come from malloc, not
// lookaside, so ASan can see the freed buffer.
//
// Another thread's message is accepted: SQLite keeps one error per connection,
// so a failure in another thread between the call and the read can replace it
// (a documented limitation of sharing a connection).
//
// The race is probabilistic, so a single run can miss a regression; the checks
// cannot fail on correct code.
@(private = "file")
SHARED_CONN_THREADS :: 8
@(private = "file")
SHARED_CONN_ITERATIONS :: 2500
@(private = "file")
SHARED_CONN_NAME_MIN :: 1300
@(private = "file")
SHARED_CONN_NAME_SPREAD :: 400
@(private = "file")
SHARED_CONN_TABLE_PREFIX :: "SELECT * FROM t"
@(private = "file")
SHARED_CONN_MESSAGE_PREFIX :: "no such table: t"

@(private = "file")
Shared_Conn_Counts :: struct {
	own:        int,
	other:      int,
	succeeded:  int,
	empty:      int,
	generic:    int,
	malformed:  int,
	sample_len: int,
	sample:     [40]u8,
}

@(private = "file")
Shared_Conn_State :: struct {
	db:     sqlite.DB,
	start:  sync.Barrier,
	counts: [SHARED_CONN_THREADS]Shared_Conn_Counts,
}

// shared_conn_message_owner returns k when `msg` is exactly
// "no such table: t<k>_" followed by a worker-sized run of the letter 'a'+k,
// and -1 otherwise.
@(private = "file")
shared_conn_message_owner :: proc(msg: string) -> int {
	prefix_len := len(SHARED_CONN_MESSAGE_PREFIX)
	if len(msg) < prefix_len + 2 || msg[:prefix_len] != SHARED_CONN_MESSAGE_PREFIX {
		return -1
	}
	k := int(msg[prefix_len]) - '0'
	if k < 0 || k >= SHARED_CONN_THREADS || msg[prefix_len + 1] != '_' {
		return -1
	}
	name := msg[prefix_len + 2:]
	if len(name) < SHARED_CONN_NAME_MIN || len(name) >= SHARED_CONN_NAME_MIN + SHARED_CONN_NAME_SPREAD {
		return -1
	}
	letter := u8('a' + k)
	for i in 0 ..< len(name) {
		if name[i] != letter {
			return -1
		}
	}
	return k
}

// Runs with core:thread's default context: the heap allocator and this
// thread's own temp allocator. The harness's tracking allocator is not
// thread-safe and must not be used here.
@(private = "file")
shared_conn_worker :: proc(state: ^Shared_Conn_State, tid: int) {
	counts := &state.counts[tid]

	sql_buf: [len(SHARED_CONN_TABLE_PREFIX) + 2 + SHARED_CONN_NAME_MIN + SHARED_CONN_NAME_SPREAD]u8
	head := copy(sql_buf[:], SHARED_CONN_TABLE_PREFIX)
	sql_buf[head] = u8('0' + tid)
	sql_buf[head + 1] = '_'
	head += 2
	letter := u8('a' + tid)
	for i in head ..< len(sql_buf) {
		sql_buf[i] = letter
	}

	sync.barrier_wait(&state.start)

	for i in 0 ..< SHARED_CONN_ITERATIONS {
		name_len := SHARED_CONN_NAME_MIN + (i * 37 + tid * 11) % SHARED_CONN_NAME_SPREAD
		sql := string(sql_buf[:head + name_len])

		err: sqlite.Error
		ok: bool
		if i % 2 == 0 {
			stmt: sqlite.Stmt
			stmt, err, ok = sqlite.stmt_prepare(state.db, sql)
			if ok {
				sqlite.stmt_finalize_cleanup(&stmt)
			}
		} else {
			err, ok = sqlite.db_exec(state.db, sql)
		}

		if ok {
			counts.succeeded += 1
		} else if err.message == "" {
			counts.empty += 1
		} else if err.message == sqlite.db_errstr(err.code) {
			// The fallback text: the connection's error state was read while
			// another thread's call had cleared it.
			counts.generic += 1
		} else {
			owner := shared_conn_message_owner(err.message)
			if owner >= 0 && err.code == int(raw.ERROR) {
				if owner == tid {
					counts.own += 1
				} else {
					counts.other += 1
				}
			} else {
				if counts.malformed == 0 {
					counts.sample_len = len(err.message)
					copy(counts.sample[:], err.message)
				}
				counts.malformed += 1
			}
		}
		sqlite.error_destroy(&err)
	}
}

test_connection_shared_across_threads_errors_are_well_formed :: proc() {
	if raw.threadsafe() == 0 {
		// A single-thread SQLite build ignores OPEN_FULLMUTEX; sharing a
		// connection across threads is unsupported there.
		fmt.println("  skipped: SQLite was built with SQLITE_THREADSAFE=0")
		return
	}

	state := new(Shared_Conn_State)
	defer free(state)

	db, open_err, open_ok := sqlite.db_open(":memory:")
	expect_no_error(open_err, open_ok, "opening in-memory db should succeed")
	state.db = db
	defer sqlite.db_close_cleanup(&state.db)
	expect_true(raw.db_mutex(db.handle) != nil, "default open flags should give the connection a mutex (FULLMUTEX)")

	sync.barrier_init(&state.start, SHARED_CONN_THREADS)
	threads: [SHARED_CONN_THREADS]^thread.Thread
	for tid in 0 ..< SHARED_CONN_THREADS {
		// No init_context: the worker must not inherit the tracking allocator.
		threads[tid] = thread.create_and_start_with_poly_data2(state, tid, shared_conn_worker)
		expect_true(threads[tid] != nil, "creating worker thread %d should succeed", tid)
	}
	for t in threads {
		thread.destroy(t)
	}

	total: Shared_Conn_Counts
	for counts, tid in state.counts {
		total.own += counts.own
		total.other += counts.other
		total.succeeded += counts.succeeded
		total.empty += counts.empty
		total.generic += counts.generic
		total.malformed += counts.malformed
		if counts.malformed > 0 && total.sample_len == 0 {
			total.sample_len = counts.sample_len
			total.sample = counts.sample
		}
		expect_eq(counts.own + counts.other + counts.succeeded + counts.empty + counts.generic + counts.malformed, SHARED_CONN_ITERATIONS, "thread %d should account for every call", tid)
	}

	sample := string(total.sample[:min(total.sample_len, len(total.sample))])
	summary := fmt.tprintf("own=%d other_thread=%d succeeded=%d empty=%d generic=%d malformed=%d first_malformed(len=%d)=%q",
		total.own, total.other, total.succeeded, total.empty, total.generic, total.malformed, total.sample_len, sample)
	expect_eq(total.succeeded, 0, "every call should fail: %s", summary)
	expect_eq(total.malformed, 0, "every Error message must be a complete SQLite message: %s", summary)
	expect_eq(total.empty, 0, "no Error may have an empty message: %s", summary)
	expect_eq(total.generic, 0, "every failing call leaves a message on the connection, so no Error may fall back to the generic text: %s", summary)
}
