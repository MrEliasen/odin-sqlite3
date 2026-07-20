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
		CREATE TABLE users(
			id     INTEGER PRIMARY KEY,
			name   TEXT NOT NULL,
			email  TEXT NOT NULL UNIQUE,
			active INTEGER NOT NULL
		);
	`)
	if !ok {
		fmt.println("create table failed:", sqlite.error_string(err))
		return
	}

	stmt, prep_err, prep_ok := sqlite.stmt_prepare(
		db,
		"INSERT INTO users(name, email, active) VALUES (?1, ?2, ?3)",
	)
	if !prep_ok {
		fmt.println("prepare insert failed:", sqlite.error_string(prep_err))
		return
	}
	defer sqlite.stmt_finalize_cleanup(&stmt)

	err, ok = sqlite.stmt_bind_text(&stmt, 1, "Alice")
	if !ok {
		fmt.println("bind name failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.stmt_bind_text(&stmt, 2, "alice@example.com")
	if !ok {
		fmt.println("bind email failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.stmt_bind_bool(&stmt, 3, true)
	if !ok {
		fmt.println("bind active failed:", sqlite.error_string(err))
		return
	}

	result, step_err, step_ok := sqlite.stmt_step(stmt)
	if !step_ok {
		fmt.println("insert step failed:", sqlite.error_string(step_err))
		return
	}
	if result != .Done {
		fmt.println("insert did not complete as expected")
		return
	}

	new_id := sqlite.db_last_insert_rowid(db)

	fmt.printf("created user id=%d\n", new_id)
	fmt.printf("rows changed=%d\n", sqlite.db_changes(db))
}

main :: proc() {
	example_support.run(example_main)
}
