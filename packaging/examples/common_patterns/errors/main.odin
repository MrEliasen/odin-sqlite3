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

	fmt.println("== expected SQL error from invalid query ==")

	_, bad_err, bad_ok := sqlite.db_query_one(
		db,
		"SELECT definitely_missing_column FROM products",
	)
	if bad_ok {
		fmt.println("unexpected success for invalid SQL")
		return
	}

	fmt.println("summary:")
	fmt.println(" ", sqlite.error_summary(bad_err))

	fmt.println("detailed string:")
	fmt.println(" ", sqlite.error_string(bad_err))

	fmt.printf("primary code: %d\n", bad_err.code)
	fmt.printf("extended code: %d\n", bad_err.extended_code)
	fmt.printf("code name: %s\n", sqlite.error_code_name(bad_err.code))
	fmt.printf("has sql? %v\n", sqlite.error_has_sql(bad_err))
	fmt.printf("has context? %v\n", sqlite.error_has_context(bad_err))
	fmt.printf("has op? %v\n", sqlite.error_has_op(bad_err))

	fmt.println("")
	fmt.println("== add context and operation information ==")

	annotated_err := sqlite.error_with_op(
		sqlite.error_with_context(bad_err, "loading product report"),
		"query_one",
	)

	fmt.println("annotated detailed string:")
	fmt.println(" ", sqlite.error_string(annotated_err))
	fmt.printf("has context after annotation? %v\n", sqlite.error_has_context(annotated_err))
	fmt.printf("has op after annotation? %v\n", sqlite.error_has_op(annotated_err))

	fmt.println("")
	fmt.println("== add SQL to an existing error value ==")

	synthetic_err := sqlite.error_with_sql(
		sqlite.error_with_op(
			sqlite.error_with_context(
				sqlite.error_none(),
				"building SQL for diagnostics",
			),
			"prepare",
		),
		"SELECT id, name FROM products WHERE in_stock = 1",
	)

	fmt.println("synthetic error value with SQL attached:")
	fmt.println(" ", sqlite.error_string(synthetic_err))
	fmt.printf("synthetic has sql? %v\n", sqlite.error_has_sql(synthetic_err))
	fmt.printf("synthetic has context? %v\n", sqlite.error_has_context(synthetic_err))
	fmt.printf("synthetic has op? %v\n", sqlite.error_has_op(synthetic_err))

	fmt.println("")
	fmt.println("== ok-value helpers ==")

	ok_err := sqlite.error_none()
	fmt.printf("error_is_none(error_none()) -> %v\n", sqlite.error_is_none(ok_err))
	fmt.printf("error_ok(error_none()) -> %v\n", sqlite.error_ok(ok_err))
	fmt.println("ok string:")
	fmt.println(" ", sqlite.error_string(ok_err))

	fmt.println("")
	fmt.println("structured error handling example completed successfully")
}