package main
import "core:mem"

import "core:fmt"
import sqlite "../../../../sqlite"

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
			id   INTEGER PRIMARY KEY,
			name TEXT NOT NULL
		);
	`)
	if !ok {
		fmt.println("create table failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.db_exec(db, `
		INSERT INTO users(name) VALUES
			('alice'),
			('bob'),
			('charlie');
	`)
	if !ok {
		fmt.println("seed insert failed:", sqlite.error_string(err))
		return
	}

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(
		db,
		"SELECT name FROM users WHERE id = ?1",
	)
	if !prep_ok {
		fmt.println("prepare failed:", sqlite.error_string(prep_err))
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	fmt.println("prepared statement reuse example:")

	ids := []i64{1, 2, 3, 999}
	for id in ids {
		reuse_err, reuse_ok := sqlite.stmt_reuse(&stmt)
		if !reuse_ok {
			fmt.println("stmt_reuse failed:", sqlite.error_string(reuse_err))
			return
		}

		bind_err, bind_ok := sqlite.stmt_bind_i64(&stmt, 1, id)
		if !bind_ok {
			fmt.println("bind failed:", sqlite.error_string(bind_err))
			return
		}

		has_row, step_err, step_ok := sqlite.stmt_next(stmt)
		if !step_ok {
			fmt.println("step failed:", sqlite.error_string(step_err))
			return
		}

		if has_row {
			name := sqlite.stmt_get_text(stmt, 0, context.temp_allocator)
			fmt.printf("id=%d -> %q\n", id, name)
		} else {
			fmt.printf("id=%d -> not found\n", id)
		}
	}

	fmt.println("demonstrating reset without clearing bindings:")

	reuse_err, reuse_ok := sqlite.stmt_reuse(&stmt)
	if !reuse_ok {
		fmt.println("stmt_reuse failed:", sqlite.error_string(reuse_err))
		return
	}

	bind_err, bind_ok := sqlite.stmt_bind_i64(&stmt, 1, 2)
	if !bind_ok {
		fmt.println("bind failed:", sqlite.error_string(bind_err))
		return
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println("step failed:", sqlite.error_string(step_err))
		return
	}
	if !has_row {
		fmt.println("expected a row for id=2")
		return
	}
	fmt.printf("first execution after bind -> %q\n", sqlite.stmt_get_text(stmt, 0, context.temp_allocator))

	reset_err, reset_ok := sqlite.stmt_reset(&stmt)
	if !reset_ok {
		fmt.println("stmt_reset failed:", sqlite.error_string(reset_err))
		return
	}

	has_row, step_err, step_ok = sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println("step after reset failed:", sqlite.error_string(step_err))
		return
	}
	if !has_row {
		fmt.println("expected bound parameter to survive reset")
		return
	}
	fmt.printf("second execution after reset -> %q\n", sqlite.stmt_get_text(stmt, 0, context.temp_allocator))

	clear_err, clear_ok := sqlite.stmt_clear_bindings(&stmt)
	if !clear_ok {
		fmt.println("stmt_clear_bindings failed:", sqlite.error_string(clear_err))
		return
	}

	reset_err, reset_ok = sqlite.stmt_reset(&stmt)
	if !reset_ok {
		fmt.println("stmt_reset after clear_bindings failed:", sqlite.error_string(reset_err))
		return
	}

	has_row, step_err, step_ok = sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println("step after clear_bindings failed:", sqlite.error_string(step_err))
		return
	}
	if !has_row {
		fmt.println("expected one row with NULL parameter result")
		return
	}

	if sqlite.stmt_is_null(stmt, 0) {
		fmt.println("after clear_bindings -> parameter is NULL as expected")
	} else {
		fmt.printf("unexpected non-NULL value after clear_bindings: %q\n", sqlite.stmt_get_text(stmt, 0, context.temp_allocator))
	}
}