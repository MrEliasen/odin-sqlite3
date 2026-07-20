package main

import sqlite "../../../sqlite"
import raw "../../../sqlite/raw/generated"

// SQLITE-FEATURE-CONTRACT: sql.ddl.indexes.v1
// Feature: Ordinary, UNIQUE, partial, and expression indexes in SQLite schemas.
// SQLite source: https://sqlite.org/lang_createindex.html and https://sqlite.org/partialindex.html
// Requirement: CREATE INDEX persists each supported index definition, UNIQUE indexes reject
// duplicate non-NULL keys atomically, and index expressions may use only deterministic functions.
// Adversarial cases: Bound duplicate key, duplicate index name, non-deterministic random()
// expression, partial predicate, expression index, close/reopen, and unchanged table state.
// Oracle: Result codes are paired with ordered sqlite_schema inspection and a separate row-count
// query after reopen; the persisted SQL text identifies partial and expression definitions.
// Guardrail: Do not infer index support from prepare success or query-plan choices, and do not
// accept a duplicate row or a non-deterministic expression because a particular build allows it.
test_ddl_indexes :: proc() {
	fixture := open_fixture("ddl_indexes")
	defer close_fixture(&fixture)

	exec_ok(
		fixture.db,
		"CREATE TABLE items(id INTEGER PRIMARY KEY, sku TEXT NOT NULL, name TEXT NOT NULL, active INTEGER NOT NULL CHECK(active IN (0, 1)))",
	)
	exec_ok(fixture.db, "CREATE UNIQUE INDEX idx_items_sku_unique ON items(sku)")
	exec_ok(fixture.db, "CREATE INDEX idx_items_active_name ON items(name) WHERE active = 1")
	exec_ok(fixture.db, "CREATE INDEX idx_items_lower_name ON items(lower(name))")

	insert := prepare_ok(
		fixture.db,
		"INSERT INTO items(id, sku, name, active) VALUES (?1, ?2, ?3, ?4)",
	)
	bind_i64(&insert, 1, 1)
	bind_text(&insert, 2, "sku-a")
	bind_text(&insert, 3, "Alpha")
	bind_i64(&insert, 4, 1)
	step_done(insert)
	reuse(&insert)
	bind_i64(&insert, 1, 2)
	bind_text(&insert, 2, "sku-b")
	bind_text(&insert, 3, "Beta")
	bind_i64(&insert, 4, 0)
	step_done(insert)
	finalize_ok(&insert)

	duplicate := prepare_ok(
		fixture.db,
		"INSERT INTO items(id, sku, name, active) VALUES (?1, ?2, ?3, ?4)",
	)
	bind_i64(&duplicate, 1, 3)
	bind_text(&duplicate, 2, "sku-a")
	bind_text(&duplicate, 3, "Duplicate")
	bind_i64(&duplicate, 4, 1)
	step_fails(duplicate, int(raw.CONSTRAINT), int(raw.CONSTRAINT_UNIQUE))
	finalize_after_failure(&duplicate)

	exec_fails(fixture.db, "CREATE INDEX idx_items_lower_name ON items(name)", int(raw.ERROR))
	exec_fails(fixture.db, "CREATE INDEX idx_items_random ON items(random())", int(raw.ERROR))

	reopen_fixture(&fixture)
	schema := prepare_ok(
		fixture.db,
		"SELECT name, sql FROM sqlite_schema WHERE type = 'index' AND name IN (?1, ?2, ?3) ORDER BY name",
	)
	bind_text(&schema, 1, "idx_items_sku_unique")
	bind_text(&schema, 2, "idx_items_active_name")
	bind_text(&schema, 3, "idx_items_lower_name")
	step_row(schema)
	expect_equal(
		sqlite.stmt_get_text(schema, 0, context.temp_allocator),
		"idx_items_active_name",
		"partial index name",
	)
	expect_contains(
		sqlite.stmt_get_text(schema, 1, context.temp_allocator),
		"WHERE active = 1",
		"partial index SQL",
	)
	step_row(schema)
	expect_equal(
		sqlite.stmt_get_text(schema, 0, context.temp_allocator),
		"idx_items_lower_name",
		"expression index name",
	)
	expect_contains(
		sqlite.stmt_get_text(schema, 1, context.temp_allocator),
		"lower(name)",
		"expression index SQL",
	)
	step_row(schema)
	expect_equal(
		sqlite.stmt_get_text(schema, 0, context.temp_allocator),
		"idx_items_sku_unique",
		"unique index name",
	)
	expect_contains(
		sqlite.stmt_get_text(schema, 1, context.temp_allocator),
		"UNIQUE INDEX",
		"unique index SQL",
	)
	step_done(schema)
	finalize_ok(&schema)

	state := prepare_ok(fixture.db, "SELECT COUNT(*), COUNT(DISTINCT sku) FROM items")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(2), "duplicate insert leaves two rows")
	expect_equal(sqlite.stmt_get_i64(state, 1), i64(2), "duplicate insert leaves unique keys")
	step_done(state)
	finalize_ok(&state)

	missing := prepare_ok(fixture.db, "SELECT COUNT(*) FROM sqlite_schema WHERE name = ?1")
	bind_text(&missing, 1, "idx_items_random")
	step_row(missing)
	expect_equal(sqlite.stmt_get_i64(missing, 0), i64(0), "invalid index must not persist")
	step_done(missing)
	finalize_ok(&missing)
}

// SQLITE-FEATURE-CONTRACT: sql.ddl.views-triggers-generated.v1
// Feature: Views, row triggers, and stored generated columns.
// SQLite source: https://sqlite.org/lang_createview.html, https://sqlite.org/lang_createtrigger.html,
// and https://sqlite.org/gencol.html
// Requirement: Generated values derive from their row, AFTER triggers observe those values,
// views expose the derived state, trigger RAISE(ABORT) cancels a row, and generated columns and
// read-only views cannot be directly inserted into without an applicable INSTEAD OF trigger.
// Adversarial cases: Bound nominal row, trigger-rejected negative quantity, direct generated-column
// write, direct view write, audit side effects, failure atomicity, and close/reopen persistence.
// Oracle: Separate statements read the base table, view, audit table, and sqlite_schema after the
// failures and again after reopen; primary and extended constraint codes identify trigger abort.
// Guardrail: Do not calculate generated or trigger results in Odin, ignore side effects, or weaken
// rejected writes into success merely because a wrapper chooses a different prepare path.
test_ddl_views_triggers_generated_columns :: proc() {
	fixture := open_fixture("ddl_views_triggers_generated")
	defer close_fixture(&fixture)

	exec_ok(
		fixture.db,
		"CREATE TABLE orders(id INTEGER PRIMARY KEY, qty INTEGER NOT NULL, price INTEGER NOT NULL, total INTEGER GENERATED ALWAYS AS (qty * price) STORED)",
	)
	exec_ok(
		fixture.db,
		"CREATE TABLE audit(order_id INTEGER NOT NULL, observed_total INTEGER NOT NULL)",
	)
	exec_ok(
		fixture.db,
		"CREATE VIEW expensive_orders AS SELECT id, total FROM orders WHERE total >= 20",
	)
	exec_ok(
		fixture.db,
		"CREATE TRIGGER reject_negative_qty BEFORE INSERT ON orders WHEN NEW.qty < 0 BEGIN SELECT RAISE(ABORT, 'negative quantity'); END",
	)
	exec_ok(
		fixture.db,
		"CREATE TRIGGER audit_order AFTER INSERT ON orders BEGIN INSERT INTO audit(order_id, observed_total) VALUES (NEW.id, NEW.total); END",
	)

	insert := prepare_ok(fixture.db, "INSERT INTO orders(id, qty, price) VALUES (?1, ?2, ?3)")
	bind_i64(&insert, 1, 1)
	bind_i64(&insert, 2, 4)
	bind_i64(&insert, 3, 6)
	step_done(insert)
	finalize_ok(&insert)

	rejected := prepare_ok(fixture.db, "INSERT INTO orders(id, qty, price) VALUES (?1, ?2, ?3)")
	bind_i64(&rejected, 1, 2)
	bind_i64(&rejected, 2, -1)
	bind_i64(&rejected, 3, 100)
	step_fails(rejected, int(raw.CONSTRAINT), int(raw.CONSTRAINT_TRIGGER))
	finalize_after_failure(&rejected)

	prepare_fails(
		fixture.db,
		"INSERT INTO orders(id, qty, price, total) VALUES (?1, ?2, ?3, ?4)",
		int(raw.ERROR),
	)
	prepare_fails(
		fixture.db,
		"INSERT INTO expensive_orders(id, total) VALUES (?1, ?2)",
		int(raw.ERROR),
	)

	base := prepare_ok(fixture.db, "SELECT qty, price, total FROM orders WHERE id = ?1")
	bind_i64(&base, 1, 1)
	step_row(base)
	expect_equal(sqlite.stmt_get_i64(base, 0), i64(4), "stored quantity")
	expect_equal(sqlite.stmt_get_i64(base, 1), i64(6), "stored price")
	expect_equal(sqlite.stmt_get_i64(base, 2), i64(24), "stored generated total")
	step_done(base)
	finalize_ok(&base)

	view_read := prepare_ok(fixture.db, "SELECT id, total FROM expensive_orders ORDER BY id")
	step_row(view_read)
	expect_equal(sqlite.stmt_get_i64(view_read, 0), i64(1), "view row id")
	expect_equal(sqlite.stmt_get_i64(view_read, 1), i64(24), "view generated total")
	step_done(view_read)
	finalize_ok(&view_read)

	audit_read := prepare_ok(
		fixture.db,
		"SELECT order_id, observed_total FROM audit ORDER BY order_id",
	)
	step_row(audit_read)
	expect_equal(sqlite.stmt_get_i64(audit_read, 0), i64(1), "audit order id")
	expect_equal(sqlite.stmt_get_i64(audit_read, 1), i64(24), "trigger observes generated value")
	step_done(audit_read)
	finalize_ok(&audit_read)

	reopen_fixture(&fixture)
	persisted := prepare_ok(
		fixture.db,
		"SELECT (SELECT COUNT(*) FROM orders), (SELECT COUNT(*) FROM audit), (SELECT total FROM expensive_orders WHERE id = ?1)",
	)
	bind_i64(&persisted, 1, 1)
	step_row(persisted)
	expect_equal(sqlite.stmt_get_i64(persisted, 0), i64(1), "trigger rejection leaves one order")
	expect_equal(
		sqlite.stmt_get_i64(persisted, 1),
		i64(1),
		"trigger rejection leaves one audit row",
	)
	expect_equal(sqlite.stmt_get_i64(persisted, 2), i64(24), "view persists across reopen")
	step_done(persisted)
	finalize_ok(&persisted)
}

// SQLITE-FEATURE-CONTRACT: sql.ddl.strict-without-rowid.v1
// Feature: STRICT tables, the ANY datatype, and WITHOUT ROWID tables.
// SQLite source: https://sqlite.org/stricttables.html and https://sqlite.org/withoutrowid.html
// Requirement: STRICT columns reject values that cannot be losslessly converted, STRICT ANY
// preserves the original storage class, and WITHOUT ROWID tables enforce a non-NULL composite
// primary key while exposing no rowid pseudo-column.
// Adversarial cases: Maximum i64, numeric-looking text in ANY, incompatible TEXT for INTEGER,
// duplicate and NULL composite keys, invalid STRICT datatype, rowid lookup, and reopen.
// Oracle: Exact constraint codes and prepare failures are paired with separately prepared typed
// reads and persisted row counts after close/reopen.
// Guardrail: Do not coerce STRICT ANY like an ordinary column, synthesize a rowid, or accept
// invalid STRICT writes/types based on permissive behavior of non-STRICT tables.
test_ddl_strict_without_rowid :: proc() {
	fixture := open_fixture("ddl_strict_without_rowid")
	defer close_fixture(&fixture)

	exec_ok(
		fixture.db,
		"CREATE TABLE strict_values(key TEXT PRIMARY KEY, n INTEGER NOT NULL, raw ANY) STRICT",
	)
	exec_ok(
		fixture.db,
		"CREATE TABLE keyed(a TEXT, b INTEGER, payload TEXT, PRIMARY KEY(a, b)) WITHOUT ROWID",
	)
	exec_fails(fixture.db, "CREATE TABLE invalid_strict(x VARCHAR) STRICT", int(raw.ERROR))

	strict_insert := prepare_ok(
		fixture.db,
		"INSERT INTO strict_values(key, n, raw) VALUES (?1, ?2, ?3)",
	)
	bind_text(&strict_insert, 1, "alpha")
	bind_i64(&strict_insert, 2, max(i64))
	bind_text(&strict_insert, 3, "000123")
	step_done(strict_insert)
	finalize_ok(&strict_insert)

	strict_bad := prepare_ok(
		fixture.db,
		"INSERT INTO strict_values(key, n, raw) VALUES (?1, ?2, ?3)",
	)
	bind_text(&strict_bad, 1, "bad")
	bind_text(&strict_bad, 2, "not-an-integer")
	bind_null(&strict_bad, 3)
	step_fails(strict_bad, int(raw.CONSTRAINT), int(raw.CONSTRAINT_DATATYPE))
	finalize_after_failure(&strict_bad)

	keyed_insert := prepare_ok(fixture.db, "INSERT INTO keyed(a, b, payload) VALUES (?1, ?2, ?3)")
	bind_text(&keyed_insert, 1, "a")
	bind_i64(&keyed_insert, 2, 1)
	bind_text(&keyed_insert, 3, "")
	step_done(keyed_insert)
	finalize_ok(&keyed_insert)

	duplicate := prepare_ok(fixture.db, "INSERT INTO keyed(a, b, payload) VALUES (?1, ?2, ?3)")
	bind_text(&duplicate, 1, "a")
	bind_i64(&duplicate, 2, 1)
	bind_text(&duplicate, 3, "duplicate")
	step_fails(duplicate, int(raw.CONSTRAINT), int(raw.CONSTRAINT_PRIMARYKEY))
	finalize_after_failure(&duplicate)

	null_key := prepare_ok(fixture.db, "INSERT INTO keyed(a, b, payload) VALUES (?1, ?2, ?3)")
	bind_null(&null_key, 1)
	bind_i64(&null_key, 2, 2)
	bind_text(&null_key, 3, "null key")
	step_fails(null_key, int(raw.CONSTRAINT), int(raw.CONSTRAINT_NOTNULL))
	finalize_after_failure(&null_key)

	prepare_fails(fixture.db, "SELECT rowid FROM keyed", int(raw.ERROR))
	reopen_fixture(&fixture)

	strict_read := prepare_ok(
		fixture.db,
		"SELECT n, typeof(raw), raw FROM strict_values WHERE key = ?1",
	)
	bind_text(&strict_read, 1, "alpha")
	step_row(strict_read)
	expect_equal(sqlite.stmt_get_i64(strict_read, 0), max(i64), "STRICT maximum i64")
	expect_equal(
		sqlite.stmt_get_text(strict_read, 1, context.temp_allocator),
		"text",
		"STRICT ANY storage class",
	)
	expect_equal(
		sqlite.stmt_get_text(strict_read, 2, context.temp_allocator),
		"000123",
		"STRICT ANY exact text",
	)
	step_done(strict_read)
	finalize_ok(&strict_read)

	state := prepare_ok(
		fixture.db,
		"SELECT (SELECT COUNT(*) FROM strict_values), (SELECT COUNT(*) FROM keyed), (SELECT COUNT(*) FROM sqlite_schema WHERE name = ?1)",
	)
	bind_text(&state, 1, "invalid_strict")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(1), "STRICT rejected row is absent")
	expect_equal(sqlite.stmt_get_i64(state, 1), i64(1), "WITHOUT ROWID rejected rows are absent")
	expect_equal(sqlite.stmt_get_i64(state, 2), i64(0), "invalid STRICT table is absent")
	step_done(state)
	finalize_ok(&state)
}
