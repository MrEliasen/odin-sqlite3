package sqlite

import "core:strings"
import raw "raw/generated"

DEFAULT_PREPARE_FLAGS :: 0
PERSISTENT_PREPARE_FLAGS :: int(raw.PREPARE_PERSISTENT)

stmt_prepare :: proc(db: DB, sql: string, flags: int = DEFAULT_PREPARE_FLAGS) -> (Stmt, Error, bool) {
	if db.handle == nil {
		return Stmt{}, error_from_db(db, int(raw.MISUSE), sql), false
	}

	stmt := Stmt{
		db  = db.handle,
		sql = sql,
	}

	c_sql := strings.clone_to_cstring(sql)
	defer delete(c_sql)
	sql_len := len(sql) + 1

	rc := raw.prepare_v3(db.handle, c_sql, i32(sql_len), u32(flags), &stmt.handle, nil)
	if rc != raw.OK {
		return Stmt{}, error_from_db(db, int(rc), sql), false
	}

	if stmt.handle == nil {
		return Stmt{}, error_from_db(db, int(raw.ERROR), sql), false
	}

	return stmt, error_none(), true
}

stmt_prepare_persistent :: proc(db: DB, sql: string) -> (Stmt, Error, bool) {
	return stmt_prepare(db, sql, PERSISTENT_PREPARE_FLAGS)
}

stmt_step :: proc(stmt: Stmt) -> (Step_Result, Error, bool) {
	if stmt.handle == nil {
		return Step_Result.Invalid, error_from_stmt(stmt, int(raw.MISUSE)), false
	}

	rc := raw.step(stmt.handle)
	return step_result_or_error(stmt, int(rc))
}

stmt_next :: proc(stmt: Stmt) -> (bool, Error, bool) {
	result, err, ok := stmt_step(stmt)
	if !ok {
		return false, err, false
	}

	switch result {
	case .Row:
		return true, error_none(), true
	case .Done:
		return false, error_none(), true
	case .Invalid:
		return false, error_from_stmt(stmt, int(raw.ERROR)), false
	}

	return false, error_from_stmt(stmt, int(raw.ERROR)), false
}

stmt_reset :: proc(stmt: ^Stmt) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil {
		return error_from_stmt(Stmt{}, int(raw.MISUSE)), false
	}

	rc := raw.reset(stmt.handle)
	return result_from_stmt(stmt^, int(rc))
}

stmt_clear_bindings :: proc(stmt: ^Stmt) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil {
		return error_from_stmt(Stmt{}, int(raw.MISUSE)), false
	}

	stmt_clear_bound_storage(stmt)

	rc := raw.clear_bindings(stmt.handle)
	return result_from_stmt(stmt^, int(rc))
}

stmt_finalize :: proc(stmt: ^Stmt) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil {
		return error_none(), true
	}

	stmt_clear_bound_storage(stmt)

	rc := raw.finalize(stmt.handle)
	stmt.handle = nil

	err := error_none()
	ok := true
	if rc != raw.OK {
		err = error_from_stmt(stmt^, int(rc))
		ok = false
	}

	if stmt.owned_sql {
		delete(stmt.sql)
		stmt.owned_sql = false
	}

	delete(stmt.bound_text_storage)
	delete(stmt.bound_blob_storage)

	stmt.db = nil
	stmt.sql = ""
	return err, ok
}

stmt_sql :: proc(stmt: Stmt) -> string {
	if stmt.handle == nil {
		return ""
	}

	text := raw.sql(stmt.handle)
	if text == nil {
		return ""
	}

	return string(text)
}

stmt_expanded_sql :: proc(stmt: Stmt, allocator := context.allocator) -> string {
	if stmt.handle == nil {
		return ""
	}

	expanded := raw.expanded_sql(stmt.handle)
	if expanded == nil {
		return ""
	}
	defer raw.free(expanded)

	return strings.clone_from_cstring(cstring(expanded), allocator)
}

stmt_readonly :: proc(stmt: Stmt) -> bool {
	if stmt.handle == nil {
		return false
	}

	return raw.stmt_readonly(stmt.handle) != 0
}

stmt_data_count :: proc(stmt: Stmt) -> int {
	if stmt.handle == nil {
		return 0
	}

	return int(raw.data_count(stmt.handle))
}

stmt_ensure_reset :: proc(stmt: ^Stmt) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil {
		return error_from_stmt(Stmt{}, int(raw.MISUSE)), false
	}

	if raw.stmt_busy(stmt.handle) == 0 {
		return error_none(), true
	}

	return stmt_reset(stmt)
}

stmt_reuse :: proc(stmt: ^Stmt) -> (Error, bool) {
	err, ok := stmt_reset(stmt)
	if !ok {
		return err, false
	}

	err, ok = stmt_clear_bindings(stmt)
	if !ok {
		return err, false
	}

	return error_none(), true
}