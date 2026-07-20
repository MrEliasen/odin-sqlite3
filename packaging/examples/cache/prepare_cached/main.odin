package main

import "core:fmt"
import example_support "../../_support"
import sqlite "../../../../sqlite"

query_user_name :: proc(db: sqlite.DB, cache: ^sqlite.Stmt_Cache, id: i64) -> (string, bool) {
	stmt, err, ok := sqlite.db_prepare_cached(
		db,
		cache,
		"SELECT name FROM users WHERE id = ?1",
	)
	if !ok {
		fmt.println("prepare cached failed:", sqlite.error_string(err))
		return "", false
	}

	err, ok = sqlite.stmt_bind_i64(stmt, 1, id)
	if !ok {
		fmt.println("bind failed:", sqlite.error_string(err))
		return "", false
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt^)
	if !step_ok {
		fmt.println("step failed:", sqlite.error_string(step_err))
		return "", false
	}
	if !has_row {
		return "", false
	}

	return sqlite.stmt_get_text(stmt^, 0, context.temp_allocator), true
}

example_main :: proc() {
	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println("open failed:", sqlite.error_string(err))
		return
	}
	defer sqlite.db_close_cleanup(&db)

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

	cache := sqlite.cache_init()
	defer sqlite.cache_destroy_cleanup(&cache)

	fmt.println("prepare-once, reuse-many with db_prepare_cached:")

	ids := []i64{1, 2, 3, 999}
	for id in ids {
		name, found := query_user_name(db, &cache, id)
		if found {
			fmt.printf("id=%d -> %q\n", id, name)
		} else {
			fmt.printf("id=%d -> not found\n", id)
		}
	}

	fmt.printf("cache currently holds %d statement(s)\n", sqlite.cache_count(cache))
	fmt.printf(
		"cache has lookup SQL? %v\n",
		sqlite.cache_has(cache, "SELECT name FROM users WHERE id = ?1"),
	)

	clear_err, clear_ok := sqlite.cache_clear(&cache)
	if !clear_ok {
		fmt.println("cache clear failed:", sqlite.error_string(clear_err))
		return
	}

	fmt.printf("cache cleared, remaining statements=%d\n", sqlite.cache_count(cache))
}

main :: proc() {
	example_support.run(example_main)
}
