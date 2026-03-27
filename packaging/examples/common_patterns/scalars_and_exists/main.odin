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

	err, ok = sqlite.db_exec_no_rows(db, `
		CREATE TABLE products(
			id          INTEGER PRIMARY KEY,
			sku         TEXT NOT NULL UNIQUE,
			name        TEXT NOT NULL,
			price_cents INTEGER NOT NULL,
			in_stock    INTEGER NOT NULL
		);
	`)
	if !ok {
		fmt.println("create table failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.db_exec_no_rows(db, `
		INSERT INTO products(sku, name, price_cents, in_stock) VALUES
			('A-100', 'Keyboard',  7999, 1),
			('B-200', 'Mouse',     2999, 1),
			('C-300', 'Monitor',  24999, 0);
	`)
	if !ok {
		fmt.println("seed insert failed:", sqlite.error_string(err))
		return
	}

	fmt.printf("rows changed by last exec: %d\n", sqlite.db_changes(db))
	fmt.printf("total rows changed so far: %d\n", sqlite.db_total_changes(db))

	count, scalar_err, scalar_ok := sqlite.db_scalar_i64(
		db,
		"SELECT COUNT(*) FROM products",
	)
	if !scalar_ok {
		fmt.println("count query failed:", sqlite.error_string(scalar_err))
		return
	}
	fmt.printf("product count: %d\n", count)

	max_price, scalar_err_2, scalar_ok_2 := sqlite.db_scalar_i64(
		db,
		"SELECT MAX(price_cents) FROM products",
	)
	if !scalar_ok_2 {
		fmt.println("max price query failed:", sqlite.error_string(scalar_err_2))
		return
	}
	fmt.printf("highest price_cents: %d\n", max_price)

	first_name, scalar_err_3, scalar_ok_3 := sqlite.db_scalar_text(
			
		db,
		"SELECT name FROM products WHERE sku = 'A-100'",
		allocator = context.temp_allocator,
	)
	if !scalar_ok_3 {
		fmt.println("scalar text query failed:", sqlite.error_string(scalar_err_3))
		return
	}
	fmt.printf("product A-100 name: %q\n", first_name)

	highest_in_stock_price, scalar_err_4, scalar_ok_4 := sqlite.db_scalar_i64(
		db,
		"SELECT MAX(price_cents) FROM products WHERE in_stock = 1",
	)
	if !scalar_ok_4 {
		fmt.println("highest in-stock price query failed:", sqlite.error_string(scalar_err_4))
		return
	}
	fmt.printf("highest in-stock price_cents: %d\n", highest_in_stock_price)

	avg_price, scalar_err_5, scalar_ok_5 := sqlite.db_scalar_f64(
		db,
		"SELECT AVG(price_cents) FROM products",
	)
	if !scalar_ok_5 {
		fmt.println("average price query failed:", sqlite.error_string(scalar_err_5))
		return
	}
	fmt.printf("average price_cents: %.2f\n", avg_price)

	any_in_stock, exists_err, exists_ok := sqlite.db_exists(
		db,
		"SELECT 1 FROM products WHERE in_stock = 1 LIMIT 1",
	)
	if !exists_ok {
		fmt.println("exists query for in-stock products failed:", sqlite.error_string(exists_err))
		return
	}
	fmt.printf("any in-stock products? %v\n", any_in_stock)

	any_expensive, exists_err_2, exists_ok_2 := sqlite.db_exists(
		db,
		"SELECT 1 FROM products WHERE price_cents > 50000 LIMIT 1",
	)
	if !exists_ok_2 {
		fmt.println("exists query for expensive products failed:", sqlite.error_string(exists_err_2))
		return
	}
	fmt.printf("any products over 50000 cents? %v\n", any_expensive)

	monitor_exists, exists_err_3, exists_ok_3 := sqlite.db_exists(
		db,
		"SELECT 1 FROM products WHERE sku = 'C-300' LIMIT 1",
	)
	if !exists_ok_3 {
		fmt.println("exists query for monitor failed:", sqlite.error_string(exists_err_3))
		return
	}
	fmt.printf("does sku C-300 exist? %v\n", monitor_exists)

	missing_exists, exists_err_4, exists_ok_4 := sqlite.db_exists(
		db,
		"SELECT 1 FROM products WHERE sku = 'Z-999' LIMIT 1",
	)
	if !exists_ok_4 {
		fmt.println("exists query for missing SKU failed:", sqlite.error_string(exists_err_4))
		return
	}
	fmt.printf("does sku Z-999 exist? %v\n", missing_exists)

	fmt.println("scalar helpers and exists example completed successfully")
}