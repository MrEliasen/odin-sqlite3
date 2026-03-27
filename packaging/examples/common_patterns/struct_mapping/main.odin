package main
import "core:mem"

import "core:fmt"
import sqlite "../../../../sqlite"

User_Row :: struct {
	id:           i64,
	display_name: string `sqlite:"user_name"`,
	is_admin:     bool,
	score:        f64,
}

print_user_by_id :: proc(db: sqlite.DB, user_id: i64) {
	stmt, err, ok := sqlite.stmt_prepare(
		db,
		"SELECT id, user_name, is_admin, score FROM users WHERE id = ?1",
	)
	if !ok {
		fmt.println("prepare failed:", sqlite.error_string(err))
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	err, ok = sqlite.stmt_bind_i64(&stmt, 1, user_id)
	if !ok {
		fmt.println("bind failed:", sqlite.error_string(err))
		return
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println("step failed:", sqlite.error_string(step_err))
		return
	}
	if !has_row {
		fmt.printf("id=%d -> no row found\n", user_id)
		return
	}

	row := User_Row{}
	scan_err, scan_ok := sqlite.stmt_scan_struct(stmt, &row)
	if !scan_ok {
		fmt.println("stmt_scan_struct failed:", sqlite.error_string(scan_err))
		return
	}
	defer delete(row.display_name)

	fmt.printf(
		"id=%d -> mapped row: {id=%d display_name=%q is_admin=%v score=%.2f}\n",
		user_id,
		row.id,
		row.display_name,
		row.is_admin,
		row.score,
	)

	explicit_name := sqlite.stmt_get_text(stmt, 1)
	defer delete(explicit_name)

	fmt.printf(
		"id=%d -> explicit getters still work: user_name=%q is_admin=%v\n",
		user_id,
		explicit_name,
		sqlite.stmt_get_bool(stmt, 2),
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
			id        INTEGER PRIMARY KEY,
			user_name TEXT NOT NULL,
			is_admin  INTEGER NOT NULL,
			score     REAL NOT NULL
		);
	`)
	if !ok {
		fmt.println("create table failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.db_exec(db, `
		INSERT INTO users(user_name, is_admin, score) VALUES
			('alice', 1, 42.5),
			('bob',   0, 18.0),
			('cara',  0, 99.25);
	`)
	if !ok {
		fmt.println("seed insert failed:", sqlite.error_string(err))
		return
	}

	fmt.println("struct mapping examples:")
	print_user_by_id(db, 1)
	print_user_by_id(db, 2)
	print_user_by_id(db, 999)

	fmt.println()
	fmt.println("Notes:")
	fmt.println("- field names map by exact column name")
	fmt.println("- `sqlite:\"user_name\"` remaps display_name <- user_name")
	fmt.println("- stmt_scan_struct maps the current row only")
	fmt.println("- explicit typed column getters remain available")
	fmt.println("- this example intentionally uses the default allocator for copied strings")
	fmt.println("- row.display_name is caller-owned after stmt_scan_struct, so we release it with delete(...)")
	fmt.println("- explicit_name is caller-owned after stmt_get_text(...), so we release it with delete(...)")
	fmt.println("- if you instead use context.temp_allocator, you usually would not individually delete those values")

	fmt.println("struct_mapping example completed successfully")
}