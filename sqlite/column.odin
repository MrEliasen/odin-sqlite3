package sqlite

import raw "raw/generated"

column_index_valid :: proc(index: int) -> bool {
	return index >= 0
}

stmt_column_count :: proc(stmt: Stmt) -> int {
	if stmt.handle == nil {
		return 0
	}

	return int(raw.column_count(stmt.handle))
}

stmt_column_name :: proc(stmt: Stmt, index: int) -> string {
	if stmt.handle == nil || !column_index_valid(index) {
		return ""
	}

	name := raw.column_name(stmt.handle, i32(index))
	if name == nil {
		return ""
	}

	return string(name)
}

stmt_column_decltype :: proc(stmt: Stmt, index: int) -> string {
	if stmt.handle == nil || !column_index_valid(index) {
		return ""
	}

	decl := raw.column_decltype(stmt.handle, i32(index))
	if decl == nil {
		return ""
	}

	return string(decl)
}

stmt_column_type :: proc(stmt: Stmt, index: int) -> int {
	if stmt.handle == nil || !column_index_valid(index) {
		return int(raw.NULL)
	}

	return int(raw.column_type(stmt.handle, i32(index)))
}

stmt_is_null :: proc(stmt: Stmt, index: int) -> bool {
	return stmt_column_type(stmt, index) == int(raw.NULL)
}

stmt_get_i32 :: proc(stmt: Stmt, index: int) -> i32 {
	if stmt.handle == nil || !column_index_valid(index) {
		return 0
	}

	return raw.column_int(stmt.handle, i32(index))
}

stmt_get_i64 :: proc(stmt: Stmt, index: int) -> i64 {
	if stmt.handle == nil || !column_index_valid(index) {
		return 0
	}

	return i64(raw.column_int64(stmt.handle, i32(index)))
}

stmt_get_f64 :: proc(stmt: Stmt, index: int) -> f64 {
	if stmt.handle == nil || !column_index_valid(index) {
		return 0
	}

	return raw.column_double(stmt.handle, i32(index))
}

stmt_get_bool :: proc(stmt: Stmt, index: int) -> bool {
	return stmt_get_i32(stmt, index) != 0
}

// stmt_get_text returns a copied string value for the current row/column using `allocator`.
//
// Ownership:
// - the returned string is owned by the caller
// - when the returned string is allocated from a non-temporary allocator, the caller is
//   responsible for releasing it with `delete(...)` when appropriate
//
// Lifetime:
// - this proc copies SQLite's transient column data before returning
// - the returned string therefore remains valid independently of later `step/reset/finalize` calls
stmt_get_text :: proc(stmt: Stmt, index: int, allocator := context.allocator) -> string {
	if stmt.handle == nil || !column_index_valid(index) {
		return ""
	}

	if stmt_is_null(stmt, index) {
		return ""
	}

	text_ptr := raw.column_text(stmt.handle, i32(index))
	if text_ptr == nil {
		return ""
	}

	byte_count := raw.column_bytes(stmt.handle, i32(index))
	if byte_count <= 0 {
		return ""
	}

	text_bytes := ([^]u8)(text_ptr)[:byte_count]
	out := make([]u8, byte_count, allocator)
	copy(out, text_bytes)
	return string(out)
}

// stmt_get_blob returns a copied blob value for the current row/column using `allocator`.
//
// Ownership:
// - the returned blob slice is owned by the caller
// - when the returned slice is allocated from a non-temporary allocator, the caller is
//   responsible for releasing it with `delete(...)` when appropriate
//
// Lifetime:
// - this proc copies SQLite's transient column data before returning
// - the returned slice therefore remains valid independently of later `step/reset/finalize` calls
stmt_get_blob :: proc(stmt: Stmt, index: int, allocator := context.allocator) -> []u8 {
	if stmt.handle == nil || !column_index_valid(index) {
		return nil
	}

	if stmt_is_null(stmt, index) {
		return nil
	}

	blob_ptr := raw.column_blob(stmt.handle, i32(index))
	byte_count := raw.column_bytes(stmt.handle, i32(index))

	if byte_count < 0 {
		return nil
	}
	if byte_count == 0 {
		return []u8{}
	}
	if blob_ptr == nil {
		return nil
	}

	src := ([^]u8)(blob_ptr)[:byte_count]
	out := make([]u8, byte_count, allocator)
	copy(out, src)
	return out
}

stmt_get_text_bytes :: proc(stmt: Stmt, index: int) -> int {
	if stmt.handle == nil || !column_index_valid(index) {
		return 0
	}

	if stmt_is_null(stmt, index) {
		return 0
	}

	_ = raw.column_text(stmt.handle, i32(index))
	return int(raw.column_bytes(stmt.handle, i32(index)))
}

stmt_get_blob_bytes :: proc(stmt: Stmt, index: int) -> int {
	if stmt.handle == nil || !column_index_valid(index) {
		return 0
	}

	if stmt_is_null(stmt, index) {
		return 0
	}

	_ = raw.column_blob(stmt.handle, i32(index))
	return int(raw.column_bytes(stmt.handle, i32(index)))
}