package tests

import raw "../sqlite/raw/generated"
import sqlite "../sqlite"

test_exec_changes_and_last_insert_rowid :: proc() {
	test_db := test_db_open("exec_changes_and_last_insert_rowid")
	defer test_db_close(&test_db)

	err, ok := sqlite.db_exec_no_rows(test_db.db, "CREATE TABLE audit_log(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	expect_no_error(err, ok, "db_exec_no_rows should create table successfully")

	expect_eq(sqlite.db_changes(test_db.db), i64(0), "CREATE TABLE should not report row changes")
	expect_eq(sqlite.db_total_changes(test_db.db), i64(0), "CREATE TABLE should not affect total changes")

	err, ok = sqlite.db_exec(test_db.db, "INSERT INTO audit_log(name) VALUES ('alpha')")
	expect_no_error(err, ok, "first insert should succeed")
	expect_eq(sqlite.db_changes(test_db.db), i64(1), "single insert should report one changed row")
	expect_eq(sqlite.db_last_insert_rowid(test_db.db), i64(1), "first rowid should be 1")

	err, ok = sqlite.db_exec(test_db.db, "INSERT INTO audit_log(name) VALUES ('beta'), ('gamma')")
	expect_no_error(err, ok, "multi-row insert should succeed")
	expect_eq(sqlite.db_changes(test_db.db), i64(2), "multi-row insert should report two changed rows")
	expect_eq(sqlite.db_total_changes(test_db.db), i64(3), "total changes should accumulate across inserts")
	expect_eq(sqlite.db_last_insert_rowid(test_db.db), i64(3), "last insert rowid should track final inserted row")
}

test_exec_query_helpers :: proc() {
	test_db := test_db_open("exec_query_helpers")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE players(id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO players(name, score) VALUES ('alice', 10.5), ('bob', 20.0)")

	stmt, err, ok := sqlite.db_query_one(test_db.db, "SELECT id, name FROM players ORDER BY id LIMIT 1")
	expect_no_error(err, ok, "db_query_one should succeed when a row exists")
	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(1), "db_query_one should expose first row id")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "alice", "db_query_one should expose first row name")
	finalize_ok(&stmt, "SELECT id, name FROM players ORDER BY id LIMIT 1")

	optional_stmt, found, optional_err, optional_ok := sqlite.db_query_optional(test_db.db, "SELECT id FROM players WHERE name = 'missing'")
	expect_no_error(optional_err, optional_ok, "db_query_optional should succeed on empty result")
	expect_false(found, "db_query_optional should report not found for empty result")
	expect_false(sqlite.stmt_is_valid(optional_stmt), "db_query_optional should return invalid stmt when no row is found")

	stmt, err, ok = sqlite.db_query_all(test_db.db, "SELECT name FROM players ORDER BY id")
	expect_no_error(err, ok, "db_query_all should prepare statement successfully")
	defer finalize_ok(&stmt, "SELECT name FROM players ORDER BY id")

	count, step_err, step_ok := sqlite.stmt_step_all(&stmt, proc(stmt_ptr: ^sqlite.Stmt) -> (sqlite.Error, bool) {
		if sqlite.stmt_get_i64(stmt_ptr^, 0) != 0 {
			test_fail("unexpected numeric coercion while stepping query_all results")
		}
		return sqlite.error_none(), true
	})
	expect_no_error(step_err, step_ok, "stmt_step_all should exhaust query_all statement")
	expect_eq(count, 2, "stmt_step_all should visit all result rows")
}

test_exec_scalar_and_exists_helpers :: proc() {
	test_db := test_db_open("exec_scalar_and_exists_helpers")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE metrics(id INTEGER PRIMARY KEY, count_value INTEGER, ratio REAL, label TEXT)")
	exec_ok(test_db.db, "INSERT INTO metrics(count_value, ratio, label) VALUES (5, 1.25, 'north'), (0, 0.0, '')")

	i64_value, err, ok := sqlite.db_scalar_i64(test_db.db, "SELECT count_value FROM metrics WHERE id = 1")
	expect_no_error(err, ok, "db_scalar_i64 should succeed")
	expect_eq(i64_value, i64(5), "db_scalar_i64 should read integer scalar")

	f64_value, f64_err, f64_ok := sqlite.db_scalar_f64(test_db.db, "SELECT ratio FROM metrics WHERE id = 1")
	expect_no_error(f64_err, f64_ok, "db_scalar_f64 should succeed")
	expect_eq(f64_value, 1.25, "db_scalar_f64 should read float scalar")

	text_value, text_err, text_ok := sqlite.db_scalar_text(test_db.db, "SELECT label FROM metrics WHERE id = 1", sqlite.DEFAULT_PREPARE_FLAGS, context.temp_allocator)
	expect_no_error(text_err, text_ok, "db_scalar_text should succeed")
	expect_eq(text_value, "north", "db_scalar_text should read text scalar")

	exists, exists_err, exists_ok := sqlite.db_exists(test_db.db, "SELECT 1 FROM metrics WHERE id = 1")
	expect_no_error(exists_err, exists_ok, "db_exists should succeed for matching row")
	expect_true(exists, "db_exists should report true for matching row")

	exists, exists_err, exists_ok = sqlite.db_exists(test_db.db, "SELECT 1 FROM metrics WHERE id = 999")
	expect_no_error(exists_err, exists_ok, "db_exists should succeed for missing row")
	expect_false(exists, "db_exists should report false for missing row")

	exists, exists_err, exists_ok = sqlite.db_exists(test_db.db, "SELECT label FROM metrics WHERE id = 2")
	expect_no_error(exists_err, exists_ok, "db_exists should succeed for text result")
	expect_false(exists, "empty text scalar should be treated as false by db_exists")

	zero_i64, zero_i64_err, zero_i64_ok := sqlite.db_scalar_i64(test_db.db, "SELECT NULL")
	expect_no_error(zero_i64_err, zero_i64_ok, "db_scalar_i64 should succeed for NULL scalar")
	expect_eq(zero_i64, i64(0), "NULL integer scalar should map to zero")

	zero_f64, zero_f64_err, zero_f64_ok := sqlite.db_scalar_f64(test_db.db, "SELECT NULL")
	expect_no_error(zero_f64_err, zero_f64_ok, "db_scalar_f64 should succeed for NULL scalar")
	expect_eq(zero_f64, 0.0, "NULL float scalar should map to zero")

	empty_text, empty_text_err, empty_text_ok := sqlite.db_scalar_text(test_db.db, "SELECT NULL", sqlite.DEFAULT_PREPARE_FLAGS, context.temp_allocator)
	expect_no_error(empty_text_err, empty_text_ok, "db_scalar_text should succeed for NULL scalar")
	expect_eq(empty_text, "", "NULL text scalar should map to empty string")
}

test_transaction_begin_commit_and_rollback :: proc() {
	test_db := test_db_open("transaction_begin_commit_and_rollback")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE tx_items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")

	err, ok := sqlite.db_begin(test_db.db)
	expect_no_error(err, ok, "db_begin should succeed")
	expect_true(sqlite.db_in_transaction(test_db.db), "db_begin should disable autocommit")

	err, ok = sqlite.db_exec(test_db.db, "INSERT INTO tx_items(name) VALUES ('committed')")
	expect_no_error(err, ok, "insert inside explicit transaction should succeed")

	err, ok = sqlite.db_commit(test_db.db)
	expect_no_error(err, ok, "db_commit should succeed")
	expect_false(sqlite.db_in_transaction(test_db.db), "db_commit should restore autocommit")

	count, scalar_err, scalar_ok := sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM tx_items")
	expect_no_error(scalar_err, scalar_ok, "count after commit should succeed")
	expect_eq(count, i64(1), "committed row should persist")

	err, ok = sqlite.db_begin(test_db.db)
	expect_no_error(err, ok, "second db_begin should succeed")

	err, ok = sqlite.db_exec(test_db.db, "INSERT INTO tx_items(name) VALUES ('rolled_back')")
	expect_no_error(err, ok, "insert before rollback should succeed")

	err, ok = sqlite.db_rollback(test_db.db)
	expect_no_error(err, ok, "db_rollback should succeed")
	expect_false(sqlite.db_in_transaction(test_db.db), "db_rollback should restore autocommit")

	count, scalar_err, scalar_ok = sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM tx_items")
	expect_no_error(scalar_err, scalar_ok, "count after rollback should succeed")
	expect_eq(count, i64(1), "rolled back row should not persist")
}

test_transaction_begin_modes :: proc() {
	test_db := test_db_open("transaction_begin_modes")
	defer test_db_close(&test_db)

	err, ok := sqlite.db_begin_deferred(test_db.db)
	expect_no_error(err, ok, "db_begin_deferred should succeed")
	expect_true(sqlite.db_in_transaction(test_db.db), "db_begin_deferred should enter transaction")
	err, ok = sqlite.db_rollback(test_db.db)
	expect_no_error(err, ok, "rollback after db_begin_deferred should succeed")

	err, ok = sqlite.db_begin_immediate(test_db.db)
	expect_no_error(err, ok, "db_begin_immediate should succeed")
	expect_true(sqlite.db_in_transaction(test_db.db), "db_begin_immediate should enter transaction")
	err, ok = sqlite.db_rollback(test_db.db)
	expect_no_error(err, ok, "rollback after db_begin_immediate should succeed")

	err, ok = sqlite.db_begin_exclusive(test_db.db)
	expect_no_error(err, ok, "db_begin_exclusive should succeed")
	expect_true(sqlite.db_in_transaction(test_db.db), "db_begin_exclusive should enter transaction")
	err, ok = sqlite.db_rollback(test_db.db)
	expect_no_error(err, ok, "rollback after db_begin_exclusive should succeed")
}

test_transaction_savepoint_release_and_rollback_to :: proc() {
	test_db := test_db_open("transaction_savepoint_release_and_rollback_to")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE savepoint_items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")

	err, ok := sqlite.db_begin(test_db.db)
	expect_no_error(err, ok, "outer begin should succeed")

	err, ok = sqlite.db_exec(test_db.db, "INSERT INTO savepoint_items(name) VALUES ('outer')")
	expect_no_error(err, ok, "outer insert should succeed")

	err, ok = sqlite.db_savepoint(test_db.db, "sp_one")
	expect_no_error(err, ok, "savepoint should succeed")

	err, ok = sqlite.db_exec(test_db.db, "INSERT INTO savepoint_items(name) VALUES ('inner_kept')")
	expect_no_error(err, ok, "insert inside savepoint should succeed")

	err, ok = sqlite.db_release(test_db.db, "sp_one")
	expect_no_error(err, ok, "release savepoint should succeed")

	err, ok = sqlite.db_savepoint(test_db.db, "sp_two")
	expect_no_error(err, ok, "second savepoint should succeed")

	err, ok = sqlite.db_exec(test_db.db, "INSERT INTO savepoint_items(name) VALUES ('inner_rolled_back')")
	expect_no_error(err, ok, "insert before rollback_to should succeed")

	err, ok = sqlite.db_rollback_to(test_db.db, "sp_two")
	expect_no_error(err, ok, "rollback_to savepoint should succeed")

	err, ok = sqlite.db_release(test_db.db, "sp_two")
	expect_no_error(err, ok, "release after rollback_to should succeed")

	err, ok = sqlite.db_commit(test_db.db)
	expect_no_error(err, ok, "commit after savepoint work should succeed")

	count, scalar_err, scalar_ok := sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM savepoint_items")
	expect_no_error(scalar_err, scalar_ok, "count after savepoint flow should succeed")
	expect_eq(count, i64(2), "only outer row and released savepoint row should persist")

	exists, exists_err, exists_ok := sqlite.db_exists(test_db.db, "SELECT 1 FROM savepoint_items WHERE name = 'inner_rolled_back'")
	expect_no_error(exists_err, exists_ok, "exists after rollback_to should succeed")
	expect_false(exists, "row inserted after savepoint should be removed by rollback_to")
}

test_transaction_with_transaction_helper :: proc() {
	test_db := test_db_open("transaction_with_transaction_helper")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE helper_tx(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")

	err, ok := sqlite.db_with_transaction(test_db.db, proc(db: sqlite.DB) -> (sqlite.Error, bool) {
		return sqlite.db_exec(db, "INSERT INTO helper_tx(name) VALUES ('kept')")
	})
	expect_no_error(err, ok, "db_with_transaction success path should commit work")

	count, scalar_err, scalar_ok := sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM helper_tx")
	expect_no_error(scalar_err, scalar_ok, "count after successful helper transaction should succeed")
	expect_eq(count, i64(1), "successful helper transaction should persist inserted row")

	err, ok = sqlite.db_with_transaction(test_db.db, proc(db: sqlite.DB) -> (sqlite.Error, bool) {
		insert_err, insert_ok := sqlite.db_exec(db, "INSERT INTO helper_tx(name) VALUES ('rolled_back')")
		expect_no_error(insert_err, insert_ok, "insert inside failing helper transaction should succeed")
		return sqlite.Error{code = int(raw.ABORT), message = "forced failure"}, false
	})
	expect_false(ok, "db_with_transaction should propagate body failure")

	count, scalar_err, scalar_ok = sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM helper_tx")
	expect_no_error(scalar_err, scalar_ok, "count after failed helper transaction should succeed")
	expect_eq(count, i64(1), "failed helper transaction should rollback inserted row")
}

test_transaction_with_savepoint_helper :: proc() {
	test_db := test_db_open("transaction_with_savepoint_helper")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE helper_sp(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")

	err, ok := sqlite.db_begin(test_db.db)
	expect_no_error(err, ok, "outer transaction should begin successfully")

	err, ok = sqlite.db_exec(test_db.db, "INSERT INTO helper_sp(name) VALUES ('outer')")
	expect_no_error(err, ok, "outer insert should succeed")

	err, ok = sqlite.db_with_savepoint(test_db.db, "sp_keep", proc(db: sqlite.DB) -> (sqlite.Error, bool) {
		return sqlite.db_exec(db, "INSERT INTO helper_sp(name) VALUES ('kept')")
	})
	expect_no_error(err, ok, "successful savepoint helper should release changes")

	err, ok = sqlite.db_with_savepoint(test_db.db, "sp_drop", proc(db: sqlite.DB) -> (sqlite.Error, bool) {
		insert_err, insert_ok := sqlite.db_exec(db, "INSERT INTO helper_sp(name) VALUES ('dropped')")
		expect_no_error(insert_err, insert_ok, "insert inside failing savepoint helper should succeed")
		return sqlite.Error{code = int(raw.ABORT), message = "forced savepoint failure"}, false
	})
	expect_false(ok, "failing savepoint helper should report failure")

	err, ok = sqlite.db_commit(test_db.db)
	expect_no_error(err, ok, "commit after savepoint helper checks should succeed")

	count, scalar_err, scalar_ok := sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM helper_sp")
	expect_no_error(scalar_err, scalar_ok, "count after savepoint helper checks should succeed")
	expect_eq(count, i64(2), "outer row and successful savepoint row should persist")

	exists, exists_err, exists_ok := sqlite.db_exists(test_db.db, "SELECT 1 FROM helper_sp WHERE name = 'dropped'")
	expect_no_error(exists_err, exists_ok, "exists check after failed savepoint helper should succeed")
	expect_false(exists, "failed savepoint helper should rollback its inner insert")
}

test_transaction_invalid_savepoint_name_is_rejected :: proc() {
	test_db := test_db_open("transaction_invalid_savepoint_name_is_rejected")
	defer test_db_close(&test_db)

	err, ok := sqlite.db_savepoint(test_db.db, "")
	expect_false(ok, "empty savepoint name should fail")
	expect_true(err.code != 0, "empty savepoint name should produce an error")

	err, ok = sqlite.db_release(test_db.db, "")
	expect_false(ok, "empty release name should fail")
	expect_true(err.code != 0, "empty release name should produce an error")

	err, ok = sqlite.db_rollback_to(test_db.db, "")
	expect_false(ok, "empty rollback_to name should fail")
	expect_true(err.code != 0, "empty rollback_to name should produce an error")
}

test_cache_prepare_reuse_and_clear :: proc() {
	test_db := test_db_open("cache_prepare_reuse_and_clear")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE cache_items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO cache_items(name) VALUES ('alpha'), ('beta')")

	cache := sqlite.cache_init()

	sql := "SELECT name FROM cache_items WHERE id = ?1"
	stmt_a, err, ok := sqlite.db_prepare_cached(test_db.db, &cache, sql)
	expect_no_error(err, ok, "first db_prepare_cached should succeed")
	expect_true(stmt_a != nil, "first db_prepare_cached should return a non-nil statement pointer")

	bind_i64_ok(stmt_a, 1, 1, sql)

	expect_eq(sqlite.stmt_param_count(stmt_a^), 1, "cached statement should report one bind parameter")
	expect_eq(sqlite.stmt_param_name(stmt_a^, 1), "?1", "cached statement parameter 1 should be named ?1")
	expect_eq(sqlite.stmt_param_index(stmt_a^, "?1"), 1, "cached statement ?1 should resolve to index 1")

	step_expect_row(stmt_a^, sql)
	expect_eq(sqlite.stmt_get_text(stmt_a^, 0, context.temp_allocator), "alpha", "cached stmt first execution should return alpha")

	stmt_b, err_cached, ok_cached := sqlite.db_prepare_cached(test_db.db, &cache, sql)
	expect_no_error(err_cached, ok_cached, "second db_prepare_cached should succeed")
	expect_true(stmt_b != nil, "second db_prepare_cached should return a non-nil statement pointer")
	expect_true(stmt_a.handle == stmt_b.handle, "cached statement should be reused for identical SQL")

	expect_eq(sqlite.stmt_param_count(stmt_b^), 1, "reused cached statement should still report one bind parameter")
	expect_eq(sqlite.stmt_param_name(stmt_b^, 1), "?1", "reused cached statement parameter 1 should still be ?1")
	expect_eq(sqlite.stmt_param_index(stmt_b^, "?1"), 1, "reused cached statement ?1 should still resolve to index 1")

	bind_i64_ok(stmt_b, 1, 2, sql)

	debug_value, debug_err, debug_ok := sqlite.db_scalar_text(test_db.db, "SELECT name FROM cache_items WHERE id = 2", sqlite.DEFAULT_PREPARE_FLAGS, context.temp_allocator)
	expect_no_error(debug_err, debug_ok, "direct scalar query should still see row for id=2")
	expect_eq(debug_value, "beta", "direct scalar query should confirm fixture row beta exists")

	has_row_after_rebind, next_err_after_rebind, next_ok_after_rebind := sqlite.stmt_next(stmt_b^)
	if !next_ok_after_rebind || !has_row_after_rebind {
		test_fail(
			"cached statement should yield row after rebinding | ok=%v has_row=%v err=%s sql=%q expanded=%q direct_scalar=%q param_count=%v param_name_1=%q param_index_q1=%v",
			next_ok_after_rebind,
			has_row_after_rebind,
			sqlite.error_string(next_err_after_rebind),
			sqlite.stmt_sql(stmt_b^),
			sqlite.stmt_expanded_sql(stmt_b^, context.temp_allocator),
			debug_value,
			sqlite.stmt_param_count(stmt_b^),
			sqlite.stmt_param_name(stmt_b^, 1),
			sqlite.stmt_param_index(stmt_b^, "?1"),
		)
	}
	expect_eq(sqlite.stmt_get_text(stmt_b^, 0, context.temp_allocator), "beta", "reused cached statement should support rebinding")

	err_reuse, ok_reuse := sqlite.stmt_reuse(stmt_b)
	expect_no_error(err_reuse, ok_reuse, "stmt_reuse should reset cached statement and clear bindings")

	bind_i64_ok(stmt_b, 1, 1, sql)
	step_expect_row(stmt_b^, sql)
	expect_eq(sqlite.stmt_get_text(stmt_b^, 0, context.temp_allocator), "alpha", "cached statement should remain usable after stmt_reuse and rebinding")

	expect_eq(sqlite.cache_count(cache), 1, "cache should hold one entry for one SQL string")
	expect_true(sqlite.cache_has(cache, sql), "cache should report stored SQL")

	clear_err, clear_ok := sqlite.cache_clear(&cache)
	expect_no_error(clear_err, clear_ok, "cache_clear should finalize cached statements")
	expect_eq(sqlite.cache_count(cache), 0, "cache_clear should remove all entries")

	destroy_err, destroy_ok := sqlite.cache_destroy(&cache)
	expect_no_error(destroy_err, destroy_ok, "cache_destroy should succeed")
}

test_cache_usage_tracking_and_prune_unused :: proc() {
	test_db := test_db_open("cache_usage_tracking_and_prune_unused")
	defer test_db_close(&test_db)

	cache := sqlite.cache_init()

	sql_a := "SELECT 1"
	sql_b := "SELECT 2"

	stmt_a, err, ok := sqlite.db_prepare_cached(test_db.db, &cache, sql_a)
	expect_no_error(err, ok, "prepare_cached for sql_a should succeed")
	expect_true(stmt_a != nil, "prepare_cached for sql_a should return non-nil pointer")

	stmt_b, err_cached, ok_cached := sqlite.db_prepare_cached(test_db.db, &cache, sql_b)
	expect_no_error(err_cached, ok_cached, "prepare_cached for sql_b should succeed")
	expect_true(stmt_b != nil, "prepare_cached for sql_b should return non-nil pointer")

	expect_eq(sqlite.cache_count(cache), 2, "cache should contain both prepared statements")

	sqlite.cache_reset_usage(&cache)

	used_stmt, found := sqlite.cache_get(&cache, sql_a)
	expect_true(found, "cache_get should find sql_a after reset_usage")
	expect_true(used_stmt != nil, "cache_get should return non-nil stmt pointer")

	removed, prune_err, prune_ok := sqlite.cache_prune_unused(&cache)
	expect_no_error(prune_err, prune_ok, "cache_prune_unused should succeed")
	expect_eq(removed, 1, "cache_prune_unused should remove one unused entry")
	expect_eq(sqlite.cache_count(cache), 1, "cache should retain only used entry after prune")

	clear_err, clear_ok := sqlite.cache_destroy(&cache)
	expect_no_error(clear_err, clear_ok, "cache_destroy should succeed")
}

test_operational_busy_timeout_and_wal_checkpoint :: proc() {
	test_db := test_db_open("operational_busy_timeout_and_wal_checkpoint")
	defer test_db_close(&test_db)

	err, ok := sqlite.db_set_busy_timeout(test_db.db, 1000)
	expect_no_error(err, ok, "setting busy timeout should succeed")

	exec_ok(test_db.db, "PRAGMA journal_mode=WAL")
	exec_ok(test_db.db, "CREATE TABLE wal_items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO wal_items(name) VALUES ('one'), ('two'), ('three')")

	result, checkpoint_err, checkpoint_ok := sqlite.db_wal_checkpoint(test_db.db, .Passive, "main")
	expect_no_error(checkpoint_err, checkpoint_ok, "db_wal_checkpoint passive should succeed")
	expect_true(result.log_frames >= 0, "wal checkpoint should report non-negative log frame count")
	expect_true(result.checkpointed_frames >= 0, "wal checkpoint should report non-negative checkpointed frame count")

	result, checkpoint_err, checkpoint_ok = sqlite.db_wal_checkpoint_passive(test_db.db, "main")
	expect_no_error(checkpoint_err, checkpoint_ok, "db_wal_checkpoint_passive should succeed")
	expect_true(result.log_frames >= 0, "passive checkpoint helper should report log frames")
	expect_true(result.checkpointed_frames >= 0, "passive checkpoint helper should report checkpointed frames")

	result, checkpoint_err, checkpoint_ok = sqlite.db_wal_checkpoint_full(test_db.db, "main")
	expect_no_error(checkpoint_err, checkpoint_ok, "db_wal_checkpoint_full should succeed")

	result, checkpoint_err, checkpoint_ok = sqlite.db_wal_checkpoint_restart(test_db.db, "main")
	expect_no_error(checkpoint_err, checkpoint_ok, "db_wal_checkpoint_restart should succeed")

	result, checkpoint_err, checkpoint_ok = sqlite.db_wal_checkpoint_truncate(test_db.db, "main")
	expect_no_error(checkpoint_err, checkpoint_ok, "db_wal_checkpoint_truncate should succeed")
}

test_operational_stmt_consume_done_and_with_stmt :: proc() {
	test_db := test_db_open("operational_stmt_consume_done_and_with_stmt")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE helper_stmt(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO helper_stmt(name) VALUES ('alpha'), ('beta'), ('gamma')")

	err, ok := sqlite.db_with_stmt(
		test_db.db,
		"SELECT name FROM helper_stmt ORDER BY id",
		proc(stmt: ^sqlite.Stmt) -> (sqlite.Error, bool) {
			step_expect_row(stmt^, "SELECT name FROM helper_stmt ORDER BY id")
			expect_eq(sqlite.stmt_get_text(stmt^, 0, context.temp_allocator), "alpha", "db_with_stmt should expose first row through prepared stmt")

			consume_err, consume_ok := sqlite.stmt_consume_done(stmt)
			expect_no_error(consume_err, consume_ok, "stmt_consume_done should consume remaining rows")
			return sqlite.error_none(), true
		},
	)
	expect_no_error(err, ok, "db_with_stmt should succeed")

	stmt := prepare_ok(test_db.db, "SELECT name FROM helper_stmt ORDER BY id")
	defer finalize_ok(&stmt, "SELECT name FROM helper_stmt ORDER BY id")

	rows_seen, step_err, step_ok := sqlite.stmt_step_all(&stmt, proc(stmt_ptr: ^sqlite.Stmt) -> (sqlite.Error, bool) {
		name := sqlite.stmt_get_text(stmt_ptr^, 0, context.temp_allocator)
		expect_true(name == "alpha" || name == "beta" || name == "gamma", "stmt_step_all should visit valid names")
		return sqlite.error_none(), true
	})
	expect_no_error(step_err, step_ok, "stmt_step_all should succeed on helper_stmt query")
	expect_eq(rows_seen, 3, "stmt_step_all should visit all helper_stmt rows")
}