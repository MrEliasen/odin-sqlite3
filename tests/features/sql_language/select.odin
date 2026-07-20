package main

import sqlite "../../../sqlite"
import raw "../../../sqlite/raw/generated"

// SQLITE-FEATURE-CONTRACT: sql.select.joins-subqueries.v1
// Feature: INNER/LEFT joins, correlated subqueries, EXISTS, IN, and scalar NULL semantics.
// SQLite source: https://sqlite.org/lang_select.html and https://sqlite.org/lang_expr.html#in_op
// Requirement: INNER JOIN returns only matches, LEFT JOIN retains unmatched left rows with NULL
// right columns, correlated EXISTS evaluates per outer row, and IN returns NULL when no match is
// found but the right-hand set contains NULL.
// Adversarial cases: One-to-many matches, unmatched rows on both sides, NULL join key, NULL scalar,
// bound correlation threshold, IN with a NULL member, and an ambiguous-column prepare failure.
// Oracle: Multiple independently prepared SELECTs use explicit ORDER BY or aggregates and inspect
// NULL/type state; a final count confirms invalid read SQL did not alter durable data.
// Guardrail: Do not rely on insertion order, collapse an unmatched LEFT JOIN row, or turn UNKNOWN
// from IN into host false merely because both are falsey in application code.
test_select_joins_and_subqueries :: proc() {
	fixture := open_fixture("select_joins_subqueries")
	defer close_fixture(&fixture)

	exec_ok(fixture.db, "CREATE TABLE authors(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(
		fixture.db,
		"CREATE TABLE books(id INTEGER PRIMARY KEY, author_id INTEGER, price INTEGER)",
	)

	author_insert := prepare_ok(fixture.db, "INSERT INTO authors(id, name) VALUES (?1, ?2)")
	author_rows := []struct {
		id:   i64,
		name: string,
	}{{1, "Ada"}, {2, "Bob"}, {3, "Cy"}}
	for row in author_rows {
		if row.id != 1 {
			reuse(&author_insert)
		}
		bind_i64(&author_insert, 1, row.id)
		bind_text(&author_insert, 2, row.name)
		step_done(author_insert)
	}
	finalize_ok(&author_insert)

	book_insert := prepare_ok(
		fixture.db,
		"INSERT INTO books(id, author_id, price) VALUES (?1, ?2, ?3)",
	)
	bind_i64(&book_insert, 1, 10)
	bind_i64(&book_insert, 2, 1)
	bind_i64(&book_insert, 3, 10)
	step_done(book_insert)
	reuse(&book_insert)
	bind_i64(&book_insert, 1, 11)
	bind_i64(&book_insert, 2, 1)
	bind_null(&book_insert, 3)
	step_done(book_insert)
	reuse(&book_insert)
	bind_i64(&book_insert, 1, 12)
	bind_i64(&book_insert, 2, 2)
	bind_i64(&book_insert, 3, 20)
	step_done(book_insert)
	reuse(&book_insert)
	bind_i64(&book_insert, 1, 13)
	bind_null(&book_insert, 2)
	bind_i64(&book_insert, 3, 99)
	step_done(book_insert)
	finalize_ok(&book_insert)

	inner := prepare_ok(
		fixture.db,
		"SELECT a.id, b.id FROM authors AS a INNER JOIN books AS b ON b.author_id = a.id ORDER BY a.id, b.id",
	)
	inner_rows := []struct {
		author_id, book_id: i64,
	}{{1, 10}, {1, 11}, {2, 12}}
	for expected in inner_rows {
		step_row(inner)
		expect_equal(sqlite.stmt_get_i64(inner, 0), expected.author_id, "INNER JOIN author")
		expect_equal(sqlite.stmt_get_i64(inner, 1), expected.book_id, "INNER JOIN book")
	}
	step_done(inner)
	finalize_ok(&inner)

	left := prepare_ok(
		fixture.db,
		"SELECT a.id, COUNT(b.id), SUM(b.price) FROM authors AS a LEFT JOIN books AS b ON b.author_id = a.id GROUP BY a.id ORDER BY a.id",
	)
	step_row(left)
	expect_equal(sqlite.stmt_get_i64(left, 0), i64(1), "LEFT JOIN first author")
	expect_equal(sqlite.stmt_get_i64(left, 1), i64(2), "LEFT JOIN one-to-many count")
	expect_equal(sqlite.stmt_get_i64(left, 2), i64(10), "aggregate ignores NULL price")
	step_row(left)
	expect_equal(sqlite.stmt_get_i64(left, 0), i64(2), "LEFT JOIN second author")
	expect_equal(sqlite.stmt_get_i64(left, 1), i64(1), "LEFT JOIN single match")
	step_row(left)
	expect_equal(sqlite.stmt_get_i64(left, 0), i64(3), "LEFT JOIN unmatched author")
	expect_equal(sqlite.stmt_get_i64(left, 1), i64(0), "LEFT JOIN unmatched count")
	expect(sqlite.stmt_is_null(left, 2), "SUM over unmatched group is NULL")
	step_done(left)
	finalize_ok(&left)

	exists_query := prepare_ok(
		fixture.db,
		"SELECT a.id FROM authors AS a WHERE EXISTS (SELECT 1 FROM books AS b WHERE b.author_id = a.id AND b.price > ?1) ORDER BY a.id",
	)
	bind_i64(&exists_query, 1, 15)
	step_row(exists_query)
	expect_equal(sqlite.stmt_get_i64(exists_query, 0), i64(2), "correlated EXISTS match")
	step_done(exists_query)
	finalize_ok(&exists_query)

	in_query := prepare_ok(
		fixture.db,
		"SELECT (?1 IN (SELECT author_id FROM books WHERE id >= ?2)) IS NULL, EXISTS (SELECT 1 FROM books WHERE author_id = ?1)",
	)
	bind_i64(&in_query, 1, 99)
	bind_i64(&in_query, 2, 10)
	step_row(in_query)
	expect_equal(sqlite.stmt_get_i64(in_query, 0), i64(1), "IN with NULL member yields NULL")
	expect_equal(sqlite.stmt_get_i64(in_query, 1), i64(0), "EXISTS without match is false")
	step_done(in_query)
	finalize_ok(&in_query)

	prepare_fails(
		fixture.db,
		"SELECT id FROM authors JOIN books ON books.author_id = authors.id",
		int(raw.ERROR),
	)
	state := prepare_ok(fixture.db, "SELECT COUNT(*) FROM books")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(4), "invalid SELECT leaves table unchanged")
	step_done(state)
	finalize_ok(&state)
}

// SQLITE-FEATURE-CONTRACT: sql.select.aggregates-compounds.v1
// Feature: DISTINCT, GROUP BY, HAVING, aggregates, and compound SELECT operators.
// SQLite source: https://sqlite.org/lang_select.html and https://sqlite.org/lang_aggfunc.html
// Requirement: Aggregate NULL handling, DISTINCT elimination, group filtering, UNION duplicate
// removal, UNION ALL retention, INTERSECT membership, and EXCEPT subtraction follow SQL semantics.
// Adversarial cases: Duplicate values, all-NULL group, COUNT(*) versus COUNT(expr), bound HAVING
// threshold, duplicate compound arms, unequal EXCEPT arms, and aggregate misuse in WHERE.
// Oracle: Every result with multiple rows has explicit ORDER BY; a distinct grouped query requires
// the all-NULL group to have zero non-NULL values and NULL aggregates before compound/state checks.
// Guardrail: Do not count NULL in COUNT(expr), invent a value for an all-NULL aggregate, or rely on
// unspecified compound output order or host-side deduplication.
test_select_aggregates_and_compounds :: proc() {
	fixture := open_fixture("select_aggregates_compounds")
	defer close_fixture(&fixture)

	exec_ok(
		fixture.db,
		"CREATE TABLE measurements(id INTEGER PRIMARY KEY, grp TEXT NOT NULL, value INTEGER)",
	)
	insert := prepare_ok(
		fixture.db,
		"INSERT INTO measurements(id, grp, value) VALUES (?1, ?2, ?3)",
	)
	rows := []struct {
		id:      i64,
		grp:     string,
		value:   i64,
		is_null: bool,
	} {
		{1, "a", 1, false},
		{2, "a", 1, false},
		{3, "a", 0, true},
		{4, "b", 2, false},
		{5, "b", 3, false},
		{6, "c", 0, true},
	}
	for row, index in rows {
		if index > 0 {
			reuse(&insert)
		}
		bind_i64(&insert, 1, row.id)
		bind_text(&insert, 2, row.grp)
		if row.is_null {
			bind_null(&insert, 3)
		} else {
			bind_i64(&insert, 3, row.value)
		}
		step_done(insert)
	}
	finalize_ok(&insert)

	groups := prepare_ok(
		fixture.db,
		"SELECT grp, COUNT(*), COUNT(value), COUNT(DISTINCT value), SUM(value), AVG(value), MIN(value), MAX(value) FROM measurements GROUP BY grp HAVING COUNT(value) >= ?1 ORDER BY grp",
	)
	bind_i64(&groups, 1, 1)
	step_row(groups)
	expect_equal(sqlite.stmt_get_text(groups, 0, context.temp_allocator), "a", "first group")
	expect_equal(sqlite.stmt_get_i64(groups, 1), i64(3), "a COUNT star")
	expect_equal(sqlite.stmt_get_i64(groups, 2), i64(2), "a COUNT value")
	expect_equal(sqlite.stmt_get_i64(groups, 3), i64(1), "a COUNT DISTINCT")
	expect_equal(sqlite.stmt_get_i64(groups, 4), i64(2), "a SUM")
	expect_equal(sqlite.stmt_get_f64(groups, 5), 1.0, "a AVG")
	expect_equal(sqlite.stmt_get_i64(groups, 6), i64(1), "a MIN")
	expect_equal(sqlite.stmt_get_i64(groups, 7), i64(1), "a MAX")
	step_row(groups)
	expect_equal(sqlite.stmt_get_text(groups, 0, context.temp_allocator), "b", "second group")
	expect_equal(sqlite.stmt_get_i64(groups, 1), i64(2), "b COUNT star")
	expect_equal(sqlite.stmt_get_i64(groups, 4), i64(5), "b SUM")
	expect_equal(sqlite.stmt_get_f64(groups, 5), 2.5, "b AVG")
	step_done(groups)
	finalize_ok(&groups)

	all_null_group := prepare_ok(
		fixture.db,
		"SELECT grp, COUNT(value), SUM(value), AVG(value), MIN(value), MAX(value) FROM measurements GROUP BY grp HAVING COUNT(value) = ?1 ORDER BY grp",
	)
	bind_i64(&all_null_group, 1, 0)
	step_row(all_null_group)
	expect_equal(
		sqlite.stmt_get_text(all_null_group, 0, context.temp_allocator),
		"c",
		"all-NULL group",
	)
	expect_equal(sqlite.stmt_get_i64(all_null_group, 1), i64(0), "all-NULL COUNT value")
	expect(sqlite.stmt_is_null(all_null_group, 2), "all-NULL SUM is SQL NULL")
	expect(sqlite.stmt_is_null(all_null_group, 3), "all-NULL AVG is SQL NULL")
	expect(sqlite.stmt_is_null(all_null_group, 4), "all-NULL MIN is SQL NULL")
	expect(sqlite.stmt_is_null(all_null_group, 5), "all-NULL MAX is SQL NULL")
	step_done(all_null_group)
	finalize_ok(&all_null_group)

	distinct_groups := prepare_ok(fixture.db, "SELECT DISTINCT grp FROM measurements ORDER BY grp")
	expected_groups := []string{"a", "b", "c"}
	for expected in expected_groups {
		step_row(distinct_groups)
		expect_equal(
			sqlite.stmt_get_text(distinct_groups, 0, context.temp_allocator),
			expected,
			"DISTINCT group",
		)
	}
	step_done(distinct_groups)
	finalize_ok(&distinct_groups)

	union_query := prepare_ok(
		fixture.db,
		"SELECT ?1 AS value UNION SELECT ?2 UNION SELECT ?3 ORDER BY value",
	)
	bind_i64(&union_query, 1, 2)
	bind_i64(&union_query, 2, 1)
	bind_i64(&union_query, 3, 2)
	expected_union := []i64{1, 2}
	for expected in expected_union {
		step_row(union_query)
		expect_equal(sqlite.stmt_get_i64(union_query, 0), expected, "UNION value")
	}
	step_done(union_query)
	finalize_ok(&union_query)

	union_all := prepare_ok(
		fixture.db,
		"SELECT ?1 AS value UNION ALL SELECT ?2 UNION ALL SELECT ?3 ORDER BY value",
	)
	bind_i64(&union_all, 1, 2)
	bind_i64(&union_all, 2, 1)
	bind_i64(&union_all, 3, 2)
	expected_union_all := []i64{1, 2, 2}
	for expected in expected_union_all {
		step_row(union_all)
		expect_equal(sqlite.stmt_get_i64(union_all, 0), expected, "UNION ALL value")
	}
	step_done(union_all)
	finalize_ok(&union_all)

	intersect_query := prepare_ok(fixture.db, "SELECT ?1 AS value INTERSECT SELECT ?2")
	bind_text(&intersect_query, 1, "same")
	bind_text(&intersect_query, 2, "same")
	step_row(intersect_query)
	expect_equal(
		sqlite.stmt_get_text(intersect_query, 0, context.temp_allocator),
		"same",
		"INTERSECT common row",
	)
	step_done(intersect_query)
	finalize_ok(&intersect_query)

	except_query := prepare_ok(fixture.db, "SELECT ?1 AS value EXCEPT SELECT ?2")
	bind_text(&except_query, 1, "left")
	bind_text(&except_query, 2, "right")
	step_row(except_query)
	expect_equal(
		sqlite.stmt_get_text(except_query, 0, context.temp_allocator),
		"left",
		"EXCEPT remaining row",
	)
	step_done(except_query)
	finalize_ok(&except_query)

	prepare_fails(
		fixture.db,
		"SELECT SUM(value) FROM measurements WHERE SUM(value) > ?1",
		int(raw.ERROR),
	)
	state := prepare_ok(fixture.db, "SELECT COUNT(*) FROM measurements")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(6), "invalid aggregate leaves rows unchanged")
	step_done(state)
	finalize_ok(&state)
}

// SQLITE-FEATURE-CONTRACT: sql.select.order-limit.v1
// Feature: Deterministic ORDER BY tie-breaking, NULL placement, LIMIT, and OFFSET.
// SQLite source: https://sqlite.org/lang_select.html#orderby and https://sqlite.org/lang_select.html#limitoffset
// Requirement: Explicit sort terms determine row order including NULLS LAST and ties; positive
// LIMIT/OFFSET selects the documented slice, and negative LIMIT removes the upper bound.
// Adversarial cases: Equal sort keys, NULL key, zero-based offset, negative LIMIT, bound limits,
// non-integer LIMIT runtime failure, and persistence before reading.
// Oracle: After reopen, explicit ordered queries enumerate exact ids; the invalid bound LIMIT is
// required to return SQLITE_MISMATCH and a distinct statement confirms row count is unchanged.
// Guardrail: Do not infer row order from rowid or insertion, omit a tie-breaker, clamp negative
// LIMIT in host code, or accept a non-integral LIMIT conversion.
test_select_ordering_and_limits :: proc() {
	fixture := open_fixture("select_ordering_limits")
	defer close_fixture(&fixture)

	exec_ok(
		fixture.db,
		"CREATE TABLE ranked(id INTEGER PRIMARY KEY, label TEXT NOT NULL, score INTEGER)",
	)
	insert := prepare_ok(fixture.db, "INSERT INTO ranked(id, label, score) VALUES (?1, ?2, ?3)")
	rows := []struct {
		id:      i64,
		label:   string,
		score:   i64,
		is_null: bool,
	} {
		{1, "ten", 10, false},
		{2, "null", 0, true},
		{3, "twenty-a", 20, false},
		{4, "twenty-b", 20, false},
		{5, "five", 5, false},
	}
	for row, index in rows {
		if index > 0 {
			reuse(&insert)
		}
		bind_i64(&insert, 1, row.id)
		bind_text(&insert, 2, row.label)
		if row.is_null {
			bind_null(&insert, 3)
		} else {
			bind_i64(&insert, 3, row.score)
		}
		step_done(insert)
	}
	finalize_ok(&insert)
	reopen_fixture(&fixture)

	page := prepare_ok(
		fixture.db,
		"SELECT id FROM ranked ORDER BY score DESC NULLS LAST, id ASC LIMIT ?1 OFFSET ?2",
	)
	bind_i64(&page, 1, 3)
	bind_i64(&page, 2, 1)
	expected_page := []i64{4, 1, 5}
	for expected in expected_page {
		step_row(page)
		expect_equal(sqlite.stmt_get_i64(page, 0), expected, "limited ordered id")
	}
	step_done(page)
	finalize_ok(&page)

	unbounded := prepare_ok(
		fixture.db,
		"SELECT id FROM ranked ORDER BY score DESC NULLS LAST, id ASC LIMIT ?1 OFFSET ?2",
	)
	bind_i64(&unbounded, 1, -1)
	bind_i64(&unbounded, 2, 3)
	expected_unbounded := []i64{5, 2}
	for expected in expected_unbounded {
		step_row(unbounded)
		expect_equal(sqlite.stmt_get_i64(unbounded, 0), expected, "negative-LIMIT ordered id")
	}
	step_done(unbounded)
	finalize_ok(&unbounded)

	bad_limit := prepare_ok(fixture.db, "SELECT id FROM ranked ORDER BY id LIMIT ?1")
	bind_text(&bad_limit, 1, "not-an-integer")
	step_fails(bad_limit, int(raw.MISMATCH))
	finalize_after_failure(&bad_limit)

	state := prepare_ok(fixture.db, "SELECT COUNT(*) FROM ranked")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(5), "invalid LIMIT leaves rows unchanged")
	step_done(state)
	finalize_ok(&state)
}

// SQLITE-FEATURE-CONTRACT: sql.select.cte-windows.v1
// Feature: Ordinary and recursive CTEs plus partitioned window functions and frames.
// SQLite source: https://sqlite.org/lang_with.html and https://sqlite.org/windowfunctions.html
// Requirement: Ordinary CTEs feed their enclosing query, recursive CTEs iterate to their bound
// termination condition, and ROW_NUMBER, RANK, and framed SUM operate in partition/window order.
// Adversarial cases: Duplicate peer scores, two partitions, explicit peer tie-breaker, cumulative
// ROWS frame, bound recursion start/step/limit, and illegal multiple recursive references.
// Oracle: Separate ordered statements enumerate the recursive sequence and every window column;
// prepare failure for the invalid CTE is followed by an independent persisted row count.
// Guardrail: Do not calculate ranks in host code, confuse peer rank with row number, rely on output
// order from a window ORDER BY alone, or allow a recursive term with multiple self-references.
test_select_ctes_and_windows :: proc() {
	fixture := open_fixture("select_ctes_windows")
	defer close_fixture(&fixture)

	exec_ok(
		fixture.db,
		"CREATE TABLE events(id INTEGER PRIMARY KEY, grp TEXT NOT NULL, score INTEGER NOT NULL)",
	)
	insert := prepare_ok(fixture.db, "INSERT INTO events(id, grp, score) VALUES (?1, ?2, ?3)")
	event_rows := []struct {
		id:    i64,
		grp:   string,
		score: i64,
	}{{1, "a", 10}, {2, "a", 20}, {3, "a", 20}, {4, "b", 5}, {5, "b", 7}}
	for row, index in event_rows {
		if index > 0 {
			reuse(&insert)
		}
		bind_i64(&insert, 1, row.id)
		bind_text(&insert, 2, row.grp)
		bind_i64(&insert, 3, row.score)
		step_done(insert)
	}
	finalize_ok(&insert)

	ordinary := prepare_ok(
		fixture.db,
		"WITH filtered AS (SELECT score FROM events WHERE score >= ?1) SELECT COUNT(*), SUM(score) FROM filtered",
	)
	bind_i64(&ordinary, 1, 10)
	step_row(ordinary)
	expect_equal(sqlite.stmt_get_i64(ordinary, 0), i64(3), "ordinary CTE count")
	expect_equal(sqlite.stmt_get_i64(ordinary, 1), i64(50), "ordinary CTE sum")
	step_done(ordinary)
	finalize_ok(&ordinary)

	recursive := prepare_ok(
		fixture.db,
		"WITH RECURSIVE seq(n) AS (VALUES(?1) UNION ALL SELECT n + ?2 FROM seq WHERE n < ?3) SELECT n FROM seq ORDER BY n",
	)
	bind_i64(&recursive, 1, 1)
	bind_i64(&recursive, 2, 1)
	bind_i64(&recursive, 3, 5)
	expected_sequence := []i64{1, 2, 3, 4, 5}
	for expected in expected_sequence {
		step_row(recursive)
		expect_equal(sqlite.stmt_get_i64(recursive, 0), expected, "recursive CTE value")
	}
	step_done(recursive)
	finalize_ok(&recursive)

	windows := prepare_ok(
		fixture.db,
		`SELECT grp, id, score,
			row_number() OVER (PARTITION BY grp ORDER BY score DESC, id),
			rank() OVER (PARTITION BY grp ORDER BY score DESC),
			sum(score) OVER (PARTITION BY grp ORDER BY score DESC, id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
		 FROM events ORDER BY grp, score DESC, id`,
	)
	expected_rows := []struct {
		grp:                                  string,
		id, score, row_number, rank, running: i64,
	} {
		{"a", 2, 20, 1, 1, 20},
		{"a", 3, 20, 2, 1, 40},
		{"a", 1, 10, 3, 3, 50},
		{"b", 5, 7, 1, 1, 7},
		{"b", 4, 5, 2, 2, 12},
	}
	for expected in expected_rows {
		step_row(windows)
		expect_equal(
			sqlite.stmt_get_text(windows, 0, context.temp_allocator),
			expected.grp,
			"window partition",
		)
		expect_equal(sqlite.stmt_get_i64(windows, 1), expected.id, "window id")
		expect_equal(sqlite.stmt_get_i64(windows, 2), expected.score, "window score")
		expect_equal(sqlite.stmt_get_i64(windows, 3), expected.row_number, "ROW_NUMBER")
		expect_equal(sqlite.stmt_get_i64(windows, 4), expected.rank, "RANK")
		expect_equal(sqlite.stmt_get_i64(windows, 5), expected.running, "framed running SUM")
	}
	step_done(windows)
	finalize_ok(&windows)

	prepare_fails(
		fixture.db,
		"WITH RECURSIVE bad(n) AS (VALUES(?1) UNION ALL SELECT a.n + b.n FROM bad AS a, bad AS b) SELECT n FROM bad",
		int(raw.ERROR),
	)
	state := prepare_ok(fixture.db, "SELECT COUNT(*) FROM events")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(5), "invalid CTE leaves rows unchanged")
	step_done(state)
	finalize_ok(&state)
}
