package main

import sqlite "../../../sqlite"
import raw "../../../sqlite/raw/generated"

// SQLITE-FEATURE-CONTRACT: sql.values.storage-affinity.v1
// Feature: SQLite storage classes, column affinity, and typed boundary values.
// SQLite source: input/sqlite3.h and https://sqlite.org/datatype3.html
// Requirement: Bound NULL, INTEGER, REAL, TEXT, and BLOB values retain their documented
// storage classes; affinity performs only documented conversions; signed 64-bit endpoints,
// empty TEXT, empty BLOB, and embedded-NUL payloads remain distinguishable.
// Adversarial cases: NULL versus two zero-length classes; embedded NUL in TEXT and BLOB;
// minimum and maximum i64; numeric text crossing INTEGER, REAL, TEXT, NUMERIC, and BLOB affinity.
// Oracle: After close and reopen, an ordered separately prepared SELECT checks column types,
// byte counts, exact values, and affinity results through explicit column accessors.
// Guardrail: Do not conflate NULL with empty values, truncate a bound embedded-NUL buffer,
// or accept wrapper-observed coercions that differ from SQLite's documented affinity rules.
test_storage_classes_affinity_boundaries :: proc() {
	fixture := open_fixture("storage_classes_affinity")
	defer close_fixture(&fixture)

	exec_ok(fixture.db, "CREATE TABLE flexible(id INTEGER PRIMARY KEY, value)")
	exec_ok(
		fixture.db,
		"CREATE TABLE affinity(id INTEGER PRIMARY KEY, i INTEGER, r REAL, t TEXT, n NUMERIC, b BLOB)",
	)

	insert := prepare_ok(fixture.db, "INSERT INTO flexible(id, value) VALUES (?1, ?2)")
	bind_i64(&insert, 1, 1)
	bind_null(&insert, 2)
	step_done(insert)

	reuse(&insert)
	bind_i64(&insert, 1, 2)
	bind_i64(&insert, 2, min(i64))
	step_done(insert)

	reuse(&insert)
	bind_i64(&insert, 1, 3)
	bind_i64(&insert, 2, max(i64))
	step_done(insert)

	reuse(&insert)
	bind_i64(&insert, 1, 4)
	bind_f64(&insert, 2, 1.5)
	step_done(insert)

	reuse(&insert)
	bind_i64(&insert, 1, 5)
	bind_text(&insert, 2, "")
	step_done(insert)

	reuse(&insert)
	bind_i64(&insert, 1, 6)
	bind_blob(&insert, 2, []u8{})
	step_done(insert)

	reuse(&insert)
	bind_i64(&insert, 1, 7)
	bind_text(&insert, 2, "abc\x00def")
	step_done(insert)

	reuse(&insert)
	bind_i64(&insert, 1, 8)
	bind_blob(&insert, 2, []u8{0, 1, 0, 255})
	step_done(insert)
	finalize_ok(&insert)

	affinity_insert := prepare_ok(
		fixture.db,
		"INSERT INTO affinity(id, i, r, t, n, b) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
	)
	bind_i64(&affinity_insert, 1, 1)
	bind_text(&affinity_insert, 2, "42")
	bind_text(&affinity_insert, 3, "3.5")
	bind_i64(&affinity_insert, 4, 7)
	bind_text(&affinity_insert, 5, "3.0e+5")
	bind_text(&affinity_insert, 6, "11")
	step_done(affinity_insert)
	finalize_ok(&affinity_insert)

	reopen_fixture(&fixture)

	read := prepare_ok(fixture.db, "SELECT typeof(value), value FROM flexible ORDER BY id")
	step_row(read)
	expect_equal(sqlite.stmt_get_text(read, 0, context.temp_allocator), "null", "NULL typeof")
	expect(sqlite.stmt_is_null(read, 1), "NULL must remain NULL")

	step_row(read)
	expect_equal(
		sqlite.stmt_get_text(read, 0, context.temp_allocator),
		"integer",
		"minimum i64 typeof",
	)
	expect_equal(sqlite.stmt_get_i64(read, 1), min(i64), "minimum i64 round trip")

	step_row(read)
	expect_equal(
		sqlite.stmt_get_text(read, 0, context.temp_allocator),
		"integer",
		"maximum i64 typeof",
	)
	expect_equal(sqlite.stmt_get_i64(read, 1), max(i64), "maximum i64 round trip")

	step_row(read)
	expect_equal(sqlite.stmt_get_text(read, 0, context.temp_allocator), "real", "REAL typeof")
	expect_equal(sqlite.stmt_get_f64(read, 1), 1.5, "REAL round trip")

	step_row(read)
	expect_equal(
		sqlite.stmt_get_text(read, 0, context.temp_allocator),
		"text",
		"empty TEXT typeof",
	)
	expect_equal(sqlite.stmt_column_type(read, 1), int(raw.TEXT), "empty TEXT column type")
	expect_equal(sqlite.stmt_get_text_bytes(read, 1), 0, "empty TEXT byte count")

	step_row(read)
	expect_equal(
		sqlite.stmt_get_text(read, 0, context.temp_allocator),
		"blob",
		"empty BLOB typeof",
	)
	expect_equal(sqlite.stmt_column_type(read, 1), int(raw.BLOB), "empty BLOB column type")
	expect_equal(sqlite.stmt_get_blob_bytes(read, 1), 0, "empty BLOB byte count")
	expect_equal(len(sqlite.stmt_get_blob(read, 1, context.temp_allocator)), 0, "empty BLOB value")

	step_row(read)
	expect_equal(
		sqlite.stmt_get_text(read, 0, context.temp_allocator),
		"text",
		"embedded-NUL TEXT typeof",
	)
	expect_equal(sqlite.stmt_get_text_bytes(read, 1), 7, "embedded-NUL TEXT byte count")
	embedded_text := sqlite.stmt_get_text(read, 1, context.temp_allocator)
	expect_text_bytes_equal(embedded_text, "abc\x00def", "embedded-NUL TEXT")

	step_row(read)
	expect_equal(
		sqlite.stmt_get_text(read, 0, context.temp_allocator),
		"blob",
		"embedded-NUL BLOB typeof",
	)
	embedded_blob := sqlite.stmt_get_blob(read, 1, context.temp_allocator)
	expect_bytes_equal(embedded_blob, []u8{0, 1, 0, 255}, "embedded-NUL BLOB")
	step_done(read)
	finalize_ok(&read)

	affinity_read := prepare_ok(
		fixture.db,
		"SELECT typeof(i), typeof(r), typeof(t), typeof(n), typeof(b), i, r, t, n, b FROM affinity WHERE id = ?1",
	)
	bind_i64(&affinity_read, 1, 1)
	step_row(affinity_read)
	expect_equal(
		sqlite.stmt_get_text(affinity_read, 0, context.temp_allocator),
		"integer",
		"INTEGER affinity",
	)
	expect_equal(
		sqlite.stmt_get_text(affinity_read, 1, context.temp_allocator),
		"real",
		"REAL affinity",
	)
	expect_equal(
		sqlite.stmt_get_text(affinity_read, 2, context.temp_allocator),
		"text",
		"TEXT affinity",
	)
	expect_equal(
		sqlite.stmt_get_text(affinity_read, 3, context.temp_allocator),
		"integer",
		"NUMERIC affinity",
	)
	expect_equal(
		sqlite.stmt_get_text(affinity_read, 4, context.temp_allocator),
		"text",
		"BLOB affinity",
	)
	expect_equal(sqlite.stmt_get_i64(affinity_read, 5), i64(42), "INTEGER-affinity value")
	expect_equal(sqlite.stmt_get_f64(affinity_read, 6), 3.5, "REAL-affinity value")
	expect_equal(
		sqlite.stmt_get_text(affinity_read, 7, context.temp_allocator),
		"7",
		"TEXT-affinity value",
	)
	expect_equal(
		sqlite.stmt_get_i64(affinity_read, 8),
		i64(300000),
		"NUMERIC exponent becomes integer",
	)
	expect_equal(
		sqlite.stmt_get_text(affinity_read, 9, context.temp_allocator),
		"11",
		"BLOB affinity preserves text",
	)
	step_done(affinity_read)
	finalize_ok(&affinity_read)
}

// SQLITE-FEATURE-CONTRACT: sql.expressions.core.v1
// Feature: SQLite scalar expressions, three-valued logic, CASE, CAST, patterns, and collations.
// SQLite source: https://sqlite.org/lang_expr.html and https://sqlite.org/datatype3.html#collation
// Requirement: Operators propagate NULL according to SQLite's three-valued logic, integer
// overflow promotes arithmetic to REAL, CASE and CAST follow documented conversions, LIKE is
// ASCII case-insensitive by default, GLOB is case-sensitive, and collations control equality.
// Adversarial cases: Maximum-i64 addition, NULL mixed with true and false, division by zero,
// numeric-prefix casts, ASCII case differences, wildcard patterns, and malformed CASE syntax.
// Oracle: Explicit column types and values from one prepared expression statement are checked,
// then a separately prepared bound query proves the connection remains usable after invalid SQL.
// Guardrail: Do not use host-language truthiness, locale collation rules, or current wrapper
// conversions as the expected result; retain SQLite's documented NULL and conversion semantics.
test_expression_semantics :: proc() {
	fixture := open_fixture("expression_semantics")
	defer close_fixture(&fixture)

	sql := `SELECT
		typeof(?1 + ?2), (?1 + ?2),
		(?3 AND NULL) IS NULL, (?4 AND NULL) IS 0, (?5 OR NULL) IS 1,
		(NULL = NULL) IS NULL,
		CASE WHEN ?6 IS NULL THEN ?7 ELSE ?8 END,
		CAST(?9 AS INTEGER), CAST(?10 AS TEXT),
		?11 LIKE ?12, ?13 GLOB ?14,
		(?15 = ?16 COLLATE NOCASE), (?15 = ?16 COLLATE BINARY),
		(?17 / ?18) IS NULL,
		CAST(?19 AS INTEGER)`
	stmt := prepare_ok(fixture.db, sql)
	bind_i64(&stmt, 1, max(i64))
	bind_i64(&stmt, 2, 1)
	bind_i64(&stmt, 3, 1)
	bind_i64(&stmt, 4, 0)
	bind_i64(&stmt, 5, 1)
	bind_null(&stmt, 6)
	bind_text(&stmt, 7, "null arm")
	bind_text(&stmt, 8, "else arm")
	bind_text(&stmt, 9, "123xyz")
	bind_i64(&stmt, 10, 17)
	bind_text(&stmt, 11, "Alpha")
	bind_text(&stmt, 12, "a%")
	bind_text(&stmt, 13, "Alpha")
	bind_text(&stmt, 14, "a*")
	bind_text(&stmt, 15, "SQLite")
	bind_text(&stmt, 16, "sqlite")
	bind_i64(&stmt, 17, 7)
	bind_i64(&stmt, 18, 0)
	bind_text(&stmt, 19, "9223372036854775808")
	step_row(stmt)

	expect_equal(
		sqlite.stmt_get_text(stmt, 0, context.temp_allocator),
		"real",
		"overflow arithmetic type",
	)
	expect(
		sqlite.stmt_get_f64(stmt, 1) > 9.22e18,
		"overflow arithmetic must promote to a large REAL",
	)
	for column in 2 ..= 5 {
		expect_equal(
			sqlite.stmt_get_i64(stmt, column),
			i64(1),
			"three-valued logic column %d",
			column,
		)
	}
	expect_equal(
		sqlite.stmt_get_text(stmt, 6, context.temp_allocator),
		"null arm",
		"CASE NULL arm",
	)
	expect_equal(sqlite.stmt_get_i64(stmt, 7), i64(123), "CAST numeric prefix")
	expect_equal(
		sqlite.stmt_get_text(stmt, 8, context.temp_allocator),
		"17",
		"CAST integer to text",
	)
	expect_equal(sqlite.stmt_get_i64(stmt, 9), i64(1), "LIKE ASCII case folding")
	expect_equal(sqlite.stmt_get_i64(stmt, 10), i64(0), "GLOB case sensitivity")
	expect_equal(sqlite.stmt_get_i64(stmt, 11), i64(1), "NOCASE equality")
	expect_equal(sqlite.stmt_get_i64(stmt, 12), i64(0), "BINARY equality")
	expect_equal(sqlite.stmt_get_i64(stmt, 13), i64(1), "division by zero returns NULL")
	expect_equal(
		sqlite.stmt_get_i64(stmt, 14),
		max(i64),
		"out-of-range text-to-integer cast clamps",
	)
	step_done(stmt)
	finalize_ok(&stmt)

	prepare_fails(fixture.db, "SELECT CASE WHEN THEN ?1 END", int(raw.ERROR))
	probe := prepare_ok(fixture.db, "SELECT typeof(?1), ?1 IS NULL")
	bind_null(&probe, 1)
	step_row(probe)
	expect_equal(
		sqlite.stmt_get_text(probe, 0, context.temp_allocator),
		"null",
		"post-error bound typeof",
	)
	expect_equal(sqlite.stmt_get_i64(probe, 1), i64(1), "post-error NULL predicate")
	step_done(probe)
	finalize_ok(&probe)
}
