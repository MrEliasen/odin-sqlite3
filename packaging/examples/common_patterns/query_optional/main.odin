package main
import "core:mem"

import "core:fmt"
import sqlite "../../../../sqlite"

print_optional_product :: proc(db: sqlite.DB, sku: string) {
	stmt, found, err, ok := sqlite.db_query_optional(
		db,
		fmt.tprintf("SELECT id, name, price_cents, in_stock FROM products WHERE sku = %q", sku),
	)
	if !ok {
		fmt.println("query_optional failed:", sqlite.error_string(err))
		return
	}
	if !found {
		fmt.printf("sku=%q -> no row found\n", sku)
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	fmt.printf(
		"sku=%q -> id=%d name=%q price_cents=%d in_stock=%v\n",
		sku,
		sqlite.stmt_get_i64(stmt, 0),
		sqlite.stmt_get_text(stmt, 1, context.temp_allocator),
		sqlite.stmt_get_i64(stmt, 2),
		sqlite.stmt_get_bool(stmt, 3),
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

	err, ok = sqlite.db_exec(db, `
		INSERT INTO products(sku, name, price_cents, in_stock) VALUES
			('A-100', 'Keyboard',  7999, 1),
			('B-200', 'Mouse',     2999, 1),
			('C-300', 'Monitor',  24999, 0);
	`)
	if !ok {
		fmt.println("seed insert failed:", sqlite.error_string(err))
		return
	}

	fmt.println("query_optional examples:")
	print_optional_product(db, "A-100")
	print_optional_product(db, "C-300")
	print_optional_product(db, "Z-999")

	stmt, found, optional_err, optional_ok := sqlite.db_query_optional(
		db,
		"SELECT id, name FROM products WHERE in_stock = 1 ORDER BY id LIMIT 1",
	)
	if !optional_ok {
		fmt.println("query_optional for first in-stock product failed:", sqlite.error_string(optional_err))
		return
	}
	if found {
		defer sqlite.stmt_finalize(&stmt)
		fmt.printf(
			"first in-stock product -> id=%d name=%q\n",
			sqlite.stmt_get_i64(stmt, 0),
			sqlite.stmt_get_text(stmt, 1, context.temp_allocator),
		)
	} else {
		fmt.println("no in-stock product found")
	}

	stmt, found, optional_err, optional_ok = sqlite.db_query_optional(
		db,
		"SELECT id, name FROM products WHERE in_stock = 0 AND price_cents > 50000 LIMIT 1",
	)
	if !optional_ok {
		fmt.println("query_optional for missing expensive out-of-stock product failed:", sqlite.error_string(optional_err))
		return
	}
	fmt.printf("expensive out-of-stock product found? %v\n", found)

	fmt.println("query_optional example completed successfully")
}