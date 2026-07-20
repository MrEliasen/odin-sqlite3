package engine_runtime

import "core:strings"
import raw "../../../sqlite/raw/generated"

require_pinned_runtime :: proc() {
	expect_eq(raw.libversion_number(), i32(raw.VERSION_NUMBER), "runtime/header SQLite version number")
	expect(cstring_equals(raw.libversion(), raw.VERSION), "runtime/header SQLite version string mismatch")
	expect(cstring_equals(raw.sourceid(), raw.SOURCE_ID), "runtime/header SQLite source id mismatch")
}

// SQLITE-FEATURE-CONTRACT: engine.statement.prepare-bind-lifecycle.v1
// Feature: Prepared-statement tail parsing, parameter metadata, bind, step, reset, clear, readonly, data-count, and finalize lifecycle.
// SQLite source: input/sqlite3.h sections "Compiling An SQL Statement", "Binding Values To Prepared Statements", and "Prepared Statement Status".
// Requirement: prepare_v2 compiles only the first statement and reports its tail; parameter indexes and names follow SQLite numbering; reset preserves bindings, clear changes them to NULL, and binding while a statement is busy returns SQLITE_MISUSE.
// Adversarial cases: Repeated named parameter, explicit ?5 gap, transient text storage released after bind, invalid indexes 0 and 6, bind attempted after SQLITE_ROW, and data-count checked before, during, and after row delivery.
// Oracle: Exact tail and parameter metadata are checked, row values and SQLite storage classes are read through column APIs, stable result codes are checked, and the cleared result is observed on a second execution.
// Guardrail: Do not infer metadata or lifecycle behavior from wrapper bookkeeping, accept a busy rebind, clear bindings during reset, or access the statement after finalize.
test_prepare_tail_bind_reset_clear_and_metadata :: proc() {
	db := open_db(":memory:")
	defer close_db(&db)

	sql := "SELECT ?1, :named, :named, ?5; SELECT 99;"
	c_sql := strings.clone_to_cstring(sql)
	defer delete(c_sql)
	statement: ^raw.Stmt
	tail: cstring
	expect_rc(raw.prepare_v2(db, c_sql, i32(len(sql)), &statement, &tail), raw.OK, "prepare first statement and tail")
	expect(statement != nil, "prepare must return the first statement")
	expect(cstring_equals(tail, " SELECT 99;"), "prepare tail must name the uncompiled second statement")
	defer finalize_ok(&statement)

	expect_eq(raw.bind_parameter_count(statement), i32(5), "rightmost ?NNN determines parameter count")
	expect(cstring_equals(raw.bind_parameter_name(statement, 1), "?1"), "parameter 1 name")
	expect(cstring_equals(raw.bind_parameter_name(statement, 2), ":named"), "parameter 2 name")
	expect(raw.bind_parameter_name(statement, 3) == nil, "unused parameter gap 3 must have no name")
	expect(raw.bind_parameter_name(statement, 4) == nil, "unused parameter gap 4 must have no name")
	expect(cstring_equals(raw.bind_parameter_name(statement, 5), "?5"), "parameter 5 name")
	expect_eq(raw.bind_parameter_index(statement, ":named"), i32(2), "named parameter lookup")
	expect_eq(raw.bind_parameter_index(statement, ":missing"), i32(0), "missing named parameter lookup")
	expect_eq(raw.stmt_readonly(statement), i32(1), "SELECT must be readonly")
	expect_eq(raw.column_count(statement), i32(4), "prepared SELECT column count")
	expect_eq(raw.data_count(statement), i32(0), "data count before step")

	bind_i64_ok(statement, 1, 17)
	transient_text := strings.clone_to_cstring("copied")
	expect_rc(
		raw.bind_text64(statement, 2, transient_text, 6, raw.TRANSIENT, u8(raw.UTF8)),
		raw.OK,
		"bind transient named text",
	)
	delete(transient_text)
	bind_i64_ok(statement, 5, 55)
	expect_rc(raw.bind_int64(statement, 0, 1), raw.RANGE, "bind index zero")
	expect_rc(raw.bind_int64(statement, 6, 1), raw.RANGE, "bind index beyond parameter count")

	step_row(statement)
	expect_eq(raw.data_count(statement), i32(4), "data count while row is available")
	expect_eq(i64(raw.column_int64(statement, 0)), i64(17), "bound parameter 1 value")
	expect_column_text(statement, 1, "copied")
	expect_column_text(statement, 2, "copied")
	expect_eq(i64(raw.column_int64(statement, 3)), i64(55), "bound parameter 5 value")
	expect_rc(raw.bind_int64(statement, 1, 99), raw.MISUSE, "binding a busy statement")

	expect_rc(raw.reset(statement), raw.OK, "reset after row")
	expect_eq(raw.data_count(statement), i32(0), "data count after reset")
	step_row(statement)
	expect_eq(i64(raw.column_int64(statement, 0)), i64(17), "reset preserves first binding")
	expect_column_text(statement, 1, "copied")
	expect_eq(i64(raw.column_int64(statement, 3)), i64(55), "reset preserves explicit ?5 binding")
	step_done(statement)
	expect_eq(raw.data_count(statement), i32(0), "data count after SQLITE_DONE")

	expect_rc(raw.reset(statement), raw.OK, "reset before clearing")
	expect_rc(raw.clear_bindings(statement), raw.OK, "clear all bindings")
	step_row(statement)
	for column in 0 ..< 4 {
		expect_eq(raw.column_type(statement, i32(column)), raw.NULL, "cleared column %d is NULL", column)
	}
	step_done(statement)

	write_statement := prepare_ok(db, "CREATE TABLE lifecycle_probe(id INTEGER)")
	expect_eq(raw.stmt_readonly(write_statement), i32(0), "DDL statement must not be readonly")
	step_done(write_statement)
	finalize_ok(&write_statement)
}

// SQLITE-FEATURE-CONTRACT: engine.statement.schema-auto-reprepare.v1
// Feature: Automatic reprepare of prepare_v2 statements after a schema change.
// SQLite source: input/sqlite3.h section "Compiling An SQL Statement" and SQLITE_STMTSTATUS_REPREPARE.
// Requirement: A prepare_v2 statement automatically recompiles when the schema changes, up to SQLITE_MAX_SCHEMA_RETRY, rather than surfacing SQLITE_SCHEMA for this successful query.
// Adversarial cases: The SELECT is prepared and bound on one connection, a second connection changes the table schema before first step, and the original statement is reused after reset.
// Oracle: sqlite3_step returns SQLITE_ROW with the original bound result, SQLITE_STMTSTATUS_REPREPARE increments, and a distinct statement observes the new schema column.
// Guardrail: Do not manually prepare a replacement in the test, accept SQLITE_SCHEMA as success, or inspect wrapper statement caches.
test_schema_change_auto_reprepare :: proc() {
	path := make_temp_db_path("schema_reprepare")
	defer delete(path)
	remove_db_files(path)
	defer remove_db_files(path)

	first := open_db(path)
	defer close_db(&first)
	second := open_db(path)
	defer close_db(&second)
	exec_ok(first, "CREATE TABLE schema_probe(id INTEGER PRIMARY KEY, value INTEGER)")
	expect_rc(insert_i64(first, "INSERT INTO schema_probe(value) VALUES(?1)", 41), raw.DONE, "insert schema probe")

	statement := prepare_ok(first, "SELECT value FROM schema_probe WHERE id=?1")
	defer finalize_ok(&statement)
	bind_i64_ok(statement, 1, 1)
	expect_eq(raw.stmt_status(statement, raw.STMTSTATUS_REPREPARE, 0), i32(0), "reprepare count before schema change")

	exec_ok(second, "ALTER TABLE schema_probe ADD COLUMN extra TEXT")
	step_row(statement)
	expect_eq(i64(raw.column_int64(statement, 0)), i64(41), "auto-reprepared statement result")
	expect(raw.stmt_status(statement, raw.STMTSTATUS_REPREPARE, 0) >= 1, "schema change must trigger automatic reprepare")
	step_done(statement)

	expect_rc(raw.reset(statement), raw.OK, "reset auto-reprepared statement")
	step_row(statement)
	expect_eq(i64(raw.column_int64(statement, 0)), i64(41), "reused auto-reprepared statement result")
	step_done(statement)

	schema_oracle := prepare_ok(second, "SELECT count(*) FROM pragma_table_info(?1) WHERE name=?2")
	bind_text_ok(schema_oracle, 1, "schema_probe")
	bind_text_ok(schema_oracle, 2, "extra")
	step_row(schema_oracle)
	expect_eq(i64(raw.column_int64(schema_oracle, 0)), i64(1), "second path observes added schema column")
	step_done(schema_oracle)
	finalize_ok(&schema_oracle)
}

// SQLITE-FEATURE-CONTRACT: engine.values.exact-null-text-blob-transport.v1
// Feature: Exact C-API transport of NULL, empty text, empty BLOB, embedded NUL bytes, and a large BLOB.
// SQLite source: input/sqlite3.h sections "Binding Values To Prepared Statements", "Result Values From A Query", and "Datatypes In SQLite".
// Requirement: Explicit-length binds preserve storage class and every byte; NULL, zero-byte TEXT, and zero-byte BLOB remain distinguishable, and SQLITE_TRANSIENT copies caller storage before bind returns.
// Adversarial cases: NULL, non-NULL zero-length text and BLOB, embedded NUL in both text and BLOB, and a 1 MiB patterned BLOB whose caller allocation is released immediately after binding.
// Oracle: A separately prepared SELECT checks sqlite3_column_type, sqlite3_column_bytes, and byte-for-byte values, followed by an independent typeof/hex/length query.
// Guardrail: Do not use C-string length for embedded-NUL values, treat a zero-length BLOB pointer as proof of NULL, or validate one convenience getter with another.
test_exact_text_blob_null_transport :: proc() {
	db := open_db(":memory:")
	defer close_db(&db)
	exec_ok(db, "CREATE TABLE transport(n, empty_text, empty_blob, nul_text, nul_blob, large_blob)")

	statement := prepare_ok(db, "INSERT INTO transport VALUES(?1, ?2, ?3, ?4, ?5, ?6)")
	bind_null_ok(statement, 1)
	bind_text_ok(statement, 2, "")
	empty := []u8{}
	bind_blob_ok(statement, 3, empty)
	nul_text := [4]u8{'a', 0, 'b', 0}
	expect_rc(
		raw.bind_text64(statement, 4, cstring(&nul_text[0]), 3, raw.TRANSIENT, u8(raw.UTF8)),
		raw.OK,
		"bind embedded-NUL text",
	)
	nul_blob := []u8{0x10, 0x00, 0x20}
	bind_blob_ok(statement, 5, nul_blob)
	large := make([]u8, 1024 * 1024)
	for _, index in large {
		large[index] = u8((index * 37 + 11) & 0xff)
	}
	bind_blob_ok(statement, 6, large)
	delete(large)
	step_done(statement)
	finalize_ok(&statement)

	reader := prepare_ok(db, "SELECT n, empty_text, empty_blob, nul_text, nul_blob, large_blob FROM transport")
	defer finalize_ok(&reader)
	step_row(reader)
	expect_eq(raw.column_type(reader, 0), raw.NULL, "explicit NULL storage class")
	expect_column_text(reader, 1, "")
	expect_column_blob(reader, 2, empty)
	expect_eq(raw.column_type(reader, 3), raw.TEXT, "embedded-NUL text storage class")
	expect_eq(raw.column_bytes(reader, 3), i32(3), "embedded-NUL text byte count")
	nul_text_actual := ([^]u8)(raw.column_text(reader, 3))[:3]
	for byte, index in nul_text_actual {
		expect_eq(byte, nul_text[index], "embedded-NUL text byte %d", index)
	}
	expect_column_blob(reader, 4, nul_blob)
	expect_eq(raw.column_type(reader, 5), raw.BLOB, "large value storage class")
	expect_eq(raw.column_bytes(reader, 5), i32(1024 * 1024), "large BLOB length")
	large_actual := ([^]u8)(raw.column_blob(reader, 5))[:1024 * 1024]
	for _, index in large_actual {
		expect_eq(large_actual[index], u8((index * 37 + 11) & 0xff), "large BLOB byte %d", index)
	}
	step_done(reader)

	oracle := prepare_ok(
		db,
		"SELECT typeof(n), typeof(empty_text), length(CAST(empty_text AS BLOB)), typeof(empty_blob), length(empty_blob), hex(nul_text), hex(nul_blob), length(large_blob) FROM transport",
	)
	defer finalize_ok(&oracle)
	step_row(oracle)
	expect_column_text(oracle, 0, "null")
	expect_column_text(oracle, 1, "text")
	expect_eq(i64(raw.column_int64(oracle, 2)), i64(0), "empty text byte length")
	expect_column_text(oracle, 3, "blob")
	expect_eq(i64(raw.column_int64(oracle, 4)), i64(0), "empty blob length")
	expect_column_text(oracle, 5, "610062")
	expect_column_text(oracle, 6, "100020")
	expect_eq(i64(raw.column_int64(oracle, 7)), i64(1024 * 1024), "large blob SQL length")
	step_done(oracle)
}

// SQLITE-FEATURE-CONTRACT: engine.values.numeric-boundaries-conversions.v1
// Feature: 64-bit integer boundaries and documented numeric conversion behavior.
// SQLite source: input/sqlite3.h section "Result Values From A Query" and https://sqlite.org/lang_expr.html#castexpr.
// Requirement: sqlite3_bind_int64 and sqlite3_column_int64 preserve the full signed 64-bit range; INTEGER-to-REAL conversion follows IEEE-754 precision, and CAST clamps overflowing integer text to the signed limits.
// Adversarial cases: Minimum and maximum i64, 2^53+1, fractional REAL, positive and negative decimal overflow strings, and nonnumeric text, all supplied through bound parameters.
// Oracle: A distinct SELECT reports exact SQLite storage classes and values through column_int64/column_double, while a separate CAST statement verifies documented clamping and zero conversion.
// Guardrail: Do not narrow through host int, compare formatted decimal strings, or change expected clamping/precision to match wrapper conversion behavior.
test_numeric_boundaries_and_conversion :: proc() {
	db := open_db(":memory:")
	defer close_db(&db)
	exec_ok(db, "CREATE TABLE numeric_probe(minimum, maximum, beyond_exact_double, fraction)")

	insert := prepare_ok(db, "INSERT INTO numeric_probe VALUES(?1, ?2, ?3, ?4)")
	bind_i64_ok(insert, 1, min(i64))
	bind_i64_ok(insert, 2, max(i64))
	bind_i64_ok(insert, 3, 9007199254740993)
	bind_double_ok(insert, 4, 1.5)
	step_done(insert)
	finalize_ok(&insert)

	reader := prepare_ok(db, "SELECT minimum, maximum, beyond_exact_double, fraction, typeof(minimum), typeof(fraction) FROM numeric_probe")
	defer finalize_ok(&reader)
	step_row(reader)
	expect_eq(i64(raw.column_int64(reader, 0)), min(i64), "minimum signed integer")
	expect_eq(i64(raw.column_int64(reader, 1)), max(i64), "maximum signed integer")
	expect_eq(i64(raw.column_int64(reader, 2)), i64(9007199254740993), "integer beyond exact f64 range")
	expect_eq(raw.column_double(reader, 2), f64(9007199254740992), "documented INTEGER to REAL precision")
	expect_eq(raw.column_double(reader, 3), f64(1.5), "fractional double")
	expect_column_text(reader, 4, "integer")
	expect_column_text(reader, 5, "real")
	step_done(reader)

	cast_statement := prepare_ok(db, "SELECT CAST(?1 AS INTEGER), CAST(?2 AS INTEGER), CAST(?3 AS INTEGER)")
	bind_text_ok(cast_statement, 1, "9223372036854775808")
	bind_text_ok(cast_statement, 2, "-9223372036854775809")
	bind_text_ok(cast_statement, 3, "not-a-number")
	step_row(cast_statement)
	expect_eq(i64(raw.column_int64(cast_statement, 0)), max(i64), "positive overflow clamps to i64 max")
	expect_eq(i64(raw.column_int64(cast_statement, 1)), min(i64), "negative overflow clamps to i64 min")
	expect_eq(i64(raw.column_int64(cast_statement, 2)), i64(0), "nonnumeric text converts to zero")
	step_done(cast_statement)
	finalize_ok(&cast_statement)
}
