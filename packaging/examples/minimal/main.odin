package main

import "core:fmt"
import example_support "../_support"
import sqlite "../../../sqlite"

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
		fmt.println("schema setup failed:", sqlite.error_string(err))
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

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(
		db,
		"SELECT name FROM users WHERE id = ?1",
	)
	if !prep_ok {
		fmt.println("prepare failed:", sqlite.error_string(prep_err))
		return
	}
	defer sqlite.stmt_finalize_cleanup(&stmt)

	bind_err, bind_ok := sqlite.stmt_bind_i64(&stmt, 1, 2)
	if !bind_ok {
		fmt.println("bind failed:", sqlite.error_string(bind_err))
		return
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println("step failed:", sqlite.error_string(step_err))
		return
	}
	if !has_row {
		fmt.println("no row found")
		return
	}

	name := sqlite.stmt_get_text(stmt, 0, context.temp_allocator)
	fmt.println("user with id=2:", name)

	count, scalar_err, scalar_ok := sqlite.db_scalar_i64(
		db,
		"SELECT COUNT(*) FROM users",
	)
	if !scalar_ok {
		fmt.println("scalar query failed:", sqlite.error_string(scalar_err))
		return
	}

	fmt.println("total users:", count)
}

main :: proc() {
	example_support.run(example_main)
}
