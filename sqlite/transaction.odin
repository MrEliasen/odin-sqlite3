package sqlite

import "core:fmt"

db_begin :: proc(db: DB) -> (Error, bool) {
	return db_exec(db, "BEGIN")
}

db_begin_deferred :: proc(db: DB) -> (Error, bool) {
	return db_exec(db, "BEGIN DEFERRED")
}

db_begin_immediate :: proc(db: DB) -> (Error, bool) {
	return db_exec(db, "BEGIN IMMEDIATE")
}

db_begin_exclusive :: proc(db: DB) -> (Error, bool) {
	return db_exec(db, "BEGIN EXCLUSIVE")
}

db_commit :: proc(db: DB) -> (Error, bool) {
	return db_exec(db, "COMMIT")
}

db_rollback :: proc(db: DB) -> (Error, bool) {
	return db_exec(db, "ROLLBACK")
}

db_savepoint :: proc(db: DB, name: string) -> (Error, bool) {
	if name == "" {
		return Error{
			code    = 1,
			message = "sqlite: savepoint name must not be empty",
		}, false
	}

	return db_exec(db, fmt.tprintf("SAVEPOINT %s", name))
}

db_release :: proc(db: DB, name: string) -> (Error, bool) {
	if name == "" {
		return Error{
			code    = 1,
			message = "sqlite: savepoint name must not be empty",
		}, false
	}

	return db_exec(db, fmt.tprintf("RELEASE SAVEPOINT %s", name))
}

db_rollback_to :: proc(db: DB, name: string) -> (Error, bool) {
	if name == "" {
		return Error{
			code    = 1,
			message = "sqlite: savepoint name must not be empty",
		}, false
	}

	return db_exec(db, fmt.tprintf("ROLLBACK TO SAVEPOINT %s", name))
}

db_with_transaction :: proc(db: DB, body: proc(db: DB) -> (Error, bool)) -> (Error, bool) {
	err, ok := db_begin(db)
	if !ok {
		return err, false
	}

	body_err, body_ok := body(db)
	if !body_ok {
		rollback_err, rollback_ok := db_rollback(db)
		if !rollback_ok {
			return rollback_err, false
		}
		return body_err, false
	}

	return db_commit(db)
}

db_with_savepoint :: proc(db: DB, name: string, body: proc(db: DB) -> (Error, bool)) -> (Error, bool) {
	err, ok := db_savepoint(db, name)
	if !ok {
		return err, false
	}

	body_err, body_ok := body(db)
	if !body_ok {
		rollback_err, rollback_ok := db_rollback_to(db, name)
		if !rollback_ok {
			return rollback_err, false
		}
		return body_err, false
	}

	return db_release(db, name)
}