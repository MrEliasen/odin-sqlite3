package main

import "core:fmt"
import example_support "../../_support"
import sqlite "../../../../sqlite"

User :: struct {
	id:     i64,
	name:   string,
	email:  string,
	active: bool,
}

load_user_by_id :: proc(db: sqlite.DB, id: i64) -> (User, bool) {
	stmt, err, ok := sqlite.stmt_prepare(
		db,
		"SELECT id, name, email, active FROM users WHERE id = ?1",
	)
	if !ok {
		fmt.println("prepare failed:", sqlite.error_string(err))
		return User{}, false
	}
	defer sqlite.stmt_finalize_cleanup(&stmt)

	err, ok = sqlite.stmt_bind_i64(&stmt, 1, id)
	if !ok {
		fmt.println("bind failed:", sqlite.error_string(err))
		return User{}, false
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println("step failed:", sqlite.error_string(step_err))
		return User{}, false
	}
	if !has_row {
		return User{}, false
	}

	return User{
		id     = sqlite.stmt_get_i64(stmt, 0),
		name   = sqlite.stmt_get_text(stmt, 1, context.temp_allocator),
		email  = sqlite.stmt_get_text(stmt, 2, context.temp_allocator),
		active = sqlite.stmt_get_bool(stmt, 3),
	}, true
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

	err, ok = sqlite.db_exec(db, `
		INSERT INTO users(name, email, active) VALUES
			('Alice', 'alice@example.com', 1),
			('Bob',   'bob@example.com',   0);
	`)
	if !ok {
		fmt.println("seed insert failed:", sqlite.error_string(err))
		return
	}

	user, found := load_user_by_id(db, 1)
	if !found {
		fmt.println("user with id=1 not found")
		return
	}

	fmt.printf(
		"read user id=%d name=%q email=%q active=%v\n",
		user.id,
		user.name,
		user.email,
		user.active,
	)

	_, found = load_user_by_id(db, 999)
	fmt.printf("user with id=999 found? %v\n", found)
}

main :: proc() {
	example_support.run(example_main)
}
