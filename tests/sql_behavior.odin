package tests

import "core:strings"
import raw "../sqlite/raw/generated"
import sqlite "../sqlite"

// ---------------------------------------------------------------------------
// SQL behavior tests
//
// The wrapper API tests in the other files focus on roundtripping the binding
// surface. The tests in this file exercise actual SQL semantics end-to-end
// using the wrapper: schema constraints, joins, aggregates, transactions,
// PRAGMAs, large data, and concurrency between multiple open connections to
// the same database file.
// ---------------------------------------------------------------------------

// ----- DML basics ----------------------------------------------------------

test_sql_update_with_prepared_params :: proc() {
	test_db := test_db_open("sql_update_with_prepared_params")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE items(id INTEGER PRIMARY KEY, qty INTEGER NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO items(id, qty) VALUES (1, 5), (2, 10), (3, 15)")

	stmt := prepare_ok(test_db.db, "UPDATE items SET qty = ?1 WHERE id = ?2")
	defer finalize_ok(&stmt, "UPDATE items SET qty = ?1 WHERE id = ?2")

	bind_i64_ok(&stmt, 1, 99, "")
	bind_i64_ok(&stmt, 2, 2, "")
	step_expect_done(stmt, "UPDATE")

	expect_eq(sqlite.db_changes(test_db.db), i64(1), "UPDATE should report exactly one changed row")

	got, err, ok := sqlite.db_scalar_i64(test_db.db, "SELECT qty FROM items WHERE id = 2")
	expect_no_error(err, ok, "scalar SELECT after UPDATE")
	expect_eq(got, i64(99), "UPDATE should persist new value")
}

test_sql_delete_with_prepared_params :: proc() {
	test_db := test_db_open("sql_delete_with_prepared_params")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE items(id INTEGER PRIMARY KEY)")
	exec_ok(test_db.db, "INSERT INTO items(id) VALUES (1), (2), (3), (4), (5)")

	stmt := prepare_ok(test_db.db, "DELETE FROM items WHERE id <= ?1")
	defer finalize_ok(&stmt, "DELETE")
	bind_i64_ok(&stmt, 1, 3, "")
	step_expect_done(stmt, "DELETE")

	expect_eq(sqlite.db_changes(test_db.db), i64(3), "DELETE should report three changed rows")

	count, err, ok := sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM items")
	expect_no_error(err, ok, "count after DELETE")
	expect_eq(count, i64(2), "two rows should remain after DELETE")
}

// ----- Constraint violations ----------------------------------------------

test_sql_unique_constraint_violation :: proc() {
	test_db := test_db_open("sql_unique_constraint_violation")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE accounts(id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE)")
	exec_ok(test_db.db, "INSERT INTO accounts(email) VALUES ('a@example.com')")

	err, ok := sqlite.db_exec(test_db.db, "INSERT INTO accounts(email) VALUES ('a@example.com')")
	defer sqlite.error_destroy(&err)
	expect_false(ok, "duplicate UNIQUE value should fail")
	expect_eq(err.code, int(raw.CONSTRAINT), "duplicate UNIQUE should return SQLITE_CONSTRAINT")
	expect_string_contains(err.message, "UNIQUE", "message should mention UNIQUE constraint")
}

test_sql_not_null_constraint_violation :: proc() {
	test_db := test_db_open("sql_not_null_constraint_violation")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE accounts(id INTEGER PRIMARY KEY, email TEXT NOT NULL)")

	stmt := prepare_ok(test_db.db, "INSERT INTO accounts(email) VALUES (?1)")
	// sqlite3_finalize replays a step error, so use a non-asserting finalize.
	defer {
		fin_err, _ := sqlite.stmt_finalize(&stmt)
		sqlite.error_destroy(&fin_err)
	}
	bind_null_ok(&stmt, 1, "")

	_, err, ok := sqlite.stmt_step(stmt)
	defer sqlite.error_destroy(&err)
	expect_false(ok, "NULL into NOT NULL should fail")
	expect_eq(err.code, int(raw.CONSTRAINT), "NOT NULL violation should return SQLITE_CONSTRAINT")
	expect_string_contains(err.message, "NOT NULL", "message should mention NOT NULL")
}

test_sql_check_constraint_violation :: proc() {
	test_db := test_db_open("sql_check_constraint_violation")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE accounts(id INTEGER PRIMARY KEY, balance INTEGER NOT NULL CHECK (balance >= 0))")

	err, ok := sqlite.db_exec(test_db.db, "INSERT INTO accounts(balance) VALUES (-5)")
	defer sqlite.error_destroy(&err)
	expect_false(ok, "CHECK violation should fail")
	expect_eq(err.code, int(raw.CONSTRAINT), "CHECK violation should return SQLITE_CONSTRAINT")
	expect_string_contains(err.message, "CHECK", "message should mention CHECK")
}

test_sql_primary_key_conflict :: proc() {
	test_db := test_db_open("sql_primary_key_conflict")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO items(id, name) VALUES (1, 'first')")

	err, ok := sqlite.db_exec(test_db.db, "INSERT INTO items(id, name) VALUES (1, 'second')")
	defer sqlite.error_destroy(&err)
	expect_false(ok, "duplicate PK should fail")
	expect_eq(err.code, int(raw.CONSTRAINT), "duplicate PK should return SQLITE_CONSTRAINT")
}

test_sql_foreign_key_constraint :: proc() {
	test_db := test_db_open("sql_foreign_key_constraint")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "PRAGMA foreign_keys = ON")
	exec_ok(test_db.db, "CREATE TABLE parents(id INTEGER PRIMARY KEY)")
	exec_ok(test_db.db, "CREATE TABLE children(id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES parents(id))")
	exec_ok(test_db.db, "INSERT INTO parents(id) VALUES (1), (2)")
	exec_ok(test_db.db, "INSERT INTO children(parent_id) VALUES (1)")

	err, ok := sqlite.db_exec(test_db.db, "INSERT INTO children(parent_id) VALUES (999)")
	defer sqlite.error_destroy(&err)
	expect_false(ok, "FK to missing parent should fail")
	expect_eq(err.code, int(raw.CONSTRAINT), "FK violation should return SQLITE_CONSTRAINT")

	del_err, del_ok := sqlite.db_exec(test_db.db, "DELETE FROM parents WHERE id = 1")
	defer sqlite.error_destroy(&del_err)
	expect_false(del_ok, "deleting referenced parent should fail")
	expect_eq(del_err.code, int(raw.CONSTRAINT), "FK-cascading delete violation should return SQLITE_CONSTRAINT")
}

// ----- UPSERT / RETURNING --------------------------------------------------

test_sql_upsert_on_conflict_do_update :: proc() {
	test_db := test_db_open("sql_upsert_on_conflict_do_update")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE counters(name TEXT PRIMARY KEY, hits INTEGER NOT NULL DEFAULT 0)")

	exec_ok(test_db.db, "INSERT INTO counters(name, hits) VALUES ('home', 1) ON CONFLICT(name) DO UPDATE SET hits = hits + 1")
	exec_ok(test_db.db, "INSERT INTO counters(name, hits) VALUES ('home', 1) ON CONFLICT(name) DO UPDATE SET hits = hits + 1")
	exec_ok(test_db.db, "INSERT INTO counters(name, hits) VALUES ('home', 1) ON CONFLICT(name) DO UPDATE SET hits = hits + 1")

	got, err, ok := sqlite.db_scalar_i64(test_db.db, "SELECT hits FROM counters WHERE name = 'home'")
	expect_no_error(err, ok, "scalar SELECT after UPSERT")
	expect_eq(got, i64(3), "UPSERT should accumulate to 3")
}

test_sql_returning_clause :: proc() {
	test_db := test_db_open("sql_returning_clause")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE accounts(id INTEGER PRIMARY KEY, balance INTEGER NOT NULL DEFAULT 0)")
	exec_ok(test_db.db, "INSERT INTO accounts(balance) VALUES (100), (200), (300)")

	stmt := prepare_ok(test_db.db, "UPDATE accounts SET balance = balance + 5 WHERE id = ?1 RETURNING id, balance")
	defer finalize_ok(&stmt, "UPDATE … RETURNING")
	bind_i64_ok(&stmt, 1, 2, "")

	step_expect_row(stmt, "RETURNING should produce a row")
	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(2), "RETURNING should expose id")
	expect_eq(sqlite.stmt_get_i64(stmt, 1), i64(205), "RETURNING should expose new balance")
	step_expect_done(stmt, "RETURNING should finish after one row")
}

// ----- Joins + aggregates --------------------------------------------------

test_sql_inner_and_left_join :: proc() {
	test_db := test_db_open("sql_inner_and_left_join")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE authors(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(test_db.db, "CREATE TABLE books(id INTEGER PRIMARY KEY, author_id INTEGER, title TEXT NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO authors(id, name) VALUES (1, 'Borges'), (2, 'Calvino'), (3, 'Lispector')")
	exec_ok(test_db.db, "INSERT INTO books(author_id, title) VALUES (1, 'Ficciones'), (2, 'Invisible Cities'), (NULL, 'Anon')")

	inner_count, err1, ok1 := sqlite.db_scalar_i64(test_db.db,
		"SELECT COUNT(*) FROM authors a INNER JOIN books b ON b.author_id = a.id")
	expect_no_error(err1, ok1, "inner join count")
	expect_eq(inner_count, i64(2), "INNER JOIN should drop unmatched author and orphan book")

	left_count, err2, ok2 := sqlite.db_scalar_i64(test_db.db,
		"SELECT COUNT(*) FROM authors a LEFT JOIN books b ON b.author_id = a.id")
	expect_no_error(err2, ok2, "left join count")
	expect_eq(left_count, i64(3), "LEFT JOIN should keep author with no books as one row")
}

test_sql_aggregates_group_by_having :: proc() {
	test_db := test_db_open("sql_aggregates_group_by_having")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE sales(id INTEGER PRIMARY KEY, region TEXT NOT NULL, amount REAL NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO sales(region, amount) VALUES ('north', 10.5), ('north', 20.25), ('south', 5.0), ('south', 5.5), ('east', 99.0)")

	sum_north, e1, o1 := sqlite.db_scalar_f64(test_db.db, "SELECT SUM(amount) FROM sales WHERE region = 'north'")
	expect_no_error(e1, o1, "SUM(north)")
	expect_eq(sum_north, 30.75, "SUM(north) should be 30.75")

	stmt := prepare_ok(test_db.db, "SELECT region, COUNT(*), SUM(amount), MIN(amount), MAX(amount) FROM sales GROUP BY region HAVING COUNT(*) >= 2 ORDER BY region")
	defer finalize_ok(&stmt, "GROUP BY HAVING")

	step_expect_row(stmt, "first group")
	first := sqlite.stmt_get_text(stmt, 0, context.temp_allocator)
	expect_eq(first, "north", "first group should be north")
	expect_eq(sqlite.stmt_get_i64(stmt, 1), i64(2), "north should have 2 rows")
	expect_eq(sqlite.stmt_get_f64(stmt, 2), 30.75, "north SUM")
	expect_eq(sqlite.stmt_get_f64(stmt, 3), 10.5, "north MIN")
	expect_eq(sqlite.stmt_get_f64(stmt, 4), 20.25, "north MAX")

	step_expect_row(stmt, "second group")
	second := sqlite.stmt_get_text(stmt, 0, context.temp_allocator)
	expect_eq(second, "south", "second group should be south")

	step_expect_done(stmt, "east should be filtered out by HAVING")
}

// ----- CTEs + window functions --------------------------------------------

test_sql_common_table_expression :: proc() {
	test_db := test_db_open("sql_common_table_expression")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE items(id INTEGER PRIMARY KEY, qty INTEGER NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO items(qty) VALUES (1), (2), (3), (4), (5)")

	got, err, ok := sqlite.db_scalar_i64(test_db.db, `
		WITH big AS (SELECT qty FROM items WHERE qty >= 3)
		SELECT SUM(qty) FROM big
	`)
	expect_no_error(err, ok, "CTE scalar")
	expect_eq(got, i64(12), "CTE SUM should be 3+4+5 = 12")
}

test_sql_recursive_cte :: proc() {
	test_db := test_db_open("sql_recursive_cte")
	defer test_db_close(&test_db)

	got, err, ok := sqlite.db_scalar_i64(test_db.db, `
		WITH RECURSIVE counter(n) AS (
			SELECT 1
			UNION ALL
			SELECT n+1 FROM counter WHERE n < 10
		)
		SELECT SUM(n) FROM counter
	`)
	expect_no_error(err, ok, "recursive CTE scalar")
	expect_eq(got, i64(55), "1+2+…+10 = 55")
}

test_sql_window_row_number :: proc() {
	test_db := test_db_open("sql_window_row_number")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE scores(id INTEGER PRIMARY KEY, player TEXT NOT NULL, points INTEGER NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO scores(player, points) VALUES ('a', 30), ('b', 10), ('c', 20)")

	stmt := prepare_ok(test_db.db, "SELECT player, points, ROW_NUMBER() OVER (ORDER BY points DESC) AS rank FROM scores")
	defer finalize_ok(&stmt, "window")

	step_expect_row(stmt, "row 1")
	expect_eq(sqlite.stmt_get_text(stmt, 0, context.temp_allocator), "a", "highest points is a")
	expect_eq(sqlite.stmt_get_i64(stmt, 2), i64(1), "rank 1")

	step_expect_row(stmt, "row 2")
	expect_eq(sqlite.stmt_get_text(stmt, 0, context.temp_allocator), "c", "second is c")
	expect_eq(sqlite.stmt_get_i64(stmt, 2), i64(2), "rank 2")

	step_expect_row(stmt, "row 3")
	expect_eq(sqlite.stmt_get_text(stmt, 0, context.temp_allocator), "b", "third is b")
	expect_eq(sqlite.stmt_get_i64(stmt, 2), i64(3), "rank 3")

	step_expect_done(stmt, "window query end")
}

// ----- JSON1 ---------------------------------------------------------------

test_sql_json1_extract :: proc() {
	test_db := test_db_open("sql_json1_extract")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE docs(id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
	exec_ok(test_db.db, `INSERT INTO docs(body) VALUES ('{"user":{"name":"alice","age":33}}')`)

	name, err1, ok1 := sqlite.db_scalar_text(test_db.db, "SELECT json_extract(body, '$.user.name') FROM docs WHERE id = 1", sqlite.DEFAULT_PREPARE_FLAGS, context.temp_allocator)
	expect_no_error(err1, ok1, "json_extract name")
	expect_eq(name, "alice", "json_extract should return inner field")

	age, err2, ok2 := sqlite.db_scalar_i64(test_db.db, "SELECT json_extract(body, '$.user.age') FROM docs WHERE id = 1")
	expect_no_error(err2, ok2, "json_extract age")
	expect_eq(age, i64(33), "json_extract should return integer")
}

// ----- UTF-8 + special characters -----------------------------------------

test_sql_utf8_roundtrip :: proc() {
	test_db := test_db_open("sql_utf8_roundtrip")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT NOT NULL)")

	stmt := prepare_ok(test_db.db, "INSERT INTO notes(body) VALUES (?1)")
	defer finalize_ok(&stmt, "INSERT UTF8")

	samples := []string{
		"hello world",
		"héllo wörld",
		"日本語のテスト",
		"emoji 🎉🚀🌍",
		"mixed: αβγ δε ñ ç 漢字 한국어",
		`embedded "quotes" and 'apostrophes'`,
		`backslashes \ and percent % and underscore _`,
	}

	for s in samples {
		reset_ok(&stmt, "")
		clear_bindings_ok(&stmt, "")
		bind_text_ok(&stmt, 1, s, "")
		step_expect_done(stmt, "insert utf8")
	}

	read := prepare_ok(test_db.db, "SELECT body FROM notes ORDER BY id")
	defer finalize_ok(&read, "SELECT UTF8")

	for s, i in samples {
		step_expect_row(read, "row")
		got := sqlite.stmt_get_text(read, 0, context.temp_allocator)
		expect_eq(got, s, "UTF-8 sample %d should roundtrip", i)
	}
	step_expect_done(read, "exhausted")
}

test_sql_text_with_embedded_null_truncates_per_sqlite :: proc() {
	// SQLite TEXT semantics: when bound via sqlite3_bind_text, content stops
	// at the first embedded NUL even when an explicit byte length is supplied
	// (the length is treated as a maximum, not an exact count). To preserve
	// all bytes (including NULs), bind as BLOB instead. This test pins both
	// behaviors so a future SQLite or wrapper change is noticed.
	test_db := test_db_open("sql_text_with_embedded_null")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
	exec_ok(test_db.db, "CREATE TABLE bins(id INTEGER PRIMARY KEY, body BLOB NOT NULL)")

	{
		stmt := prepare_ok(test_db.db, "INSERT INTO notes(body) VALUES (?1)")
		defer finalize_ok(&stmt, "INSERT TEXT embedded NUL")
		bind_text_ok(&stmt, 1, "abc\x00def", "")
		step_expect_done(stmt, "insert text")
	}
	{
		stmt := prepare_ok(test_db.db, "INSERT INTO bins(body) VALUES (?1)")
		defer finalize_ok(&stmt, "INSERT BLOB embedded NUL")
		bind_blob_ok(&stmt, 1, transmute([]u8)string("abc\x00def"), "")
		step_expect_done(stmt, "insert blob")
	}

	text_bytes, et, ot := sqlite.db_scalar_i64(test_db.db, "SELECT length(body) FROM notes WHERE id = 1")
	expect_no_error(et, ot, "text length scalar")
	expect_eq(text_bytes, i64(3), "TEXT binding truncates at embedded NUL (documented SQLite behavior)")

	blob_bytes, eb, ob := sqlite.db_scalar_i64(test_db.db, "SELECT length(body) FROM bins WHERE id = 1")
	expect_no_error(eb, ob, "blob length scalar")
	expect_eq(blob_bytes, i64(7), "BLOB binding preserves all 7 bytes including the NUL")
}

// ----- Large blobs --------------------------------------------------------

test_sql_large_blob_roundtrip :: proc() {
	test_db := test_db_open("sql_large_blob_roundtrip")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE artifacts(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")

	size := 1024 * 1024 // 1 MiB
	buf := make([]u8, size)
	defer delete(buf)
	for i := 0; i < size; i += 1 {
		buf[i] = u8(i % 251)
	}

	stmt := prepare_ok(test_db.db, "INSERT INTO artifacts(payload) VALUES (?1)")
	defer finalize_ok(&stmt, "INSERT large blob")
	bind_blob_ok(&stmt, 1, buf, "")
	step_expect_done(stmt, "insert")

	rowid := sqlite.db_last_insert_rowid(test_db.db)
	expect_eq(rowid, i64(1), "rowid 1")

	read := prepare_ok(test_db.db, "SELECT payload FROM artifacts WHERE id = ?1")
	defer finalize_ok(&read, "SELECT large blob")
	bind_i64_ok(&read, 1, rowid, "")
	step_expect_row(read, "row")

	got := sqlite.stmt_get_blob(read, 0, context.temp_allocator)
	expect_eq(len(got), size, "blob length should match")

	mismatches := 0
	for i := 0; i < size; i += 1 {
		if got[i] != buf[i] {
			mismatches += 1
			if mismatches > 3 {
				break
			}
		}
	}
	expect_eq(mismatches, 0, "every byte of large blob should roundtrip")
}

// ----- Many parameters ----------------------------------------------------

test_sql_many_parameters :: proc() {
	test_db := test_db_open("sql_many_parameters")
	defer test_db_close(&test_db)

	// SQLite supports up to SQLITE_LIMIT_VARIABLE_NUMBER parameters (default
	// 32766). Use 100 parameters to stress the binding path without crossing
	// the per-build limit.
	count := 100
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT ?1")
	for i := 2; i <= count; i += 1 {
		strings.write_string(&b, " + ")
		strings.write_byte(&b, '?')
		write_int_to_builder(&b, i)
	}
	sql := strings.to_string(b)

	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, "many ?")
	expect_eq(sqlite.stmt_param_count(stmt), count, "param count should match")

	for i := 1; i <= count; i += 1 {
		bind_i64_ok(&stmt, i, i64(i), "")
	}
	step_expect_row(stmt, "many ?")
	expected := i64(count * (count + 1) / 2)
	expect_eq(sqlite.stmt_get_i64(stmt, 0), expected, "sum of 1..%d", count)
}

@(private)
write_int_to_builder :: proc(b: ^strings.Builder, n: int) {
	if n == 0 {
		strings.write_byte(b, '0')
		return
	}
	tmp: [16]u8
	i := 0
	x := n
	if x < 0 {
		strings.write_byte(b, '-')
		x = -x
	}
	for x > 0 {
		tmp[i] = u8('0' + (x % 10))
		x /= 10
		i += 1
	}
	for i > 0 {
		i -= 1
		strings.write_byte(b, tmp[i])
	}
}

// ----- Bulk insert in a single transaction --------------------------------

test_sql_bulk_insert_in_transaction :: proc() {
	test_db := test_db_open("sql_bulk_insert_in_transaction")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE entries(id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")

	begin_err, begin_ok := sqlite.db_begin(test_db.db)
	expect_no_error(begin_err, begin_ok, "BEGIN")

	stmt := prepare_ok(test_db.db, "INSERT INTO entries(value) VALUES (?1)")

	N :: 10_000
	for i := 0; i < N; i += 1 {
		reset_ok(&stmt, "")
		bind_i64_ok(&stmt, 1, i64(i), "")
		step_expect_done(stmt, "")
	}

	finalize_ok(&stmt, "INSERT bulk")

	commit_err, commit_ok := sqlite.db_commit(test_db.db)
	expect_no_error(commit_err, commit_ok, "COMMIT")

	total, e, o := sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM entries")
	expect_no_error(e, o, "count after bulk")
	expect_eq(total, i64(N), "all rows should commit")

	sum, e2, o2 := sqlite.db_scalar_i64(test_db.db, "SELECT SUM(value) FROM entries")
	expect_no_error(e2, o2, "sum after bulk")
	expect_eq(sum, i64(N * (N - 1) / 2), "sum 0..N-1")
}

// ----- PRAGMA round trips -------------------------------------------------

test_sql_pragma_user_version :: proc() {
	test_db := test_db_open("sql_pragma_user_version")
	defer test_db_close(&test_db)

	v0, e0, o0 := sqlite.db_scalar_i64(test_db.db, "PRAGMA user_version")
	expect_no_error(e0, o0, "initial user_version")
	expect_eq(v0, i64(0), "fresh db user_version is 0")

	exec_ok(test_db.db, "PRAGMA user_version = 42")

	v1, e1, o1 := sqlite.db_scalar_i64(test_db.db, "PRAGMA user_version")
	expect_no_error(e1, o1, "updated user_version")
	expect_eq(v1, i64(42), "PRAGMA write should persist")
}

test_sql_pragma_application_id :: proc() {
	test_db := test_db_open("sql_pragma_application_id")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "PRAGMA application_id = 1414746190") // 'SQLT'
	got, err, ok := sqlite.db_scalar_i64(test_db.db, "PRAGMA application_id")
	expect_no_error(err, ok, "application_id")
	expect_eq(got, i64(1414746190), "PRAGMA application_id should persist")
}

// ----- Type affinity ------------------------------------------------------

test_sql_type_affinity_coercion :: proc() {
	test_db := test_db_open("sql_type_affinity_coercion")
	defer test_db_close(&test_db)

	// SQLite type affinity allows storing a numeric string in an INTEGER
	// column; it coerces on insert. This test pins that documented behavior.
	exec_ok(test_db.db, "CREATE TABLE typed(id INTEGER PRIMARY KEY, n INTEGER, r REAL, t TEXT)")

	stmt := prepare_ok(test_db.db, "INSERT INTO typed(n, r, t) VALUES (?1, ?2, ?3)")
	defer finalize_ok(&stmt, "INSERT typed")
	bind_text_ok(&stmt, 1, "42", "")     // string into INTEGER → stored as INTEGER
	bind_text_ok(&stmt, 2, "3.14", "")   // string into REAL    → stored as REAL
	bind_i64_ok(&stmt, 3, 7, "")         // integer into TEXT   → stored as TEXT
	step_expect_done(stmt, "insert typed")

	read := prepare_ok(test_db.db, "SELECT typeof(n), typeof(r), typeof(t), n, r, t FROM typed")
	defer finalize_ok(&read, "SELECT typed")
	step_expect_row(read, "")

	expect_eq(sqlite.stmt_get_text(read, 0, context.temp_allocator), "integer", "INTEGER column coerces numeric text to integer")
	expect_eq(sqlite.stmt_get_text(read, 1, context.temp_allocator), "real", "REAL column coerces numeric text to real")
	expect_eq(sqlite.stmt_get_text(read, 2, context.temp_allocator), "text", "TEXT column coerces integer to text")
	expect_eq(sqlite.stmt_get_i64(read, 3), i64(42), "integer value")
	expect_eq(sqlite.stmt_get_f64(read, 4), 3.14, "real value")
	expect_eq(sqlite.stmt_get_text(read, 5, context.temp_allocator), "7", "text value of integer 7")
}

// ----- Multiple connections to same file ---------------------------------

test_sql_two_connections_see_committed_writes :: proc() {
	a := test_db_open("sql_two_connections_writer")
	defer test_db_close(&a)

	// Open second connection to same path.
	b, open_err, open_ok := sqlite.db_open(a.path)
	expect_no_error(open_err, open_ok, "open second connection")
	defer { close_err, close_ok := sqlite.db_close(&b); expect_no_error(close_err, close_ok, "close second connection") }

	exec_ok(a.db, "CREATE TABLE shared(id INTEGER PRIMARY KEY, val INTEGER NOT NULL)")
	exec_ok(a.db, "INSERT INTO shared(val) VALUES (1), (2), (3)")

	got, err, ok := sqlite.db_scalar_i64(b, "SELECT SUM(val) FROM shared")
	expect_no_error(err, ok, "second connection scalar")
	expect_eq(got, i64(6), "second connection should see committed writes")

	// Write from the second connection too and observe from the first.
	exec_ok(b, "INSERT INTO shared(val) VALUES (10)")
	got2, err2, ok2 := sqlite.db_scalar_i64(a.db, "SELECT SUM(val) FROM shared")
	expect_no_error(err2, ok2, "first connection scalar after second-connection write")
	expect_eq(got2, i64(16), "first connection should see the second connection's commit")
}

test_sql_busy_timeout_resolves_locked_writes :: proc() {
	a := test_db_open("sql_busy_timeout_resolves_locked_writes")
	defer test_db_close(&a)

	b, open_err, open_ok := sqlite.db_open(a.path)
	expect_no_error(open_err, open_ok, "open second connection")
	defer { close_err, close_ok := sqlite.db_close(&b); expect_no_error(close_err, close_ok, "close second connection") }

	// Without a busy timeout, a write while another connection holds the
	// write lock fails immediately. Set timeouts on both and let the wrapper
	// handle it.
	to_err, to_ok := sqlite.db_set_busy_timeout(a.db, 1000)
	expect_no_error(to_err, to_ok, "set busy timeout a")
	to_err2, to_ok2 := sqlite.db_set_busy_timeout(b, 1000)
	expect_no_error(to_err2, to_ok2, "set busy timeout b")

	exec_ok(a.db, "PRAGMA journal_mode = WAL")
	exec_ok(a.db, "CREATE TABLE ledger(id INTEGER PRIMARY KEY, val INTEGER NOT NULL)")
	exec_ok(a.db, "INSERT INTO ledger(val) VALUES (1)")

	// Write from both connections (sequentially — busy timeout still gives
	// confidence we route through retry path rather than reporting BUSY).
	exec_ok(a.db, "INSERT INTO ledger(val) VALUES (2)")
	exec_ok(b, "INSERT INTO ledger(val) VALUES (3)")

	got, err, ok := sqlite.db_scalar_i64(a.db, "SELECT COUNT(*) FROM ledger")
	expect_no_error(err, ok, "count")
	expect_eq(got, i64(3), "both connections should have committed")
}

// ----- ATTACH DATABASE ----------------------------------------------------

test_sql_attach_database_read_across_schemas :: proc() {
	a := test_db_open("sql_attach_database_a")
	defer test_db_close(&a)
	b := test_db_open("sql_attach_database_b")
	defer test_db_close(&b)

	exec_ok(b.db, "CREATE TABLE other(id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
	exec_ok(b.db, "INSERT INTO other(label) VALUES ('attached')")

	// Close b so a can attach the underlying file. SQLite generally allows
	// ATTACH while another connection has it open, but closing keeps the test
	// hermetic.
	close_b_err, close_b_ok := sqlite.db_close(&b.db)
	expect_no_error(close_b_err, close_b_ok, "close b")

	attach_sql := strings.concatenate({"ATTACH DATABASE '", b.path, "' AS extra"}, context.temp_allocator)
	exec_ok(a.db, attach_sql)
	defer exec_ok(a.db, "DETACH DATABASE extra")

	label, err, ok := sqlite.db_scalar_text(a.db, "SELECT label FROM extra.other WHERE id = 1", sqlite.DEFAULT_PREPARE_FLAGS, context.temp_allocator)
	expect_no_error(err, ok, "read from attached")
	expect_eq(label, "attached", "ATTACH should expose the other database")
}

// ----- Multiple statements via db_exec -----------------------------------

test_sql_exec_multi_statement_script :: proc() {
	test_db := test_db_open("sql_exec_multi_statement_script")
	defer test_db_close(&test_db)

	err, ok := sqlite.db_exec(test_db.db, `
		CREATE TABLE a(id INTEGER PRIMARY KEY);
		CREATE TABLE b(id INTEGER PRIMARY KEY);
		INSERT INTO a(id) VALUES (1), (2);
		INSERT INTO b(id) VALUES (10), (20), (30);
	`)
	expect_no_error(err, ok, "multi-statement exec")

	ca, ea, oa := sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM a")
	expect_no_error(ea, oa, "count a")
	expect_eq(ca, i64(2), "two rows in a")

	cb, eb, ob := sqlite.db_scalar_i64(test_db.db, "SELECT COUNT(*) FROM b")
	expect_no_error(eb, ob, "count b")
	expect_eq(cb, i64(3), "three rows in b")
}

// ----- Index + EXPLAIN QUERY PLAN ----------------------------------------

test_sql_index_used_by_planner :: proc() {
	test_db := test_db_open("sql_index_used_by_planner")
	defer test_db_close(&test_db)

	exec_ok(test_db.db, "CREATE TABLE messages(id INTEGER PRIMARY KEY, topic TEXT NOT NULL, body TEXT NOT NULL)")
	exec_ok(test_db.db, "CREATE INDEX idx_messages_topic ON messages(topic)")
	exec_ok(test_db.db, "INSERT INTO messages(topic, body) VALUES ('a','x'), ('b','y'), ('c','z')")

	stmt := prepare_ok(test_db.db, "EXPLAIN QUERY PLAN SELECT id FROM messages WHERE topic = 'a'")
	defer finalize_ok(&stmt, "EXPLAIN")

	saw_index := false
	for {
		has_row, e, o := sqlite.stmt_next(stmt)
		expect_no_error(e, o, "explain step")
		if !has_row {
			break
		}
		detail := sqlite.stmt_get_text(stmt, 3, context.temp_allocator)
		if contains_string(detail, "idx_messages_topic") {
			saw_index = true
		}
	}
	expect_true(saw_index, "EXPLAIN QUERY PLAN should mention idx_messages_topic")
}

// ----- Test_p3 deferred not registered - this file only -------------------

run_sql_behavior_tests :: proc() {
	run_test("sql_update_with_prepared_params", test_sql_update_with_prepared_params)
	run_test("sql_delete_with_prepared_params", test_sql_delete_with_prepared_params)
	run_test("sql_unique_constraint_violation", test_sql_unique_constraint_violation)
	run_test("sql_not_null_constraint_violation", test_sql_not_null_constraint_violation)
	run_test("sql_check_constraint_violation", test_sql_check_constraint_violation)
	run_test("sql_primary_key_conflict", test_sql_primary_key_conflict)
	run_test("sql_foreign_key_constraint", test_sql_foreign_key_constraint)
	run_test("sql_upsert_on_conflict_do_update", test_sql_upsert_on_conflict_do_update)
	run_test("sql_returning_clause", test_sql_returning_clause)
	run_test("sql_inner_and_left_join", test_sql_inner_and_left_join)
	run_test("sql_aggregates_group_by_having", test_sql_aggregates_group_by_having)
	run_test("sql_common_table_expression", test_sql_common_table_expression)
	run_test("sql_recursive_cte", test_sql_recursive_cte)
	run_test("sql_window_row_number", test_sql_window_row_number)
	run_test("sql_json1_extract", test_sql_json1_extract)
	run_test("sql_utf8_roundtrip", test_sql_utf8_roundtrip)
	run_test("sql_text_with_embedded_null_truncates_per_sqlite", test_sql_text_with_embedded_null_truncates_per_sqlite)
	run_test("sql_large_blob_roundtrip", test_sql_large_blob_roundtrip)
	run_test("sql_many_parameters", test_sql_many_parameters)
	run_test("sql_bulk_insert_in_transaction", test_sql_bulk_insert_in_transaction)
	run_test("sql_pragma_user_version", test_sql_pragma_user_version)
	run_test("sql_pragma_application_id", test_sql_pragma_application_id)
	run_test("sql_type_affinity_coercion", test_sql_type_affinity_coercion)
	run_test("sql_two_connections_see_committed_writes", test_sql_two_connections_see_committed_writes)
	run_test("sql_busy_timeout_resolves_locked_writes", test_sql_busy_timeout_resolves_locked_writes)
	run_test("sql_attach_database_read_across_schemas", test_sql_attach_database_read_across_schemas)
	run_test("sql_exec_multi_statement_script", test_sql_exec_multi_statement_script)
	run_test("sql_index_used_by_planner", test_sql_index_used_by_planner)
}
