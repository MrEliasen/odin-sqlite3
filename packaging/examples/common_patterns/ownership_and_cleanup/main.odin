package main
import "core:mem"

import "core:fmt"
import sqlite "../../../../sqlite"

Owned_User :: struct {
	id:           i64,
	display_name: string `sqlite:"user_name"`,
	profile_blob: []u8   `sqlite:"profile_data"`,
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
			id           INTEGER PRIMARY KEY,
			user_name    TEXT NOT NULL,
			profile_data BLOB NOT NULL
		);
	`)
	if !ok {
		fmt.println("create table failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.db_exec(db, `
		INSERT INTO users(user_name, profile_data) VALUES
			('alice', x'01020304'),
			('bob',   x'0A0B0C0D');
	`)
	if !ok {
		fmt.println("seed insert failed:", sqlite.error_string(err))
		return
	}

	fmt.println("ownership and cleanup example:")
	fmt.println()

	// 1. Direct typed getters that allocate caller-owned memory.
	stmt, prep_err, prep_ok := sqlite.stmt_prepare(
		db,
		"SELECT user_name, profile_data FROM users WHERE id = ?1",
	)
	if !prep_ok {
		fmt.println("prepare failed:", sqlite.error_string(prep_err))
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	err, ok = sqlite.stmt_bind_i64(&stmt, 1, 1)
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
		fmt.println("no row found for direct getter example")
		return
	}

	owned_name := sqlite.stmt_get_text(stmt, 0)
	defer delete(owned_name)

	owned_blob := sqlite.stmt_get_blob(stmt, 1)
	defer delete(owned_blob)

	fmt.printf(
		"direct getters -> name=%q blob_len=%d first_blob_byte=%d\n",
		owned_name,
		len(owned_blob),
		owned_blob[0],
	)

	fmt.println()
	fmt.println("cleanup shown above:")
	fmt.println("- owned_name came from stmt_get_text(...)")
	fmt.println("- owned_blob came from stmt_get_blob(...)")
	fmt.println("- both are caller-owned because they were copied into allocated memory")

	fmt.println()

	// 2. Struct mapping that writes caller-owned copied fields into your struct.
	mapped := Owned_User{}
	err, ok = sqlite.db_query_one_struct(
		db,
		"SELECT id, user_name, profile_data FROM users WHERE id = 2",
		&mapped,
	)
	if !ok {
		fmt.println("db_query_one_struct failed:", sqlite.error_string(err))
		return
	}
	defer delete(mapped.display_name)
	defer delete(mapped.profile_blob)

	fmt.printf(
		"struct mapping -> {id=%d display_name=%q blob_len=%d first_blob_byte=%d}\n",
		mapped.id,
		mapped.display_name,
		len(mapped.profile_blob),
		mapped.profile_blob[0],
	)

	fmt.println()
	fmt.println("cleanup shown above:")
	fmt.println("- mapped.display_name is caller-owned after stmt_scan_struct/db_query_one_struct")
	fmt.println("- mapped.profile_blob is caller-owned after stmt_scan_struct/db_query_one_struct")

	fmt.println()

	// 3. Query-all wrapper: cleanup is two-layered.
	all_rows, all_err, all_ok := sqlite.db_query_all_struct(
		db,
		"SELECT id, user_name, profile_data FROM users ORDER BY id",
		Owned_User,
	)
	if !all_ok {
		fmt.println("db_query_all_struct failed:", sqlite.error_string(all_err))
		return
	}
	defer delete(all_rows)

	for &row in all_rows {
		defer delete(row.display_name)
		defer delete(row.profile_blob)
	}

	fmt.printf("query_all_struct -> row_count=%d\n", len(all_rows))
	for row, index in all_rows {
		fmt.printf(
			"  row[%d] = {id=%d display_name=%q blob_len=%d first_blob_byte=%d}\n",
			index,
			row.id,
			row.display_name,
			len(row.profile_blob),
			row.profile_blob[0],
		)
	}

	fmt.println()
	fmt.println("cleanup shown above:")
	fmt.println("- each row.display_name must be released")
	fmt.println("- each row.profile_blob must be released")
	fmt.println("- then the outer all_rows slice must be released")

	fmt.println()
	fmt.println("Rule of thumb:")
	fmt.println("- if an API copies text/blob data using the allocator you provide, that copied memory is owned by you")
	fmt.println("- if you use a non-temporary allocator, release that memory with delete(...) when appropriate")
	fmt.println("- if you use context.temp_allocator instead, you usually would not individually delete those values")

	fmt.println()
	fmt.println("ownership_and_cleanup example completed successfully")
}