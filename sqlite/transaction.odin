package sqlite

import "core:strings"
import raw "raw/generated"

// Allowed characters in a SAVEPOINT identifier. SQLite has no parameter binding
// for savepoint names, so the wrapper restricts callers to a conservative
// alphanumeric + underscore identifier set to eliminate SQL injection through
// the name.
@(private)
savepoint_name_is_safe :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	first := name[0]
	if !((first >= 'a' && first <= 'z') ||
	     (first >= 'A' && first <= 'Z') ||
	     first == '_') {
		return false
	}
	for i := 1; i < len(name); i += 1 {
		ch := name[i]
		if !((ch >= 'a' && ch <= 'z') ||
		     (ch >= 'A' && ch <= 'Z') ||
		     (ch >= '0' && ch <= '9') ||
		     ch == '_') {
			return false
		}
	}
	return true
}

@(private)
savepoint_name_error :: proc() -> (Error, bool) {
	return error_make(int(raw.MISUSE), "sqlite: savepoint name must be a non-empty identifier (letters, digits, underscore; cannot start with a digit)"), false
}

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
	if !savepoint_name_is_safe(name) {
		return savepoint_name_error()
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SAVEPOINT ")
	strings.write_string(&b, name)
	return db_exec(db, strings.to_string(b))
}

db_release :: proc(db: DB, name: string) -> (Error, bool) {
	if !savepoint_name_is_safe(name) {
		return savepoint_name_error()
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "RELEASE SAVEPOINT ")
	strings.write_string(&b, name)
	return db_exec(db, strings.to_string(b))
}

db_rollback_to :: proc(db: DB, name: string) -> (Error, bool) {
	if !savepoint_name_is_safe(name) {
		return savepoint_name_error()
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "ROLLBACK TO SAVEPOINT ")
	strings.write_string(&b, name)
	return db_exec(db, strings.to_string(b))
}

// db_with_transaction runs `body` inside an explicit BEGIN/COMMIT. On body
// failure the transaction is rolled back and the body's error is returned. On
// commit failure, the wrapper also attempts a defensive rollback (per SQLite a
// failed COMMIT generally auto-rolls back, but calling ROLLBACK afterwards is
// safe and clears any residual state). The body's returned Error is propagated
// to the caller — if the body uses owned strings (via `error_make` or
// `error_with_*`), the caller must release them with `error_destroy`.
db_with_transaction :: proc(db: DB, body: proc(db: DB) -> (Error, bool)) -> (Error, bool) {
	err, ok := db_begin(db)
	if !ok {
		return err, false
	}

	body_err, body_ok := body(db)
	if !body_ok {
		rollback_err, rollback_ok := db_rollback(db)
		if !rollback_ok {
			error_destroy(&body_err)
			return rollback_err, false
		}
		return body_err, false
	}

	commit_err, commit_ok := db_commit(db)
	if !commit_ok {
		rollback_err, _ := db_rollback(db) // defensive secondary cleanup
		error_destroy(&rollback_err)
		return commit_err, false
	}
	return commit_err, true
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
			// Best effort: RELEASE may still clear a surviving savepoint. Keep
			// the rollback error as the most actionable cleanup failure.
			release_err, _ := db_release(db, name)
			error_destroy(&release_err)
			error_destroy(&body_err)
			return rollback_err, false
		}

		// ROLLBACK TO does not remove the savepoint. RELEASE is required to
		// close it (and, for a top-level savepoint, restore autocommit).
		release_err, release_ok := db_release(db, name)
		if !release_ok {
			error_destroy(&body_err)
			return release_err, false
		}
		return body_err, false
	}

	return db_release(db, name)
}
