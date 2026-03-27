package main
import "core:mem"

import "core:fmt"
import sqlite "../../../../sqlite"

user_exists :: proc(db: sqlite.DB, id: i64) -> bool {
	stmt, err, ok := sqlite.stmt_prepare(
		db,
		"SELECT 1 FROM users WHERE id = ?1",
	)
	if !ok {
		fmt.println("prepare exists query failed:", sqlite.error_string(err))
		return false
	}
	defer sqlite.stmt_finalize(&stmt)

	err, ok = sqlite.stmt_bind_i64(&stmt, 1, id)
	if !ok {
		fmt.println("bind exists query failed:", sqlite.error_string(err))
		return false
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println("step exists query failed:", sqlite.error_string(step_err))
		return false
	}

	return has_row
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

	fmt.printf("before delete, user id=1 exists? %v\n", user_exists(db, 1))
	fmt.printf("before delete, user id=2 exists? %v\n", user_exists(db, 2))

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(
		db,
		"DELETE FROM users WHERE id = ?1",
	)
	if !prep_ok {
		fmt.println("prepare delete failed:", sqlite.error_string(prep_err))
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	err, ok = sqlite.stmt_bind_i64(&stmt, 1, 1)
	if !ok {
		fmt.println("bind delete id failed:", sqlite.error_string(err))
		return
	}

	result, step_err, step_ok := sqlite.stmt_step(stmt)
	if !step_ok {
		fmt.println("delete step failed:", sqlite.error_string(step_err))
		return
	}
	if result != .Done {
		fmt.println("delete did not complete as expected")
		return
	}

	fmt.printf("rows changed=%d\n", sqlite.db_changes(db))
	fmt.printf("after delete, user id=1 exists? %v\n", user_exists(db, 1))
	fmt.printf("after delete, user id=2 exists? %v\n", user_exists(db, 2))

	reuse_err, reuse_ok := sqlite.stmt_reuse(&stmt)
	if !reuse_ok {
		fmt.println("stmt_reuse failed:", sqlite.error_string(reuse_err))
		return
	}

	err, ok = sqlite.stmt_bind_i64(&stmt, 1, 999)
	if !ok {
		fmt.println("bind missing-row delete id failed:", sqlite.error_string(err))
		return
	}

	result, step_err, step_ok = sqlite.stmt_step(stmt)
	if !step_ok {
		fmt.println("missing-row delete step failed:", sqlite.error_string(step_err))
		return
	}
	if result != .Done {
		fmt.println("missing-row delete did not complete as expected")
		return
	}

	fmt.printf("rows changed after missing-row delete=%d\n", sqlite.db_changes(db))
}