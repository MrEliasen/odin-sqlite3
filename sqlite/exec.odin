package sqlite

import "core:strings"
import raw "raw/generated"

db_exec :: proc(db: DB, sql: string) -> (Error, bool) {
	if db.handle == nil {
		return error_from_db(db, int(raw.MISUSE), sql), false
	}

	c_sql := strings.clone_to_cstring(sql)
	defer delete(c_sql)

	rc := raw.exec(db.handle, c_sql, nil, nil, nil)
	return result_from_db(db, int(rc), sql)
}

db_exec_no_rows :: proc(db: DB, sql: string) -> (Error, bool) {
	return db_exec(db, sql)
}

db_changes :: proc(db: DB) -> i64 {
	if db.handle == nil {
		return 0
	}

	return i64(raw.changes64(db.handle))
}

db_total_changes :: proc(db: DB) -> i64 {
	if db.handle == nil {
		return 0
	}

	return i64(raw.total_changes64(db.handle))
}

db_last_insert_rowid :: proc(db: DB) -> i64 {
	if db.handle == nil {
		return 0
	}

	return i64(raw.last_insert_rowid(db.handle))
}

db_query_one :: proc(db: DB, sql: string, flags: int = DEFAULT_PREPARE_FLAGS) -> (Stmt, Error, bool) {
	stmt, err, ok := stmt_prepare(db, sql, flags)
	if !ok {
		return Stmt{}, err, false
	}

	has_row, step_err, step_ok := stmt_next(stmt)
	if !step_ok {
		_, _ = stmt_finalize(&stmt)
		return Stmt{}, step_err, false
	}
	if !has_row {
		_, _ = stmt_finalize(&stmt)
		return Stmt{}, error_from_db(db, int(raw.DONE), sql), false
	}

	return stmt, error_none(), true
}

db_query_optional :: proc(db: DB, sql: string, flags: int = DEFAULT_PREPARE_FLAGS) -> (Stmt, bool, Error, bool) {
	stmt, err, ok := stmt_prepare(db, sql, flags)
	if !ok {
		return Stmt{}, false, err, false
	}

	has_row, step_err, step_ok := stmt_next(stmt)
	if !step_ok {
		_, _ = stmt_finalize(&stmt)
		return Stmt{}, false, step_err, false
	}
	if !has_row {
		_, _ = stmt_finalize(&stmt)
		return Stmt{}, false, error_none(), true
	}

	return stmt, true, error_none(), true
}

db_query_all :: proc(db: DB, sql: string, flags: int = DEFAULT_PREPARE_FLAGS) -> (Stmt, Error, bool) {
	return stmt_prepare(db, sql, flags)
}

db_scalar_i64 :: proc(db: DB, sql: string, flags: int = DEFAULT_PREPARE_FLAGS) -> (i64, Error, bool) {
	stmt, err, ok := db_query_one(db, sql, flags)
	if !ok {
		return 0, err, false
	}
	defer stmt_finalize(&stmt)

	if stmt_is_null(stmt, 0) {
		return 0, error_none(), true
	}

	return stmt_get_i64(stmt, 0), error_none(), true
}

db_scalar_f64 :: proc(db: DB, sql: string, flags: int = DEFAULT_PREPARE_FLAGS) -> (f64, Error, bool) {
	stmt, err, ok := db_query_one(db, sql, flags)
	if !ok {
		return 0, err, false
	}
	defer stmt_finalize(&stmt)

	if stmt_is_null(stmt, 0) {
		return 0, error_none(), true
	}

	return stmt_get_f64(stmt, 0), error_none(), true
}

// db_scalar_text returns a copied string scalar using `allocator`.
//
// Ownership:
// - the returned string is owned by the caller
// - when the returned string is allocated from a non-temporary allocator, the caller is
//   responsible for releasing it with `delete(...)` when appropriate
//
// Lifetime:
// - this proc copies SQLite's transient column data before returning
// - the returned string therefore remains valid independently of later statement finalization
db_scalar_text :: proc(db: DB, sql: string, flags: int = DEFAULT_PREPARE_FLAGS, allocator := context.allocator) -> (string, Error, bool) {
	stmt, err, ok := db_query_one(db, sql, flags)
	if !ok {
		return "", err, false
	}
	defer stmt_finalize(&stmt)

	if stmt_is_null(stmt, 0) {
		return "", error_none(), true
	}

	return stmt_get_text(stmt, 0, allocator), error_none(), true
}

db_exists :: proc(db: DB, sql: string, flags: int = DEFAULT_PREPARE_FLAGS) -> (bool, Error, bool) {
	stmt, found, err, ok := db_query_optional(db, sql, flags)
	if !ok {
		return false, err, false
	}
	if !found {
		return false, error_none(), true
	}
	defer stmt_finalize(&stmt)

	if stmt_column_count(stmt) == 0 {
		return true, error_none(), true
	}
	if stmt_is_null(stmt, 0) {
		return false, error_none(), true
	}

	switch stmt_column_type(stmt, 0) {
	case int(raw.INTEGER):
		return stmt_get_i64(stmt, 0) != 0, error_none(), true
	case int(raw.FLOAT):
		return stmt_get_f64(stmt, 0) != 0, error_none(), true
	case int(raw.TEXT):
		return stmt_get_text_bytes(stmt, 0) > 0, error_none(), true
	case int(raw.BLOB):
		return stmt_get_blob_bytes(stmt, 0) > 0, error_none(), true
	case int(raw.NULL):
		return false, error_none(), true
	}

	return true, error_none(), true
}

db_with_stmt :: proc(
	db: DB,
	sql: string,
	body: proc(stmt: ^Stmt) -> (Error, bool),
	flags: int = DEFAULT_PREPARE_FLAGS,
) -> (Error, bool) {
	stmt, err, ok := stmt_prepare(db, sql, flags)
	if !ok {
		return err, false
	}
	defer stmt_finalize(&stmt)

	return body(&stmt)
}

stmt_step_all :: proc(stmt: ^Stmt, body: proc(stmt: ^Stmt) -> (Error, bool)) -> (int, Error, bool) {
	if stmt == nil || stmt.handle == nil {
		return 0, error_from_stmt(Stmt{}, int(raw.MISUSE)), false
	}

	count := 0
	for {
		has_row, err, ok := stmt_next(stmt^)
		if !ok {
			return count, err, false
		}
		if !has_row {
			break
		}

		row_err, row_ok := body(stmt)
		if !row_ok {
			return count, row_err, false
		}

		count += 1
	}

	return count, error_none(), true
}

stmt_consume_done :: proc(stmt: ^Stmt) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil {
		return error_from_stmt(Stmt{}, int(raw.MISUSE)), false
	}

	for {
		has_row, err, ok := stmt_next(stmt^)
		if !ok {
			return err, false
		}
		if !has_row {
			return error_none(), true
		}
	}
}