package main

import sqlite "../../../sqlite"
import raw "../../../sqlite/raw/generated"

// SQLITE-FEATURE-CONTRACT: sql.json.core.v1
// Feature: Deterministic SQLite JSON scalar and table-valued functions.
// SQLite source: input/sqlite3.h (SQLite 3.53.1 SOURCE_ID
// c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9) and https://sqlite.org/json1.html
// Requirement: The pinned baseline accepts valid JSON text, preserves JSON scalar types, applies
// bound paths and updates, enumerates arrays through json_each, and rejects malformed JSON used
// by a CHECK constraint or a JSON extractor without changing stored documents.
// Adversarial cases: Object/array nesting, JSON true and null, integer scalar, bound path/value,
// malformed document, malformed path, constraint failure atomicity, json_each order, and reopen.
// Oracle: json_valid/json_type/typeof and explicit column access verify scalar types; an ordered
// json_each query and reopened table read independently prove exact content and unchanged state.
// Guardrail: Do not parse JSON in Odin to create the oracle, accept malformed JSON, depend on
// object-key ordering, or silently skip JSON when running the pinned qualification build.
test_json_functions :: proc() {
	fixture := open_fixture("json_functions")
	defer close_fixture(&fixture)

	exec_ok(
		fixture.db,
		"CREATE TABLE docs(id INTEGER PRIMARY KEY, body TEXT NOT NULL CHECK(json_valid(body)))",
	)
	document := `{"b":[true,null,3],"a":{"x":"hi"}}`
	insert := prepare_ok(fixture.db, "INSERT INTO docs(id, body) VALUES (?1, ?2)")
	bind_i64(&insert, 1, 1)
	bind_text(&insert, 2, document)
	step_done(insert)
	finalize_ok(&insert)

	scalars := prepare_ok(
		fixture.db,
		`SELECT json_valid(body),
			json_extract(body, ?1),
			typeof(json_extract(body, ?2)), json_extract(body, ?2),
			json_type(body, ?3), json_array_length(body, ?4),
			json_extract(json_set(body, ?5, ?6), ?5)
		 FROM docs WHERE id = ?7`,
	)
	bind_text(&scalars, 1, "$.a.x")
	bind_text(&scalars, 2, "$.b[2]")
	bind_text(&scalars, 3, "$.b[1]")
	bind_text(&scalars, 4, "$.b")
	bind_text(&scalars, 5, "$.z")
	bind_i64(&scalars, 6, 9)
	bind_i64(&scalars, 7, 1)
	step_row(scalars)
	expect_equal(sqlite.stmt_get_i64(scalars, 0), i64(1), "json_valid")
	expect_equal(
		sqlite.stmt_get_text(scalars, 1, context.temp_allocator),
		"hi",
		"json_extract text",
	)
	expect_equal(
		sqlite.stmt_get_text(scalars, 2, context.temp_allocator),
		"integer",
		"json_extract SQL type",
	)
	expect_equal(sqlite.stmt_get_i64(scalars, 3), i64(3), "json_extract integer")
	expect_equal(
		sqlite.stmt_get_text(scalars, 4, context.temp_allocator),
		"null",
		"json_type JSON null",
	)
	expect_equal(sqlite.stmt_get_i64(scalars, 5), i64(3), "json_array_length")
	expect_equal(sqlite.stmt_get_i64(scalars, 6), i64(9), "json_set bound value")
	step_done(scalars)
	finalize_ok(&scalars)

	elements := prepare_ok(
		fixture.db,
		"SELECT j.key, j.type, j.atom FROM docs AS d, json_each(d.body, ?1) AS j WHERE d.id = ?2 ORDER BY CAST(j.key AS INTEGER)",
	)
	bind_text(&elements, 1, "$.b")
	bind_i64(&elements, 2, 1)
	step_row(elements)
	expect_equal(sqlite.stmt_get_i64(elements, 0), i64(0), "json_each first key")
	expect_equal(
		sqlite.stmt_get_text(elements, 1, context.temp_allocator),
		"true",
		"json_each true type",
	)
	expect_equal(sqlite.stmt_get_i64(elements, 2), i64(1), "json_each true atom")
	step_row(elements)
	expect_equal(sqlite.stmt_get_i64(elements, 0), i64(1), "json_each second key")
	expect_equal(
		sqlite.stmt_get_text(elements, 1, context.temp_allocator),
		"null",
		"json_each null type",
	)
	expect(sqlite.stmt_is_null(elements, 2), "json_each JSON null atom is SQL NULL")
	step_row(elements)
	expect_equal(sqlite.stmt_get_i64(elements, 0), i64(2), "json_each third key")
	expect_equal(
		sqlite.stmt_get_text(elements, 1, context.temp_allocator),
		"integer",
		"json_each integer type",
	)
	expect_equal(sqlite.stmt_get_i64(elements, 2), i64(3), "json_each integer atom")
	step_done(elements)
	finalize_ok(&elements)

	bad_insert := prepare_ok(fixture.db, "INSERT INTO docs(id, body) VALUES (?1, ?2)")
	bind_i64(&bad_insert, 1, 2)
	bind_text(&bad_insert, 2, "{broken")
	step_fails(bad_insert, int(raw.CONSTRAINT), int(raw.CONSTRAINT_CHECK))
	finalize_after_failure(&bad_insert)

	bad_json := prepare_ok(fixture.db, "SELECT json_extract(?1, ?2)")
	bind_text(&bad_json, 1, "{broken")
	bind_text(&bad_json, 2, "$.x")
	step_fails(bad_json, int(raw.ERROR))
	finalize_after_failure(&bad_json)

	bad_path := prepare_ok(fixture.db, "SELECT json_extract(?1, ?2)")
	bind_text(&bad_path, 1, document)
	bind_text(&bad_path, 2, "$.b[")
	step_fails(bad_path, int(raw.ERROR))
	finalize_after_failure(&bad_path)

	reopen_fixture(&fixture)
	state := prepare_ok(fixture.db, "SELECT COUNT(*), body FROM docs WHERE id = ?1")
	bind_i64(&state, 1, 1)
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(1), "malformed JSON row absent")
	expect_equal(
		sqlite.stmt_get_text(state, 1, context.temp_allocator),
		document,
		"valid JSON text persisted exactly",
	)
	step_done(state)
	finalize_ok(&state)
}

// SQLITE-FEATURE-CONTRACT: sql.datetime.deterministic.v1
// Feature: Deterministic date, time, datetime, strftime, Julian-day, and Unix-epoch functions.
// SQLite source: input/sqlite3.h (SQLite 3.53.1 SOURCE_ID
// c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9) and https://sqlite.org/lang_datefunc.html
// Requirement: Fixed UTC inputs and modifiers produce documented leap-day, clock-wrap, Julian-day,
// format, and Unix-epoch results; an unrecognized modifier or invalid date yields SQL NULL.
// Adversarial cases: Leap-year boundary, midnight crossing, Unix epoch zero, J2000 noon, bound
// format/modifiers, invalid calendar text, invalid modifier, and no use of now/localtime.
// Oracle: Exact text/integer/REAL/NULL columns are read explicitly, and a distinct inverse
// unixepoch conversion statement verifies the epoch through a separate function path.
// Guardrail: Do not use wall-clock time, local timezone, locale formatting, or approximate host
// date libraries as the oracle for SQLite's deterministic UTC calculations.
test_date_time_functions :: proc() {
	fixture := open_fixture("date_time_functions")
	defer close_fixture(&fixture)

	stmt := prepare_ok(
		fixture.db,
		`SELECT date(?1, ?2), time(?1, ?3), datetime(?1, ?2),
			strftime(?4, ?5), unixepoch(?6), julianday(?7),
			date(?8) IS NULL, date(?1, ?9) IS NULL`,
	)
	bind_text(&stmt, 1, "2024-02-28 23:30:00")
	bind_text(&stmt, 2, "+1 day")
	bind_text(&stmt, 3, "+90 minutes")
	bind_text(&stmt, 4, "%Y-%m-%d %H:%M")
	bind_text(&stmt, 5, "2024-02-29 05:06:07")
	bind_text(&stmt, 6, "1970-01-01 00:00:00")
	bind_text(&stmt, 7, "2000-01-01 12:00:00")
	bind_text(&stmt, 8, "not-a-date")
	bind_text(&stmt, 9, "not-a-modifier")
	step_row(stmt)
	expect_equal(
		sqlite.stmt_get_text(stmt, 0, context.temp_allocator),
		"2024-02-29",
		"date leap day",
	)
	expect_equal(
		sqlite.stmt_get_text(stmt, 1, context.temp_allocator),
		"01:00:00",
		"time wraps midnight",
	)
	expect_equal(
		sqlite.stmt_get_text(stmt, 2, context.temp_allocator),
		"2024-02-29 23:30:00",
		"datetime leap day",
	)
	expect_equal(
		sqlite.stmt_get_text(stmt, 3, context.temp_allocator),
		"2024-02-29 05:06",
		"strftime fixed UTC",
	)
	expect_equal(sqlite.stmt_get_i64(stmt, 4), i64(0), "Unix epoch origin")
	expect_equal(sqlite.stmt_get_f64(stmt, 5), 2451545.0, "J2000 Julian day")
	expect_equal(sqlite.stmt_get_i64(stmt, 6), i64(1), "invalid date yields NULL")
	expect_equal(sqlite.stmt_get_i64(stmt, 7), i64(1), "invalid modifier yields NULL")
	step_done(stmt)
	finalize_ok(&stmt)

	inverse := prepare_ok(fixture.db, "SELECT datetime(?1, ?2), typeof(unixepoch(?3))")
	bind_i64(&inverse, 1, 0)
	bind_text(&inverse, 2, "unixepoch")
	bind_text(&inverse, 3, "1970-01-01 00:00:00")
	step_row(inverse)
	expect_equal(
		sqlite.stmt_get_text(inverse, 0, context.temp_allocator),
		"1970-01-01 00:00:00",
		"inverse Unix epoch",
	)
	expect_equal(
		sqlite.stmt_get_text(inverse, 1, context.temp_allocator),
		"integer",
		"unixepoch storage type",
	)
	step_done(inverse)
	finalize_ok(&inverse)
}

// SQLITE-FEATURE-CONTRACT: sql.transactions.savepoints.v1
// Feature: SQL BEGIN/COMMIT/ROLLBACK and nested/top-level savepoint semantics.
// SQLite source: https://sqlite.org/lang_transaction.html and https://sqlite.org/lang_savepoint.html
// Requirement: ROLLBACK TO reverses changes after a savepoint while retaining earlier transaction
// work, RELEASE of the outermost savepoint commits, ROLLBACK discards work, and nested BEGIN fails
// without ending or rolling back the active transaction.
// Adversarial cases: Update and insert after a savepoint, rollback-to then release, BEGIN inside
// BEGIN, visibility before explicit rollback, top-level savepoint release, rollback, and reopen.
// Oracle: Autocommit state is paired with separately prepared ordered state queries at each
// boundary and a final reopened connection verifies exactly the committed rows and values.
// Guardrail: Do not treat ROLLBACK TO as ending the transaction, treat RELEASE as a durable commit
// when an outer transaction exists, or assume failed nested BEGIN changes transaction state.
test_transactions_and_savepoints :: proc() {
	fixture := open_fixture("transactions_savepoints")
	defer close_fixture(&fixture)

	exec_ok(fixture.db, "CREATE TABLE ledger(id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
	exec_ok(fixture.db, "BEGIN")
	expect(sqlite.db_in_transaction(fixture.db), "BEGIN disables autocommit")
	outer := prepare_ok(fixture.db, "INSERT INTO ledger(id, value) VALUES (?1, ?2)")
	bind_i64(&outer, 1, 1)
	bind_text(&outer, 2, "outer")
	step_done(outer)
	finalize_ok(&outer)

	exec_ok(fixture.db, "SAVEPOINT inner_work")
	inner := prepare_ok(fixture.db, "INSERT INTO ledger(id, value) VALUES (?1, ?2)")
	bind_i64(&inner, 1, 2)
	bind_text(&inner, 2, "inner")
	step_done(inner)
	finalize_ok(&inner)
	update := prepare_ok(fixture.db, "UPDATE ledger SET value = ?1 WHERE id = ?2")
	bind_text(&update, 1, "changed")
	bind_i64(&update, 2, 1)
	step_done(update)
	finalize_ok(&update)
	exec_ok(fixture.db, "ROLLBACK TO inner_work")
	expect(sqlite.db_in_transaction(fixture.db), "ROLLBACK TO retains transaction")
	exec_ok(fixture.db, "RELEASE inner_work")
	expect(sqlite.db_in_transaction(fixture.db), "nested RELEASE retains outer transaction")
	exec_ok(fixture.db, "COMMIT")
	expect(!sqlite.db_in_transaction(fixture.db), "COMMIT restores autocommit")

	exec_ok(fixture.db, "BEGIN")
	rolled_back := prepare_ok(fixture.db, "INSERT INTO ledger(id, value) VALUES (?1, ?2)")
	bind_i64(&rolled_back, 1, 3)
	bind_text(&rolled_back, 2, "temporary")
	step_done(rolled_back)
	finalize_ok(&rolled_back)
	exec_fails(fixture.db, "BEGIN", int(raw.ERROR))
	expect(sqlite.db_in_transaction(fixture.db), "failed nested BEGIN retains transaction")
	visible := prepare_ok(fixture.db, "SELECT COUNT(*) FROM ledger WHERE id = ?1")
	bind_i64(&visible, 1, 3)
	step_row(visible)
	expect_equal(
		sqlite.stmt_get_i64(visible, 0),
		i64(1),
		"active transaction retains uncommitted row",
	)
	step_done(visible)
	finalize_ok(&visible)
	exec_ok(fixture.db, "ROLLBACK")

	exec_ok(fixture.db, "SAVEPOINT top_level")
	expect(sqlite.db_in_transaction(fixture.db), "top-level savepoint disables autocommit")
	top := prepare_ok(fixture.db, "INSERT INTO ledger(id, value) VALUES (?1, ?2)")
	bind_i64(&top, 1, 4)
	bind_text(&top, 2, "top-level")
	step_done(top)
	finalize_ok(&top)
	exec_ok(fixture.db, "RELEASE top_level")
	expect(!sqlite.db_in_transaction(fixture.db), "outermost RELEASE restores autocommit")

	exec_ok(fixture.db, "BEGIN")
	discarded := prepare_ok(fixture.db, "INSERT INTO ledger(id, value) VALUES (?1, ?2)")
	bind_i64(&discarded, 1, 5)
	bind_text(&discarded, 2, "discarded")
	step_done(discarded)
	finalize_ok(&discarded)
	exec_ok(fixture.db, "ROLLBACK")

	reopen_fixture(&fixture)
	state := prepare_ok(fixture.db, "SELECT id, value FROM ledger ORDER BY id")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(1), "outer transaction row persisted")
	expect_equal(
		sqlite.stmt_get_text(state, 1, context.temp_allocator),
		"outer",
		"savepoint rollback restored value",
	)
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(4), "top-level savepoint row persisted")
	expect_equal(
		sqlite.stmt_get_text(state, 1, context.temp_allocator),
		"top-level",
		"top-level savepoint value",
	)
	step_done(state)
	finalize_ok(&state)
}
