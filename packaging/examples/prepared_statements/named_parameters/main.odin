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
		CREATE TABLE players(
			id           INTEGER PRIMARY KEY,
			username     TEXT NOT NULL UNIQUE,
			level        INTEGER NOT NULL,
			experience   INTEGER NOT NULL,
			online       INTEGER NOT NULL,
			region       TEXT,
			profile_blob BLOB
		);
	`)
	if !ok {
		fmt.println("create table failed:", sqlite.error_string(err))
		return
	}

	insert_stmt, insert_err, insert_ok := sqlite.stmt_prepare(
		db,
		`INSERT INTO players(
			username,
			level,
			experience,
			online,
			region,
			profile_blob
		) VALUES (
			:username,
			@level,
			$experience,
			:online,
			@region,
			$profile_blob
		)`,
	)
	if !insert_ok {
		fmt.println("prepare insert failed:", sqlite.error_string(insert_err))
		return
	}
	defer sqlite.stmt_finalize(&insert_stmt)

	fmt.printf("parameter count: %d\n", sqlite.stmt_param_count(insert_stmt))
	fmt.printf("index for :username = %d\n", sqlite.stmt_param_index(insert_stmt, ":username"))
	fmt.printf("index for @level = %d\n", sqlite.stmt_param_index(insert_stmt, "@level"))
	fmt.printf("index for $experience = %d\n", sqlite.stmt_param_index(insert_stmt, "$experience"))
	fmt.printf("parameter 1 name = %q\n", sqlite.stmt_param_name(insert_stmt, 1))
	fmt.printf("parameter 2 name = %q\n", sqlite.stmt_param_name(insert_stmt, 2))
	fmt.printf("parameter 3 name = %q\n", sqlite.stmt_param_name(insert_stmt, 3))

	profile := []u8{10, 20, 30, 40}

	insert_err, insert_ok = sqlite.stmt_bind_named_text(&insert_stmt, ":username", "ranger_one")
	if !insert_ok {
		fmt.println("bind :username failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_named_i32(&insert_stmt, "@level", 17)
	if !insert_ok {
		fmt.println("bind @level failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_named_i64(&insert_stmt, "$experience", 125_000)
	if !insert_ok {
		fmt.println("bind $experience failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_named_bool(&insert_stmt, ":online", true)
	if !insert_ok {
		fmt.println("bind :online failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_named_text(&insert_stmt, "@region", "eu-west")
	if !insert_ok {
		fmt.println("bind @region failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_named_blob(&insert_stmt, "$profile_blob", profile)
	if !insert_ok {
		fmt.println("bind $profile_blob failed:", sqlite.error_string(insert_err))
		return
	}

	insert_result, step_err, step_ok := sqlite.stmt_step(insert_stmt)
	if !step_ok {
		fmt.println("insert step failed:", sqlite.error_string(step_err))
		return
	}
	if insert_result != .Done {
		fmt.println("insert did not complete as expected")
		return
	}

	inserted_id := sqlite.db_last_insert_rowid(db)
	fmt.printf("inserted player id=%d\n", inserted_id)

	query_stmt, query_err, query_ok := sqlite.stmt_prepare(
		db,
		`SELECT
			username,
			level,
			experience,
			online,
			region,
			profile_blob
		FROM players
		WHERE username = :username`,
	)
	if !query_ok {
		fmt.println("prepare query failed:", sqlite.error_string(query_err))
		return
	}
	defer sqlite.stmt_finalize(&query_stmt)

	query_err, query_ok = sqlite.stmt_bind_named_text(&query_stmt, ":username", "ranger_one")
	if !query_ok {
		fmt.println("bind query :username failed:", sqlite.error_string(query_err))
		return
	}

	has_row, next_err, next_ok := sqlite.stmt_next(query_stmt)
	if !next_ok {
		fmt.println("query step failed:", sqlite.error_string(next_err))
		return
	}
	if !has_row {
		fmt.println("expected one row but found none")
		return
	}

	fmt.printf("username=%q\n", sqlite.stmt_get_text(query_stmt, 0, context.temp_allocator))
	fmt.printf("level=%d\n", sqlite.stmt_get_i32(query_stmt, 1))
	fmt.printf("experience=%d\n", sqlite.stmt_get_i64(query_stmt, 2))
	fmt.printf("online=%v\n", sqlite.stmt_get_bool(query_stmt, 3))
	fmt.printf("region=%q\n", sqlite.stmt_get_text(query_stmt, 4, context.temp_allocator))

	got_blob := sqlite.stmt_get_blob(query_stmt, 5, context.temp_allocator)
	fmt.printf("profile_blob_len=%d\n", len(got_blob))
	for i, b in got_blob {
		fmt.printf("profile_blob[%d]=%d\n", i, b)
	}

	reuse_err, reuse_ok := sqlite.stmt_reuse(&query_stmt)
	if !reuse_ok {
		fmt.println("stmt_reuse failed:", sqlite.error_string(reuse_err))
		return
	}

	query_err, query_ok = sqlite.stmt_bind_named_text(&query_stmt, ":username", "missing_player")
	if !query_ok {
		fmt.println("bind reused query :username failed:", sqlite.error_string(query_err))
		return
	}

	has_row, next_err, next_ok = sqlite.stmt_next(query_stmt)
	if !next_ok {
		fmt.println("reused query step failed:", sqlite.error_string(next_err))
		return
	}

	fmt.printf("missing player found? %v\n", has_row)
}