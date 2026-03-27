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
		CREATE TABLE metrics(
			id           INTEGER PRIMARY KEY,
			label        TEXT NOT NULL,
			count_i32    INTEGER NOT NULL,
			total_i64    INTEGER NOT NULL,
			ratio_f64    REAL NOT NULL,
			enabled_bool INTEGER NOT NULL,
			payload_blob BLOB,
			note_text    TEXT
		);
	`)
	if !ok {
		fmt.println("create table failed:", sqlite.error_string(err))
		return
	}

	insert_stmt, insert_err, insert_ok := sqlite.stmt_prepare(
		db,
		`INSERT INTO metrics(
			label,
			count_i32,
			total_i64,
			ratio_f64,
			enabled_bool,
			payload_blob,
			note_text
		) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
	)
	if !insert_ok {
		fmt.println("prepare insert failed:", sqlite.error_string(insert_err))
		return
	}
	defer sqlite.stmt_finalize(&insert_stmt)

	payload := []u8{1, 2, 3, 4, 5}

	insert_err, insert_ok = sqlite.stmt_bind_text(&insert_stmt, 1, "primary")
	if !insert_ok {
		fmt.println("bind text failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_i32(&insert_stmt, 2, 42)
	if !insert_ok {
		fmt.println("bind i32 failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_i64(&insert_stmt, 3, 9_000_000_001)
	if !insert_ok {
		fmt.println("bind i64 failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_f64(&insert_stmt, 4, 3.14159)
	if !insert_ok {
		fmt.println("bind f64 failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_bool(&insert_stmt, 5, true)
	if !insert_ok {
		fmt.println("bind bool failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_blob(&insert_stmt, 6, payload)
	if !insert_ok {
		fmt.println("bind blob failed:", sqlite.error_string(insert_err))
		return
	}

	insert_err, insert_ok = sqlite.stmt_bind_null(&insert_stmt, 7)
	if !insert_ok {
		fmt.println("bind null failed:", sqlite.error_string(insert_err))
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
	fmt.printf("inserted row id=%d\n", inserted_id)

	query_stmt, query_err, query_ok := sqlite.stmt_prepare(
		db,
		`SELECT
			label,
			count_i32,
			total_i64,
			ratio_f64,
			enabled_bool,
			payload_blob,
			note_text
		FROM metrics
		WHERE id = ?1`,
	)
	if !query_ok {
		fmt.println("prepare query failed:", sqlite.error_string(query_err))
		return
	}
	defer sqlite.stmt_finalize(&query_stmt)

	query_err, query_ok = sqlite.stmt_bind_i64(&query_stmt, 1, inserted_id)
	if !query_ok {
		fmt.println("bind query id failed:", sqlite.error_string(query_err))
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

	label := sqlite.stmt_get_text(query_stmt, 0, context.temp_allocator)
	count_i32 := sqlite.stmt_get_i32(query_stmt, 1)
	total_i64 := sqlite.stmt_get_i64(query_stmt, 2)
	ratio_f64 := sqlite.stmt_get_f64(query_stmt, 3)
	enabled_bool := sqlite.stmt_get_bool(query_stmt, 4)
	got_blob := sqlite.stmt_get_blob(query_stmt, 5, context.temp_allocator)
	note_is_null := sqlite.stmt_is_null(query_stmt, 6)

	fmt.printf("label=%q\n", label)
	fmt.printf("count_i32=%d\n", count_i32)
	fmt.printf("total_i64=%d\n", total_i64)
	fmt.printf("ratio_f64=%.5f\n", ratio_f64)
	fmt.printf("enabled_bool=%v\n", enabled_bool)
	fmt.printf("payload_blob_len=%d\n", len(got_blob))
	fmt.printf("note_text_is_null=%v\n", note_is_null)

	for i, b in got_blob {
		fmt.printf("payload_blob[%d]=%d\n", i, b)
	}
}