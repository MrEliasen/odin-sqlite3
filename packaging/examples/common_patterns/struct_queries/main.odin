package main
import "core:mem"

import "core:fmt"
import sqlite "../../../../sqlite"

User_Summary :: struct {
	id:           i64,
	display_name: string `sqlite:"user_name"`,
	is_admin:     bool,
	score:        f64,
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

	fmt.println("struct query wrapper examples:")

	first_user := User_Summary{}
	err, ok = sqlite.db_query_one_struct(
		db,
		"SELECT id, user_name, is_admin, score FROM users ORDER BY id LIMIT 1",
		&first_user,
	)
	if !ok {
		fmt.println("db_query_one_struct failed:", sqlite.error_string(err))
		return
	}
	defer delete(first_user.display_name)
	fmt.printf(
		"query_one_struct -> {id=%d display_name=%q is_admin=%v score=%.2f}\n",
		first_user.id,
		first_user.display_name,
		first_user.is_admin,
		first_user.score,
	)

	optional_user := User_Summary{}
	found, optional_err, optional_ok := sqlite.db_query_optional_struct(
		db,
		"SELECT id, user_name, is_admin, score FROM users WHERE user_name = 'bob'",
		&optional_user,
	)
	if !optional_ok {
		fmt.println("db_query_optional_struct failed:", sqlite.error_string(optional_err))
		return
	}
	if found {
		defer delete(optional_user.display_name)
		fmt.printf(
			"query_optional_struct(found) -> {id=%d display_name=%q is_admin=%v score=%.2f}\n",
			optional_user.id,
			optional_user.display_name,
			optional_user.is_admin,
			optional_user.score,
		)
	} else {
		fmt.println("query_optional_struct(found) -> no row found")
	}

	missing_user := User_Summary{
		id           = -1,
		display_name = "unchanged",
		is_admin     = true,
		score        = -1,
	}
	found, optional_err, optional_ok = sqlite.db_query_optional_struct(
		db,
		"SELECT id, user_name, is_admin, score FROM users WHERE user_name = 'nobody'",
		&missing_user,
	)
	if !optional_ok {
		fmt.println("db_query_optional_struct missing-case failed:", sqlite.error_string(optional_err))
		return
	}
	fmt.printf(
		"query_optional_struct(missing) -> found=%v preserved_output={id=%d display_name=%q is_admin=%v score=%.2f}\n",
		found,
		missing_user.id,
		missing_user.display_name,
		missing_user.is_admin,
		missing_user.score,
	)

	all_users, all_err, all_ok := sqlite.db_query_all_struct(
		db,
		"SELECT id, user_name, is_admin, score FROM users ORDER BY id",
		User_Summary,
	)
	if !all_ok {
		fmt.println("db_query_all_struct failed:", sqlite.error_string(all_err))
		return
	}
	defer delete(all_users)

	for &user in all_users {
		defer delete(user.display_name)
	}

	fmt.printf("query_all_struct -> row_count=%d\n", len(all_users))
	for user, index in all_users {
		fmt.printf(
			"  row[%d] = {id=%d display_name=%q is_admin=%v score=%.2f}\n",
			index,
			user.id,
			user.display_name,
			user.is_admin,
			user.score,
		)
	}

	fmt.println()
	fmt.println("Notes:")
	fmt.println("- this example intentionally uses the default allocator for copied struct field data")
	fmt.println("- db_query_one_struct requires a row and maps it into your struct")
	fmt.println("- db_query_optional_struct treats missing rows as a normal outcome")
	fmt.println("- db_query_all_struct collects all rows into a typed slice")
	fmt.println("- sqlite struct tags work with all three wrappers")
	fmt.println("- the returned slice from db_query_all_struct is caller-owned")
	fmt.println("- copied string and []u8 fields mapped into returned rows are also caller-owned")
	fmt.println("- this example releases each user.display_name before releasing the outer slice")
	fmt.println("- if you instead use context.temp_allocator, you usually would not individually delete those values")

	fmt.println("struct_queries example completed successfully")
}