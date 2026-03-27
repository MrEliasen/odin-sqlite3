package main
import "core:mem"

import "core:fmt"
import sqlite "../../../../sqlite"

lookup_user_name :: proc(db: sqlite.DB, cache: ^sqlite.Stmt_Cache, id: i64) -> (string, bool) {
	stmt, err, ok := sqlite.db_prepare_cached(
		db,
		cache,
		"SELECT name FROM users WHERE id = ?1",
	)
	if !ok {
		fmt.println("prepare cached user lookup failed:", sqlite.error_string(err))
		return "", false
	}

	err, ok = sqlite.stmt_bind_i64(stmt, 1, id)
	if !ok {
		fmt.println("bind user lookup id failed:", sqlite.error_string(err))
		return "", false
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt^)
	if !step_ok {
		fmt.println("step user lookup failed:", sqlite.error_string(step_err))
		return "", false
	}
	if !has_row {
		return "", false
	}

	return sqlite.stmt_get_text(stmt^, 0, context.temp_allocator), true
}

count_users_with_prefix :: proc(db: sqlite.DB, cache: ^sqlite.Stmt_Cache, prefix: string) -> (i64, bool) {
	stmt, err, ok := sqlite.db_prepare_cached(
		db,
		cache,
		"SELECT COUNT(*) FROM users WHERE name LIKE :pattern",
	)
	if !ok {
		fmt.println("prepare cached count failed:", sqlite.error_string(err))
		return 0, false
	}

	pattern := fmt.tprintf("%s%%", prefix)
	err, ok = sqlite.stmt_bind_named_text(stmt, ":pattern", pattern)
	if !ok {
		fmt.println("bind named count pattern failed:", sqlite.error_string(err))
		return 0, false
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt^)
	if !step_ok {
		fmt.println("step count failed:", sqlite.error_string(step_err))
		return 0, false
	}
	if !has_row {
		fmt.println("count query returned no row")
		return 0, false
	}

	return sqlite.stmt_get_i64(stmt^, 0), true
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
			('charlie'),
			('anna'),
			('dora');
	`)
	if !ok {
		fmt.println("seed insert failed:", sqlite.error_string(err))
		return
	}

	cache := sqlite.cache_init()
	defer sqlite.cache_destroy(&cache)

	fmt.println("== warm cache with multiple statements ==")

	name, found := lookup_user_name(db, &cache, 1)
	if found {
		fmt.printf("lookup id=1 -> %q\n", name)
	} else {
		fmt.println("lookup id=1 -> not found")
	}

	name, found = lookup_user_name(db, &cache, 3)
	if found {
		fmt.printf("lookup id=3 -> %q\n", name)
	} else {
		fmt.println("lookup id=3 -> not found")
	}

	count, found_count := count_users_with_prefix(db, &cache, "a")
	if !found_count {
		return
	}
	fmt.printf("users with prefix 'a' -> %d\n", count)

	count, found_count = count_users_with_prefix(db, &cache, "b")
	if !found_count {
		return
	}
	fmt.printf("users with prefix 'b' -> %d\n", count)

	fmt.printf("cache_count after warmup = %d\n", sqlite.cache_count(cache))
	fmt.printf(
		"cache has lookup SQL? %v\n",
		sqlite.cache_has(cache, "SELECT name FROM users WHERE id = ?1"),
	)
	fmt.printf(
		"cache has count SQL? %v\n",
		sqlite.cache_has(cache, "SELECT COUNT(*) FROM users WHERE name LIKE :pattern"),
	)

	fmt.println("")
	fmt.println("== mark all cached statements unused ==")

	sqlite.cache_reset_usage(&cache)
	fmt.printf("cache_count before prune = %d\n", sqlite.cache_count(cache))

	fmt.println("")
	fmt.println("== use only one cached statement before pruning ==")

	name, found = lookup_user_name(db, &cache, 2)
	if found {
		fmt.printf("lookup id=2 -> %q\n", name)
	} else {
		fmt.println("lookup id=2 -> not found")
	}

	removed, prune_err, prune_ok := sqlite.cache_prune_unused(&cache)
	if !prune_ok {
		fmt.println("cache prune failed:", sqlite.error_string(prune_err))
		return
	}

	fmt.printf("pruned unused statements = %d\n", removed)
	fmt.printf("cache_count after prune = %d\n", sqlite.cache_count(cache))
	fmt.printf(
		"cache has lookup SQL after prune? %v\n",
		sqlite.cache_has(cache, "SELECT name FROM users WHERE id = ?1"),
	)
	fmt.printf(
		"cache has count SQL after prune? %v\n",
		sqlite.cache_has(cache, "SELECT COUNT(*) FROM users WHERE name LIKE :pattern"),
	)

	fmt.println("")
	fmt.println("== clear remaining cached statements ==")

	clear_err, clear_ok := sqlite.cache_clear(&cache)
	if !clear_ok {
		fmt.println("cache clear failed:", sqlite.error_string(clear_err))
		return
	}

	fmt.printf("cache_count after clear = %d\n", sqlite.cache_count(cache))
	fmt.printf(
		"cache has lookup SQL after clear? %v\n",
		sqlite.cache_has(cache, "SELECT name FROM users WHERE id = ?1"),
	)
	fmt.printf(
		"cache has count SQL after clear? %v\n",
		sqlite.cache_has(cache, "SELECT COUNT(*) FROM users WHERE name LIKE :pattern"),
	)

	fmt.println("")
	fmt.println("cache prune and clear example completed successfully")
}