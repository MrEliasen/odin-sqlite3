package main
import "core:mem"

import "core:fmt"
import sqlite "../../../../sqlite"

print_user :: proc(db: sqlite.DB, id: i64, label: string) {
	stmt, err, ok := sqlite.stmt_prepare(
		db,
		"SELECT id, name, email, active FROM users WHERE id = ?1",
	)
	if !ok {
		fmt.println("prepare select failed:", sqlite.error_string(err))
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	err, ok = sqlite.stmt_bind_i64(&stmt, 1, id)
	if !ok {
		fmt.println("bind select id failed:", sqlite.error_string(err))
		return
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println("step select failed:", sqlite.error_string(step_err))
		return
	}
	if !has_row {
		fmt.printf("%s user id=%d not found\n", label, id)
		return
	}

	fmt.printf(
		"%s id=%d name=%q email=%q active=%v\n",
		label,
		sqlite.stmt_get_i64(stmt, 0),
		sqlite.stmt_get_text(stmt, 1, context.temp_allocator),
		sqlite.stmt_get_text(stmt, 2, context.temp_allocator),
		sqlite.stmt_get_bool(stmt, 3),
	)
}

main :: proc() {
	tracking_allocator: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking_allocator, context.allocator)
	context.allocator = mem.tracking_allocator(&tracking_allocator)
	defer {
		if len(tracking_allocator.allocation_map) > 0 {
			fmt.eprintf("=== %v allocations not freed: ===\n", len(tracking_allocator.allocation_map))
			for _, entry in tracking_allocator.allocation_map {
				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}
		}
		if len(tracking_allocator.bad_free_array) > 0 {
			fmt.eprintf("=== %v incorrect frees: ===\n", len(tracking_allocator.bad_free_array))
			for entry in tracking_allocator.bad_free_array {
				fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
			}
		}
		mem.tracking_allocator_destroy(&tracking_allocator)
	}

	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println("open failed:", sqlite.error_string(err))
		return
	}
	defer sqlite.db_close(&db)

	err, ok = sqlite.db_exec(db, `
		CREATE TABLE users(
			id     INTEGER PRIMARY KEY,
			name   TEXT NOT NULL,
			email  TEXT NOT NULL UNIQUE,
			active INTEGER NOT NULL
		);
	`)
	if !ok {
		fmt.println("create table failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.db_exec(db, `
		INSERT INTO users(name, email, active) VALUES
			('Alice', 'alice@example.com', 1),
			('Bob',   'bob@example.com',   0);
	`)
	if !ok {
		fmt.println("seed insert failed:", sqlite.error_string(err))
		return
	}

	print_user(db, 1, "before update:")

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(
		db,
		"UPDATE users SET name = ?1, email = ?2, active = ?3 WHERE id = ?4",
	)
	if !prep_ok {
		fmt.println("prepare update failed:", sqlite.error_string(prep_err))
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	err, ok = sqlite.stmt_bind_text(&stmt, 1, "Alice Cooper")
	if !ok {
		fmt.println("bind update name failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.stmt_bind_text(&stmt, 2, "alice.cooper@example.com")
	if !ok {
		fmt.println("bind update email failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.stmt_bind_bool(&stmt, 3, false)
	if !ok {
		fmt.println("bind update active failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.stmt_bind_i64(&stmt, 4, 1)
	if !ok {
		fmt.println("bind update id failed:", sqlite.error_string(err))
		return
	}

	result, step_err, step_ok := sqlite.stmt_step(stmt)
	if !step_ok {
		fmt.println("update step failed:", sqlite.error_string(step_err))
		return
	}
	if result != .Done {
		fmt.println("update did not complete as expected")
		return
	}

	fmt.printf("rows changed=%d\n", sqlite.db_changes(db))

	print_user(db, 1, "after update:")

	missing_stmt, missing_prep_err, missing_prep_ok := sqlite.stmt_prepare(
		db,
		"UPDATE users SET active = ?1 WHERE id = ?2",
	)
	if !missing_prep_ok {
		fmt.println("prepare missing-row update failed:", sqlite.error_string(missing_prep_err))
		return
	}
	defer sqlite.stmt_finalize(&missing_stmt)

	err, ok = sqlite.stmt_bind_bool(&missing_stmt, 1, true)
	if !ok {
		fmt.println("bind missing-row active failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.stmt_bind_i64(&missing_stmt, 2, 999)
	if !ok {
		fmt.println("bind missing-row id failed:", sqlite.error_string(err))
		return
	}

	result, step_err, step_ok = sqlite.stmt_step(missing_stmt)
	if !step_ok {
		fmt.println("missing-row update step failed:", sqlite.error_string(step_err))
		return
	}
	if result != .Done {
		fmt.println("missing-row update did not complete as expected")
		return
	}

	fmt.printf("rows changed after missing-row update=%d\n", sqlite.db_changes(db))
}