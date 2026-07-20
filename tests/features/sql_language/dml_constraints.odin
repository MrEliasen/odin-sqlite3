package main

import sqlite "../../../sqlite"
import raw "../../../sqlite/raw/generated"

// SQLITE-FEATURE-CONTRACT: sql.dml.returning-atomicity.v1
// Feature: INSERT, UPDATE, DELETE, RETURNING, and statement failure atomicity.
// SQLite source: https://sqlite.org/lang_insert.html, https://sqlite.org/lang_update.html,
// https://sqlite.org/lang_delete.html, and https://sqlite.org/lang_returning.html
// Requirement: Each DML form applies bound values and RETURNING exposes the affected row; an
// ABORT constraint failure rolls back every change made by that statement while earlier commits
// remain intact, and DELETE removes only its matched row.
// Adversarial cases: Insert/update/delete RETURNING, zero-row ambiguity avoided by exact keys,
// multi-row CHECK failure after another candidate row, bound negative value, and reopen.
// Oracle: RETURNING rows are consumed explicitly, then distinct ordered SELECTs and a reopened
// connection verify both successful mutations and all-or-nothing failure state.
// Guardrail: Do not assume a RETURNING row order for multi-row statements, accept partial UPDATE
// effects after ABORT, or use the RETURNING values themselves as the sole persistence oracle.
test_dml_returning_and_atomicity :: proc() {
	fixture := open_fixture("dml_returning_atomicity")
	defer close_fixture(&fixture)

	exec_ok(
		fixture.db,
		"CREATE TABLE inventory(id INTEGER PRIMARY KEY, sku TEXT NOT NULL UNIQUE, qty INTEGER NOT NULL CHECK(qty >= 0))",
	)

	insert := prepare_ok(
		fixture.db,
		"INSERT INTO inventory(id, sku, qty) VALUES (?1, ?2, ?3) RETURNING id, typeof(qty), qty",
	)
	bind_i64(&insert, 1, 1)
	bind_text(&insert, 2, "widget")
	bind_i64(&insert, 3, 5)
	step_row(insert)
	expect_equal(sqlite.stmt_get_i64(insert, 0), i64(1), "INSERT RETURNING id")
	expect_equal(
		sqlite.stmt_get_text(insert, 1, context.temp_allocator),
		"integer",
		"INSERT RETURNING type",
	)
	expect_equal(sqlite.stmt_get_i64(insert, 2), i64(5), "INSERT RETURNING quantity")
	step_done(insert)
	finalize_ok(&insert)

	second := prepare_ok(fixture.db, "INSERT INTO inventory(id, sku, qty) VALUES (?1, ?2, ?3)")
	bind_i64(&second, 1, 2)
	bind_text(&second, 2, "gadget")
	bind_i64(&second, 3, 4)
	step_done(second)
	finalize_ok(&second)

	update := prepare_ok(
		fixture.db,
		"UPDATE inventory SET qty = qty + ?1 WHERE id = ?2 RETURNING id, qty",
	)
	bind_i64(&update, 1, 3)
	bind_i64(&update, 2, 1)
	step_row(update)
	expect_equal(sqlite.stmt_get_i64(update, 0), i64(1), "UPDATE RETURNING id")
	expect_equal(sqlite.stmt_get_i64(update, 1), i64(8), "UPDATE RETURNING new quantity")
	step_done(update)
	finalize_ok(&update)

	failing_update := prepare_ok(
		fixture.db,
		"UPDATE inventory SET qty = CASE WHEN id = ?1 THEN ?2 ELSE qty + ?3 END RETURNING id, qty",
	)
	bind_i64(&failing_update, 1, 2)
	bind_i64(&failing_update, 2, -1)
	bind_i64(&failing_update, 3, 100)
	step_fails(failing_update, int(raw.CONSTRAINT), int(raw.CONSTRAINT_CHECK))
	finalize_after_failure(&failing_update)

	unchanged := prepare_ok(fixture.db, "SELECT id, qty FROM inventory ORDER BY id")
	step_row(unchanged)
	expect_equal(sqlite.stmt_get_i64(unchanged, 0), i64(1), "first unchanged id")
	expect_equal(sqlite.stmt_get_i64(unchanged, 1), i64(8), "first unchanged quantity")
	step_row(unchanged)
	expect_equal(sqlite.stmt_get_i64(unchanged, 0), i64(2), "second unchanged id")
	expect_equal(sqlite.stmt_get_i64(unchanged, 1), i64(4), "second unchanged quantity")
	step_done(unchanged)
	finalize_ok(&unchanged)

	delete_stmt := prepare_ok(fixture.db, "DELETE FROM inventory WHERE id = ?1 RETURNING id, sku")
	bind_i64(&delete_stmt, 1, 2)
	step_row(delete_stmt)
	expect_equal(sqlite.stmt_get_i64(delete_stmt, 0), i64(2), "DELETE RETURNING id")
	expect_equal(
		sqlite.stmt_get_text(delete_stmt, 1, context.temp_allocator),
		"gadget",
		"DELETE RETURNING sku",
	)
	step_done(delete_stmt)
	finalize_ok(&delete_stmt)

	reopen_fixture(&fixture)
	state := prepare_ok(fixture.db, "SELECT id, sku, qty FROM inventory ORDER BY id")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(1), "persisted id")
	expect_equal(sqlite.stmt_get_text(state, 1, context.temp_allocator), "widget", "persisted sku")
	expect_equal(sqlite.stmt_get_i64(state, 2), i64(8), "persisted quantity")
	step_done(state)
	finalize_ok(&state)
}

// SQLITE-FEATURE-CONTRACT: sql.dml.conflict-upsert.v1
// Feature: SQLite conflict algorithms and UPSERT clauses.
// SQLite source: https://sqlite.org/lang_conflict.html and https://sqlite.org/lang_upsert.html
// Requirement: ABORT reverses prior row changes from the failing statement, FAIL preserves prior
// row changes from that statement, IGNORE skips only conflicting rows, REPLACE substitutes the
// conflicting row, and UPSERT DO UPDATE/DO NOTHING follow their named conflict target.
// Adversarial cases: A later bound tuple conflicts after earlier tuples, NULL-free UNIQUE key,
// each major conflict algorithm, UPSERT RETURNING, DO NOTHING with no returned row, and reopen.
// Oracle: Exact UNIQUE extended codes distinguish failures; separately prepared ordered reads
// inspect which keys and payloads persist after every algorithm and after close/reopen.
// Guardrail: Do not normalize ABORT and FAIL into identical atomicity, count a skipped UPSERT as
// an inserted row, or derive expected state from wrapper change counters.
test_dml_conflicts_and_upsert :: proc() {
	fixture := open_fixture("dml_conflicts_upsert")
	defer close_fixture(&fixture)

	exec_ok(fixture.db, "CREATE TABLE keys(k INTEGER UNIQUE, payload TEXT)")
	seed := prepare_ok(fixture.db, "INSERT INTO keys(k, payload) VALUES (?1, ?2)")
	bind_i64(&seed, 1, 9)
	bind_text(&seed, 2, "seed")
	step_done(seed)
	finalize_ok(&seed)

	abort_stmt := prepare_ok(
		fixture.db,
		"INSERT OR ABORT INTO keys(k, payload) VALUES (?1, ?2), (?3, ?4), (?5, ?6)",
	)
	bind_i64(&abort_stmt, 1, 1)
	bind_text(&abort_stmt, 2, "one")
	bind_i64(&abort_stmt, 3, 2)
	bind_text(&abort_stmt, 4, "two")
	bind_i64(&abort_stmt, 5, 9)
	bind_text(&abort_stmt, 6, "duplicate")
	step_fails(abort_stmt, int(raw.CONSTRAINT), int(raw.CONSTRAINT_UNIQUE))
	finalize_after_failure(&abort_stmt)

	fail_stmt := prepare_ok(
		fixture.db,
		"INSERT OR FAIL INTO keys(k, payload) VALUES (?1, ?2), (?3, ?4), (?5, ?6)",
	)
	bind_i64(&fail_stmt, 1, 3)
	bind_text(&fail_stmt, 2, "three")
	bind_i64(&fail_stmt, 3, 4)
	bind_text(&fail_stmt, 4, "four")
	bind_i64(&fail_stmt, 5, 9)
	bind_text(&fail_stmt, 6, "duplicate")
	step_fails(fail_stmt, int(raw.CONSTRAINT), int(raw.CONSTRAINT_UNIQUE))
	finalize_after_failure(&fail_stmt)

	ignore_stmt := prepare_ok(
		fixture.db,
		"INSERT OR IGNORE INTO keys(k, payload) VALUES (?1, ?2), (?3, ?4)",
	)
	bind_i64(&ignore_stmt, 1, 5)
	bind_text(&ignore_stmt, 2, "five")
	bind_i64(&ignore_stmt, 3, 9)
	bind_text(&ignore_stmt, 4, "ignored")
	step_done(ignore_stmt)
	finalize_ok(&ignore_stmt)

	replace_stmt := prepare_ok(
		fixture.db,
		"INSERT OR REPLACE INTO keys(k, payload) VALUES (?1, ?2)",
	)
	bind_i64(&replace_stmt, 1, 9)
	bind_text(&replace_stmt, 2, "replaced")
	step_done(replace_stmt)
	finalize_ok(&replace_stmt)

	upsert := prepare_ok(
		fixture.db,
		"INSERT INTO keys(k, payload) VALUES (?1, ?2) ON CONFLICT(k) DO UPDATE SET payload = excluded.payload || ?3 RETURNING payload",
	)
	bind_i64(&upsert, 1, 9)
	bind_text(&upsert, 2, "up")
	bind_text(&upsert, 3, "-dated")
	step_row(upsert)
	expect_equal(
		sqlite.stmt_get_text(upsert, 0, context.temp_allocator),
		"up-dated",
		"UPSERT RETURNING payload",
	)
	step_done(upsert)
	finalize_ok(&upsert)

	do_nothing := prepare_ok(
		fixture.db,
		"INSERT INTO keys(k, payload) VALUES (?1, ?2) ON CONFLICT(k) DO NOTHING RETURNING k",
	)
	bind_i64(&do_nothing, 1, 9)
	bind_text(&do_nothing, 2, "not-stored")
	step_done(do_nothing)
	finalize_ok(&do_nothing)

	reopen_fixture(&fixture)
	state := prepare_ok(fixture.db, "SELECT k, payload FROM keys ORDER BY k")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(3), "FAIL preserves first key")
	expect_equal(
		sqlite.stmt_get_text(state, 1, context.temp_allocator),
		"three",
		"FAIL preserves first payload",
	)
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(4), "FAIL preserves second key")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(5), "IGNORE inserts non-conflicting key")
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(9), "conflict target key")
	expect_equal(
		sqlite.stmt_get_text(state, 1, context.temp_allocator),
		"up-dated",
		"UPSERT final payload",
	)
	step_done(state)
	finalize_ok(&state)

	absent := prepare_ok(fixture.db, "SELECT COUNT(*) FROM keys WHERE k IN (?1, ?2)")
	bind_i64(&absent, 1, 1)
	bind_i64(&absent, 2, 2)
	step_row(absent)
	expect_equal(sqlite.stmt_get_i64(absent, 0), i64(0), "ABORT removes earlier tuple effects")
	step_done(absent)
	finalize_ok(&absent)
}

// SQLITE-FEATURE-CONTRACT: sql.constraints.core.v1
// Feature: PRIMARY KEY, UNIQUE, NOT NULL, and CHECK constraints including NULL uniqueness.
// SQLite source: https://sqlite.org/lang_createtable.html#constraints and input/sqlite3.h
// Requirement: Each violated constraint rejects its bound row with SQLITE_CONSTRAINT and the
// documented extended code, while multiple NULLs are permitted by UNIQUE and prior rows remain.
// Adversarial cases: Duplicate integer primary key, duplicate non-NULL unique text, bound NULL
// into NOT NULL, CHECK boundary below zero, two UNIQUE NULLs, and close/reopen state validation.
// Oracle: Exact primary and extended result codes are paired with a separately prepared aggregate
// query proving rejected rows are absent and both NULL-key rows persist.
// Guardrail: Do not compare diagnostic sentences, treat NULLs as equal for UNIQUE, or permit a
// partial failed row because another column value was valid.
test_constraints_core :: proc() {
	fixture := open_fixture("constraints_core")
	defer close_fixture(&fixture)

	exec_ok(
		fixture.db,
		"CREATE TABLE entities(id INTEGER PRIMARY KEY, code TEXT UNIQUE, required TEXT NOT NULL, score INTEGER CHECK(score BETWEEN 0 AND 10))",
	)

	base := prepare_ok(
		fixture.db,
		"INSERT INTO entities(id, code, required, score) VALUES (?1, ?2, ?3, ?4)",
	)
	bind_i64(&base, 1, 1)
	bind_text(&base, 2, "A")
	bind_text(&base, 3, "present")
	bind_i64(&base, 4, 0)
	step_done(base)
	finalize_ok(&base)

	primary := prepare_ok(
		fixture.db,
		"INSERT INTO entities(id, code, required, score) VALUES (?1, ?2, ?3, ?4)",
	)
	bind_i64(&primary, 1, 1)
	bind_text(&primary, 2, "B")
	bind_text(&primary, 3, "present")
	bind_i64(&primary, 4, 10)
	step_fails(primary, int(raw.CONSTRAINT), int(raw.CONSTRAINT_PRIMARYKEY))
	finalize_after_failure(&primary)

	unique := prepare_ok(
		fixture.db,
		"INSERT INTO entities(id, code, required, score) VALUES (?1, ?2, ?3, ?4)",
	)
	bind_i64(&unique, 1, 2)
	bind_text(&unique, 2, "A")
	bind_text(&unique, 3, "present")
	bind_i64(&unique, 4, 10)
	step_fails(unique, int(raw.CONSTRAINT), int(raw.CONSTRAINT_UNIQUE))
	finalize_after_failure(&unique)

	not_null := prepare_ok(
		fixture.db,
		"INSERT INTO entities(id, code, required, score) VALUES (?1, ?2, ?3, ?4)",
	)
	bind_i64(&not_null, 1, 3)
	bind_text(&not_null, 2, "C")
	bind_null(&not_null, 3)
	bind_i64(&not_null, 4, 10)
	step_fails(not_null, int(raw.CONSTRAINT), int(raw.CONSTRAINT_NOTNULL))
	finalize_after_failure(&not_null)

	check_stmt := prepare_ok(
		fixture.db,
		"INSERT INTO entities(id, code, required, score) VALUES (?1, ?2, ?3, ?4)",
	)
	bind_i64(&check_stmt, 1, 4)
	bind_text(&check_stmt, 2, "D")
	bind_text(&check_stmt, 3, "present")
	bind_i64(&check_stmt, 4, -1)
	step_fails(check_stmt, int(raw.CONSTRAINT), int(raw.CONSTRAINT_CHECK))
	finalize_after_failure(&check_stmt)

	null_unique := prepare_ok(
		fixture.db,
		"INSERT INTO entities(id, code, required, score) VALUES (?1, ?2, ?3, ?4)",
	)
	for id in 5 ..= 6 {
		if id != 5 {
			reuse(&null_unique)
		}
		bind_i64(&null_unique, 1, i64(id))
		bind_null(&null_unique, 2)
		bind_text(&null_unique, 3, "present")
		bind_i64(&null_unique, 4, 10)
		step_done(null_unique)
	}
	finalize_ok(&null_unique)

	reopen_fixture(&fixture)
	state := prepare_ok(
		fixture.db,
		"SELECT COUNT(*), SUM(code IS NULL), MIN(score), MAX(score), (SELECT required FROM entities WHERE id = ?1) FROM entities",
	)
	bind_i64(&state, 1, 1)
	step_row(state)
	expect_equal(sqlite.stmt_get_i64(state, 0), i64(3), "only accepted rows persist")
	expect_equal(sqlite.stmt_get_i64(state, 1), i64(2), "UNIQUE allows multiple NULLs")
	expect_equal(sqlite.stmt_get_i64(state, 2), i64(0), "CHECK lower boundary accepted")
	expect_equal(sqlite.stmt_get_i64(state, 3), i64(10), "CHECK upper boundary accepted")
	expect_equal(
		sqlite.stmt_get_text(state, 4, context.temp_allocator),
		"present",
		"original row unchanged",
	)
	step_done(state)
	finalize_ok(&state)
}

// SQLITE-FEATURE-CONTRACT: sql.constraints.foreign-key-actions.v1
// Feature: Immediate foreign keys with NULL, CASCADE, and RESTRICT actions.
// SQLite source: https://sqlite.org/foreignkeys.html and https://sqlite.org/lang_createtable.html
// Requirement: With foreign_keys enabled, missing parents fail immediately, NULL child keys are
// allowed, ON UPDATE CASCADE propagates keys, ON DELETE RESTRICT blocks deletion before changes,
// and ON DELETE CASCADE removes dependent rows once restrictors are gone.
// Adversarial cases: Bound missing parent, nullable child key, simultaneous cascading and
// restricting children, failed-delete atomicity, subsequent valid delete, and reopen.
// Oracle: The orphan uses SQLITE_CONSTRAINT_FOREIGNKEY and RESTRICT uses the documented primary
// SQLITE_CONSTRAINT; separate queries check state before/after deletion and after close/reopen.
// Guardrail: Do not assume foreign keys are enabled by default, weaken RESTRICT into deferred
// cleanup, or accept orphaned rows after a documented cascade.
test_foreign_key_actions :: proc() {
	fixture := open_fixture("foreign_key_actions")
	defer close_fixture(&fixture)

	exec_ok(fixture.db, "PRAGMA foreign_keys = ON")
	exec_ok(fixture.db, "CREATE TABLE parents(id INTEGER PRIMARY KEY)")
	exec_ok(
		fixture.db,
		"CREATE TABLE cascade_children(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id) ON UPDATE CASCADE ON DELETE CASCADE)",
	)
	exec_ok(
		fixture.db,
		"CREATE TABLE restrict_children(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id) ON UPDATE CASCADE ON DELETE RESTRICT)",
	)
	exec_ok(
		fixture.db,
		"CREATE TABLE optional_children(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id))",
	)

	parent := prepare_ok(fixture.db, "INSERT INTO parents(id) VALUES (?1)")
	bind_i64(&parent, 1, 1)
	step_done(parent)
	finalize_ok(&parent)

	child_rows := []struct {
		sql: string,
		id:  i64,
	} {
		{"INSERT INTO cascade_children(id, parent_id) VALUES (?1, ?2)", 10},
		{"INSERT INTO restrict_children(id, parent_id) VALUES (?1, ?2)", 20},
	}
	for row in child_rows {
		child := prepare_ok(fixture.db, row.sql)
		bind_i64(&child, 1, row.id)
		bind_i64(&child, 2, 1)
		step_done(child)
		finalize_ok(&child)
	}

	optional := prepare_ok(
		fixture.db,
		"INSERT INTO optional_children(id, parent_id) VALUES (?1, ?2)",
	)
	bind_i64(&optional, 1, 30)
	bind_null(&optional, 2)
	step_done(optional)
	finalize_ok(&optional)

	orphan := prepare_ok(fixture.db, "INSERT INTO cascade_children(id, parent_id) VALUES (?1, ?2)")
	bind_i64(&orphan, 1, 11)
	bind_i64(&orphan, 2, 999)
	step_fails(orphan, int(raw.CONSTRAINT), int(raw.CONSTRAINT_FOREIGNKEY))
	finalize_after_failure(&orphan)

	update_parent := prepare_ok(fixture.db, "UPDATE parents SET id = ?1 WHERE id = ?2")
	bind_i64(&update_parent, 1, 2)
	bind_i64(&update_parent, 2, 1)
	step_done(update_parent)
	finalize_ok(&update_parent)

	blocked_delete := prepare_ok(fixture.db, "DELETE FROM parents WHERE id = ?1")
	bind_i64(&blocked_delete, 1, 2)
	step_fails(blocked_delete, int(raw.CONSTRAINT))
	finalize_after_failure(&blocked_delete)

	blocked_state := prepare_ok(
		fixture.db,
		"SELECT (SELECT COUNT(*) FROM parents WHERE id = ?1), (SELECT parent_id FROM cascade_children WHERE id = ?2), (SELECT parent_id FROM restrict_children WHERE id = ?3)",
	)
	bind_i64(&blocked_state, 1, 2)
	bind_i64(&blocked_state, 2, 10)
	bind_i64(&blocked_state, 3, 20)
	step_row(blocked_state)
	expect_equal(sqlite.stmt_get_i64(blocked_state, 0), i64(1), "RESTRICT preserves parent")
	expect_equal(sqlite.stmt_get_i64(blocked_state, 1), i64(2), "CASCADE update propagated")
	expect_equal(sqlite.stmt_get_i64(blocked_state, 2), i64(2), "RESTRICT child update propagated")
	step_done(blocked_state)
	finalize_ok(&blocked_state)

	remove_restrictor := prepare_ok(fixture.db, "DELETE FROM restrict_children WHERE id = ?1")
	bind_i64(&remove_restrictor, 1, 20)
	step_done(remove_restrictor)
	finalize_ok(&remove_restrictor)
	delete_parent := prepare_ok(fixture.db, "DELETE FROM parents WHERE id = ?1")
	bind_i64(&delete_parent, 1, 2)
	step_done(delete_parent)
	finalize_ok(&delete_parent)

	reopen_fixture(&fixture)
	exec_ok(fixture.db, "PRAGMA foreign_keys = ON")
	final_state := prepare_ok(
		fixture.db,
		"SELECT (SELECT COUNT(*) FROM parents), (SELECT COUNT(*) FROM cascade_children), (SELECT COUNT(*) FROM restrict_children), (SELECT COUNT(*) FROM optional_children WHERE parent_id IS NULL)",
	)
	step_row(final_state)
	expect_equal(sqlite.stmt_get_i64(final_state, 0), i64(0), "parent deleted")
	expect_equal(sqlite.stmt_get_i64(final_state, 1), i64(0), "cascade child deleted")
	expect_equal(sqlite.stmt_get_i64(final_state, 2), i64(0), "restrict child explicitly deleted")
	expect_equal(sqlite.stmt_get_i64(final_state, 3), i64(1), "NULL foreign key remains valid")
	step_done(final_state)
	finalize_ok(&final_state)
}

// SQLITE-FEATURE-CONTRACT: sql.constraints.foreign-key-deferred.v1
// Feature: DEFERRABLE INITIALLY DEFERRED foreign-key enforcement at COMMIT.
// SQLite source: https://sqlite.org/foreignkeys.html#fk_deferred
// Requirement: A deferred violation may exist inside a transaction and be repaired before COMMIT;
// an unrepaired violation makes COMMIT fail while leaving the transaction active for rollback.
// Adversarial cases: Child-before-parent insertion, successful repair, unrepaired bound parent key,
// failed COMMIT transaction state, explicit rollback, and durable-state verification after reopen.
// Oracle: Transaction state and SQLITE_CONSTRAINT_FOREIGNKEY are checked at the failing COMMIT,
// then distinct statements before and after rollback and after reopen identify visible rows.
// Guardrail: Do not enforce an INITIALLY DEFERRED key at INSERT time, silently commit an orphan,
// or assume a failed COMMIT automatically rolls the transaction back.
test_deferred_foreign_keys :: proc() {
	fixture := open_fixture("deferred_foreign_keys")
	defer close_fixture(&fixture)

	exec_ok(fixture.db, "PRAGMA foreign_keys = ON")
	exec_ok(fixture.db, "CREATE TABLE deferred_parents(id INTEGER PRIMARY KEY)")
	exec_ok(
		fixture.db,
		"CREATE TABLE deferred_children(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES deferred_parents(id) DEFERRABLE INITIALLY DEFERRED)",
	)

	exec_ok(fixture.db, "BEGIN")
	child := prepare_ok(fixture.db, "INSERT INTO deferred_children(id, parent_id) VALUES (?1, ?2)")
	bind_i64(&child, 1, 1)
	bind_i64(&child, 2, 10)
	step_done(child)
	finalize_ok(&child)
	parent := prepare_ok(fixture.db, "INSERT INTO deferred_parents(id) VALUES (?1)")
	bind_i64(&parent, 1, 10)
	step_done(parent)
	finalize_ok(&parent)
	exec_ok(fixture.db, "COMMIT")

	exec_ok(fixture.db, "BEGIN")
	orphan := prepare_ok(
		fixture.db,
		"INSERT INTO deferred_children(id, parent_id) VALUES (?1, ?2)",
	)
	bind_i64(&orphan, 1, 2)
	bind_i64(&orphan, 2, 20)
	step_done(orphan)
	finalize_ok(&orphan)

	commit_error, commit_ok := sqlite.db_exec(fixture.db, "COMMIT")
	defer sqlite.error_destroy(&commit_error)
	expect(!commit_ok, "COMMIT with a deferred orphan must fail")
	expect_equal(commit_error.code, int(raw.CONSTRAINT), "deferred COMMIT primary code")
	expect_equal(
		commit_error.extended_code,
		int(raw.CONSTRAINT_FOREIGNKEY),
		"deferred COMMIT extended code",
	)
	expect(
		sqlite.db_in_transaction(fixture.db),
		"failed deferred COMMIT must leave transaction active",
	)

	inside := prepare_ok(fixture.db, "SELECT COUNT(*) FROM deferred_children WHERE parent_id = ?1")
	bind_i64(&inside, 1, 20)
	step_row(inside)
	expect_equal(sqlite.stmt_get_i64(inside, 0), i64(1), "orphan remains visible before rollback")
	step_done(inside)
	finalize_ok(&inside)
	exec_ok(fixture.db, "ROLLBACK")
	expect(!sqlite.db_in_transaction(fixture.db), "ROLLBACK restores autocommit")

	after := prepare_ok(fixture.db, "SELECT COUNT(*) FROM deferred_children WHERE parent_id = ?1")
	bind_i64(&after, 1, 20)
	step_row(after)
	expect_equal(sqlite.stmt_get_i64(after, 0), i64(0), "rollback removes deferred orphan")
	step_done(after)
	finalize_ok(&after)

	reopen_fixture(&fixture)
	exec_ok(fixture.db, "PRAGMA foreign_keys = ON")
	persisted := prepare_ok(
		fixture.db,
		"SELECT (SELECT COUNT(*) FROM deferred_parents WHERE id = ?1), (SELECT COUNT(*) FROM deferred_children WHERE parent_id = ?1)",
	)
	bind_i64(&persisted, 1, 10)
	step_row(persisted)
	expect_equal(sqlite.stmt_get_i64(persisted, 0), i64(1), "repaired parent persisted")
	expect_equal(sqlite.stmt_get_i64(persisted, 1), i64(1), "repaired child persisted")
	step_done(persisted)
	finalize_ok(&persisted)
}
