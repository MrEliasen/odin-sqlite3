package main

import "core:fmt"
import example_support "../../_support"
import sqlite "../../../../sqlite"

example_main :: proc() {
	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println("open failed:", sqlite.error_string(err))
		return
	}
	defer sqlite.db_close_cleanup(&db)

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
	defer sqlite.error_destroy(&bad_err)
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

	sqlite.error_with_context(&bad_err, "loading product report")
	sqlite.error_with_op(&bad_err, "query_one")

	fmt.println("annotated detailed string:")
	fmt.println(" ", sqlite.error_string(bad_err))
	fmt.printf("has context after annotation? %v\n", sqlite.error_has_context(bad_err))
	fmt.printf("has op after annotation? %v\n", sqlite.error_has_op(bad_err))

	fmt.println("")
	fmt.println("== add SQL to an existing error value ==")

	synthetic_err := sqlite.error_none()
	defer sqlite.error_destroy(&synthetic_err)
	sqlite.error_with_context(&synthetic_err, "building SQL for diagnostics")
	sqlite.error_with_op(&synthetic_err, "prepare")
	sqlite.error_with_sql(&synthetic_err, "SELECT id, name FROM products WHERE in_stock = 1")

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

main :: proc() {
	example_support.run(example_main)
}
