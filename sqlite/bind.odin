package sqlite

import "core:fmt"
import "core:strings"
import raw "raw/generated"

stmt_bind_error :: proc(stmt: Stmt) -> (Error, bool) {
	return error_from_stmt(stmt, int(raw.MISUSE)), false
}

stmt_bind_args_error :: proc(stmt: Stmt, message: string) -> (Error, bool) {
	err := error_from_stmt(stmt, int(raw.RANGE))
	err = error_with_op(err, "stmt_bind_args")
	err = error_with_context(err, message)
	return err, false
}

bind_index_valid :: proc(index: int) -> bool {
	return index > 0
}

stmt_clear_bound_storage :: proc(stmt: ^Stmt) {
	if stmt == nil {
		return
	}

	for c_value in stmt.bound_text_storage {
		delete(c_value)
	}
	for blob in stmt.bound_blob_storage {
		delete(blob)
	}

	clear(&stmt.bound_text_storage)
	clear(&stmt.bound_blob_storage)
}

stmt_bind_track_text :: proc(stmt: ^Stmt, value: string) -> cstring {
	c_value := strings.clone_to_cstring(value)
	append(&stmt.bound_text_storage, c_value)
	return c_value
}

stmt_bind_track_blob :: proc(stmt: ^Stmt, value: []u8) -> rawptr {
	if len(value) == 0 {
		stored := []u8{}
		append(&stmt.bound_blob_storage, stored)
		return nil
	}

	stored := make([]u8, len(value))
	copy(stored, value)
	append(&stmt.bound_blob_storage, stored)
	last := stmt.bound_blob_storage[len(stmt.bound_blob_storage)-1]
	return rawptr(&last[0])
}

stmt_bind_null :: proc(stmt: ^Stmt, index: int) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil || !bind_index_valid(index) {
		return stmt_bind_error(Stmt{})
	}

	rc := raw.bind_null(stmt.handle, i32(index))
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_i32 :: proc(stmt: ^Stmt, index: int, value: i32) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil || !bind_index_valid(index) {
		return stmt_bind_error(Stmt{})
	}

	rc := raw.bind_int(stmt.handle, i32(index), value)
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_i64 :: proc(stmt: ^Stmt, index: int, value: i64) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil || !bind_index_valid(index) {
		return stmt_bind_error(Stmt{})
	}

	rc := raw.bind_int64(stmt.handle, i32(index), raw.Int64(value))
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_f64 :: proc(stmt: ^Stmt, index: int, value: f64) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil || !bind_index_valid(index) {
		return stmt_bind_error(Stmt{})
	}

	rc := raw.bind_double(stmt.handle, i32(index), value)
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_bool :: proc(stmt: ^Stmt, index: int, value: bool) -> (Error, bool) {
	if value {
		return stmt_bind_i32(stmt, index, 1)
	}
	return stmt_bind_i32(stmt, index, 0)
}

stmt_bind_text :: proc(stmt: ^Stmt, index: int, value: string) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil || !bind_index_valid(index) {
		return stmt_bind_error(Stmt{})
	}

	c_value := stmt_bind_track_text(stmt, value)

	rc := raw.bind_text(
		stmt.handle,
		i32(index),
		c_value,
		i32(len(value)),
		raw.STATIC,
	)
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_blob :: proc(stmt: ^Stmt, index: int, value: []u8) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil || !bind_index_valid(index) {
		return stmt_bind_error(Stmt{})
	}

	data_ptr := stmt_bind_track_blob(stmt, value)

	rc := raw.bind_blob(
		stmt.handle,
		i32(index),
		data_ptr,
		i32(len(value)),
		raw.STATIC,
	)
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_zeroblob :: proc(stmt: ^Stmt, index: int, size: int) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil || !bind_index_valid(index) {
		return stmt_bind_error(Stmt{})
	}

	rc := raw.bind_zeroblob(stmt.handle, i32(index), i32(size))
	return result_from_stmt(stmt^, int(rc))
}

stmt_param_count :: proc(stmt: Stmt) -> int {
	if stmt.handle == nil {
		return 0
	}

	return int(raw.bind_parameter_count(stmt.handle))
}

stmt_param_index :: proc(stmt: Stmt, name: string) -> int {
	if stmt.handle == nil || name == "" {
		return 0
	}

	c_name := strings.clone_to_cstring(name)
	defer delete(c_name)

	return int(raw.bind_parameter_index(stmt.handle, c_name))
}

stmt_param_name :: proc(stmt: Stmt, index: int) -> string {
	if stmt.handle == nil || !bind_index_valid(index) {
		return ""
	}

	name := raw.bind_parameter_name(stmt.handle, i32(index))
	if name == nil {
		return ""
	}

	return string(name)
}

stmt_bind_named_null :: proc(stmt: ^Stmt, name: string) -> (Error, bool) {
	index := stmt_param_index(stmt^, name)
	if index == 0 {
		return error_from_stmt(stmt^, int(raw.RANGE)), false
	}
	return stmt_bind_null(stmt, index)
}

stmt_bind_named_i32 :: proc(stmt: ^Stmt, name: string, value: i32) -> (Error, bool) {
	index := stmt_param_index(stmt^, name)
	if index == 0 {
		return error_from_stmt(stmt^, int(raw.RANGE)), false
	}
	return stmt_bind_i32(stmt, index, value)
}

stmt_bind_named_i64 :: proc(stmt: ^Stmt, name: string, value: i64) -> (Error, bool) {
	index := stmt_param_index(stmt^, name)
	if index == 0 {
		return error_from_stmt(stmt^, int(raw.RANGE)), false
	}
	return stmt_bind_i64(stmt, index, value)
}

stmt_bind_named_f64 :: proc(stmt: ^Stmt, name: string, value: f64) -> (Error, bool) {
	index := stmt_param_index(stmt^, name)
	if index == 0 {
		return error_from_stmt(stmt^, int(raw.RANGE)), false
	}
	return stmt_bind_f64(stmt, index, value)
}

stmt_bind_named_bool :: proc(stmt: ^Stmt, name: string, value: bool) -> (Error, bool) {
	index := stmt_param_index(stmt^, name)
	if index == 0 {
		return error_from_stmt(stmt^, int(raw.RANGE)), false
	}
	return stmt_bind_bool(stmt, index, value)
}

stmt_bind_named_text :: proc(stmt: ^Stmt, name: string, value: string) -> (Error, bool) {
	index := stmt_param_index(stmt^, name)
	if index == 0 {
		return error_from_stmt(stmt^, int(raw.RANGE)), false
	}
	return stmt_bind_text(stmt, index, value)
}

stmt_bind_named_blob :: proc(stmt: ^Stmt, name: string, value: []u8) -> (Error, bool) {
	index := stmt_param_index(stmt^, name)
	if index == 0 {
		return error_from_stmt(stmt^, int(raw.RANGE)), false
	}
	return stmt_bind_blob(stmt, index, value)
}

stmt_bind_named :: proc(stmt: ^Stmt, name: string, arg: Bind_Arg) -> (Error, bool) {
	index := stmt_param_index(stmt^, name)
	if index == 0 {
		return error_from_stmt(stmt^, int(raw.RANGE)), false
	}

	return stmt_bind(stmt, index, arg)
}

stmt_bind :: proc(stmt: ^Stmt, index: int, arg: Bind_Arg) -> (Error, bool) {
	if stmt == nil {
		return stmt_bind_error(Stmt{})
	}

	switch arg.kind {
	case .Null:
		return stmt_bind_null(stmt, index)
	case .I32:
		return stmt_bind_i32(stmt, index, arg.value.(i32))
	case .I64:
		return stmt_bind_i64(stmt, index, arg.value.(i64))
	case .F64:
		return stmt_bind_f64(stmt, index, arg.value.(f64))
	case .Bool:
		return stmt_bind_bool(stmt, index, arg.value.(bool))
	case .Text:
		return stmt_bind_text(stmt, index, arg.value.(string))
	case .Blob:
		return stmt_bind_blob(stmt, index, arg.value.([]u8))
	}

	return error_from_stmt(stmt^, int(raw.MISUSE)), false
}

stmt_bind_args_slice :: proc(stmt: ^Stmt, args: []Bind_Arg) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil {
		return stmt_bind_error(Stmt{})
	}

	param_count := stmt_param_count(stmt^)
	if len(args) > param_count {
		return stmt_bind_args_error(
			stmt^,
			fmt.tprintf("too many positional bind args: args=%d params=%d", len(args), param_count),
		)
	}

	for arg, i in args {
		err, ok := stmt_bind(stmt, i+1, arg)
		if !ok {
			return err, false
		}
	}

	return error_none(), true
}

stmt_bind_args :: proc(stmt: ^Stmt, args: ..Bind_Arg) -> (Error, bool) {
	return stmt_bind_args_slice(stmt, args[:])
}