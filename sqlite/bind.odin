package sqlite

import "base:runtime"
import "core:fmt"
import "core:strings"
import raw "raw/generated"

stmt_bind_error :: proc(stmt: Stmt) -> (Error, bool) {
	return error_from_stmt(stmt, int(raw.MISUSE)), false
}

stmt_bind_args_error :: proc(stmt: Stmt, message: string) -> (Error, bool) {
	err := error_from_stmt(stmt, int(raw.RANGE))
	error_with_op(&err, "stmt_bind_args")
	error_with_context(&err, message)
	return err, false
}

bind_index_valid :: proc(index: int) -> bool {
	return index > 0 && index <= int(max(i32))
}

@(private)
stmt_bind_index_check :: proc(stmt: ^Stmt, index: int) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil || index <= 0 {
		return stmt_bind_error(Stmt{})
	}
	if index > int(max(i32)) {
		err := error_from_stmt(stmt^, int(raw.RANGE))
		error_with_op(&err, "stmt_bind")
		error_with_context(&err, "parameter index exceeds SQLite's i32 range")
		return err, false
	}
	return error_none(), true
}

stmt_clear_bound_storage :: proc(stmt: ^Stmt) {
	if stmt == nil {
		return
	}

	allocator := owner_allocator(stmt.allocator)
	for _, c_value in stmt.bound_text_storage {
		delete(c_value, allocator)
	}
	for _, blob in stmt.bound_blob_storage {
		delete(blob, allocator)
	}

	clear(&stmt.bound_text_storage)
	clear(&stmt.bound_blob_storage)
}

@(private)
stmt_release_text_slot :: proc(stmt: ^Stmt, index: i32) {
	if existing, ok := stmt.bound_text_storage[index]; ok {
		delete(existing, owner_allocator(stmt.allocator))
		delete_key(&stmt.bound_text_storage, index)
	}
}

@(private)
stmt_release_blob_slot :: proc(stmt: ^Stmt, index: i32) {
	if existing, ok := stmt.bound_blob_storage[index]; ok {
		delete(existing, owner_allocator(stmt.allocator))
		delete_key(&stmt.bound_blob_storage, index)
	}
}

@(private)
stmt_release_bound_slot :: proc(stmt: ^Stmt, index: i32) {
	stmt_release_text_slot(stmt, index)
	stmt_release_blob_slot(stmt, index)
}

// SQLite treats a NULL data pointer as SQL NULL even when the byte count is
// zero. A stable non-NULL address preserves the distinction for empty blobs.
stmt_empty_blob_sentinel: u8

stmt_bind_null :: proc(stmt: ^Stmt, index: int) -> (Error, bool) {
	err, valid := stmt_bind_index_check(stmt, index)
	if !valid {
		return err, false
	}

	rc := raw.bind_null(stmt.handle, i32(index))
	if rc == raw.OK {
		stmt_release_bound_slot(stmt, i32(index))
	}
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_i32 :: proc(stmt: ^Stmt, index: int, value: i32) -> (Error, bool) {
	err, valid := stmt_bind_index_check(stmt, index)
	if !valid {
		return err, false
	}

	rc := raw.bind_int(stmt.handle, i32(index), value)
	if rc == raw.OK {
		stmt_release_bound_slot(stmt, i32(index))
	}
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_i64 :: proc(stmt: ^Stmt, index: int, value: i64) -> (Error, bool) {
	err, valid := stmt_bind_index_check(stmt, index)
	if !valid {
		return err, false
	}

	rc := raw.bind_int64(stmt.handle, i32(index), raw.Int64(value))
	if rc == raw.OK {
		stmt_release_bound_slot(stmt, i32(index))
	}
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_f64 :: proc(stmt: ^Stmt, index: int, value: f64) -> (Error, bool) {
	err, valid := stmt_bind_index_check(stmt, index)
	if !valid {
		return err, false
	}

	rc := raw.bind_double(stmt.handle, i32(index), value)
	if rc == raw.OK {
		stmt_release_bound_slot(stmt, i32(index))
	}
	return result_from_stmt(stmt^, int(rc))
}

stmt_bind_bool :: proc(stmt: ^Stmt, index: int, value: bool) -> (Error, bool) {
	if value {
		return stmt_bind_i32(stmt, index, 1)
	}
	return stmt_bind_i32(stmt, index, 0)
}

stmt_bind_text :: proc(stmt: ^Stmt, index: int, value: string) -> (Error, bool) {
	err, valid := stmt_bind_index_check(stmt, index)
	if !valid {
		return err, false
	}

	allocator := owner_allocator(stmt.allocator)

	// Allocate the candidate without touching the current SQLITE_STATIC
	// backing; if SQLite rejects the rebind, that backing stays allocated and
	// tracked. What the parameter then holds depends on where SQLite failed
	// (vdbeUnbind): a busy statement (SQLITE_MISUSE) or an out-of-range index
	// (SQLITE_RANGE) is rejected before the old value is touched, so it stays
	// bound. Any later failure (e.g. SQLITE_TOOBIG, SQLITE_NOMEM) happens after
	// SQLite has already released the old value, so the parameter is NULL.
	// A nil pointer would make SQLite bind NULL and report success.
	c_value, alloc_err := strings.clone_to_cstring(value, allocator)
	if alloc_err != nil {
		return error_alloc("stmt_bind_text", alloc_err), false
	}

	// Reserve the tracking slot before SQLite can hold the pointer, so a
	// failed map growth cannot leave an untracked SQLITE_STATIC buffer.
	_, slot, inserted, slot_err := map_entry(&stmt.bound_text_storage, i32(index))
	if slot_err != nil {
		delete(c_value, allocator)
		return error_alloc("stmt_bind_text", slot_err), false
	}

	rc := raw.bind_text64(
		stmt.handle,
		i32(index),
		c_value,
		raw.Uint64(len(value)),
		raw.STATIC,
		u8(raw.UTF8),
	)
	if rc != raw.OK {
		delete(c_value, allocator)
		if inserted {
			delete_key(&stmt.bound_text_storage, i32(index))
		}
		return result_from_stmt(stmt^, int(rc))
	}

	// SQLite no longer references the previous buffer for this slot.
	if !inserted {
		delete(slot^, allocator)
	}
	slot^ = c_value
	stmt_release_blob_slot(stmt, i32(index))
	return error_none(), true

}

// stmt_bind_text64 is the explicitly named 64-bit-length variant. Odin
// strings are int-sized, so stmt_bind_text already uses sqlite3_bind_text64.
stmt_bind_text64 :: proc(stmt: ^Stmt, index: int, value: string) -> (Error, bool) {
	return stmt_bind_text(stmt, index, value)
}

stmt_bind_blob :: proc(stmt: ^Stmt, index: int, value: []u8) -> (Error, bool) {
	err, valid := stmt_bind_index_check(stmt, index)
	if !valid {
		return err, false
	}

	allocator := owner_allocator(stmt.allocator)
	stored: []u8
	data_ptr := rawptr(&stmt_empty_blob_sentinel)
	slot: ^[]u8
	inserted := false
	if len(value) > 0 {
		alloc_err: runtime.Allocator_Error
		stored, alloc_err = make([]u8, len(value), allocator)
		if alloc_err != nil {
			return error_alloc("stmt_bind_blob", alloc_err), false
		}
		copy(stored, value)
		data_ptr = rawptr(&stored[0])

		// Reserve the tracking slot before SQLite can hold the pointer.
		slot_err: runtime.Allocator_Error
		_, slot, inserted, slot_err = map_entry(&stmt.bound_blob_storage, i32(index))
		if slot_err != nil {
			delete(stored, allocator)
			return error_alloc("stmt_bind_blob", slot_err), false
		}
	}

	rc := raw.bind_blob64(
		stmt.handle,
		i32(index),
		data_ptr,
		raw.Uint64(len(value)),
		raw.STATIC,
	)
	if rc != raw.OK {
		delete(stored, allocator)
		if inserted {
			delete_key(&stmt.bound_blob_storage, i32(index))
		}
		return result_from_stmt(stmt^, int(rc))
	}

	stmt_release_text_slot(stmt, i32(index))
	if slot != nil {
		// SQLite no longer references the previous buffer for this slot.
		if !inserted {
			delete(slot^, allocator)
		}
		slot^ = stored
	} else {
		// Empty blobs bind the static sentinel and need no tracked storage.
		stmt_release_blob_slot(stmt, i32(index))
	}
	return error_none(), true
}

// stmt_bind_blob64 is the explicitly named 64-bit-length variant. Odin slices
// are int-sized, so stmt_bind_blob already uses sqlite3_bind_blob64.
stmt_bind_blob64 :: proc(stmt: ^Stmt, index: int, value: []u8) -> (Error, bool) {
	return stmt_bind_blob(stmt, index, value)
}

stmt_bind_zeroblob :: proc(stmt: ^Stmt, index: int, size: int) -> (Error, bool) {
	err, valid := stmt_bind_index_check(stmt, index)
	if !valid {
		return err, false
	}
	if size < 0 {
		err = error_from_stmt(stmt^, int(raw.RANGE))
		error_with_op(&err, "stmt_bind_zeroblob")
		error_with_context(&err, "zeroblob size must be non-negative")
		return err, false
	}
	return stmt_bind_zeroblob64(stmt, index, u64(size))
}

stmt_bind_zeroblob64 :: proc(stmt: ^Stmt, index: int, size: u64) -> (Error, bool) {
	err, valid := stmt_bind_index_check(stmt, index)
	if !valid {
		return err, false
	}

	rc := raw.bind_zeroblob64(stmt.handle, i32(index), raw.Uint64(size))
	if rc == raw.OK {
		stmt_release_bound_slot(stmt, i32(index))
	}
	return result_from_stmt(stmt^, int(rc))
}

stmt_param_count :: proc(stmt: Stmt) -> int {
	if stmt.handle == nil {
		return 0
	}

	return int(raw.bind_parameter_count(stmt.handle))
}

// stmt_param_index returns the 1-based index of the parameter called `name`,
// or 0 when there is none. A name containing a NUL byte matches nothing (it
// would otherwise be truncated and could match a different parameter).
stmt_param_index :: proc(stmt: Stmt, name: string) -> int {
	if stmt.handle == nil || name == "" || text_has_nul(name) {
		return 0
	}

	c_name := strings.clone_to_cstring(name)
	defer delete(c_name)

	return int(raw.bind_parameter_index(stmt.handle, c_name))
}

// stmt_param_name returns the textual name of parameter `index` ("?N",
// ":name", "@name", "$name") or "" for nameless `?` parameters.
//
// Lifetime: BORROWED from the statement; valid until the statement is
// finalized. Clone with `strings.clone` if you need it longer.
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

@(private)
stmt_bind_named_index :: proc(stmt: ^Stmt, name: string) -> (int, Error, bool) {
	if stmt == nil || stmt.handle == nil {
		err, _ := stmt_bind_error(Stmt{})
		return 0, err, false
	}
	if text_has_nul(name) {
		return 0, error_embedded_nul(DB{handle = stmt.db}, "stmt_bind_named", "parameter name", stmt.sql), false
	}
	index := stmt_param_index(stmt^, name)
	if index == 0 {
		return 0, error_from_stmt(stmt^, int(raw.RANGE)), false
	}
	return index, error_none(), true
}

stmt_bind_named_null :: proc(stmt: ^Stmt, name: string) -> (Error, bool) {
	index, err, ok := stmt_bind_named_index(stmt, name)
	if !ok {
		return err, false
	}
	return stmt_bind_null(stmt, index)
}

stmt_bind_named_i32 :: proc(stmt: ^Stmt, name: string, value: i32) -> (Error, bool) {
	index, err, ok := stmt_bind_named_index(stmt, name)
	if !ok {
		return err, false
	}
	return stmt_bind_i32(stmt, index, value)
}

stmt_bind_named_i64 :: proc(stmt: ^Stmt, name: string, value: i64) -> (Error, bool) {
	index, err, ok := stmt_bind_named_index(stmt, name)
	if !ok {
		return err, false
	}
	return stmt_bind_i64(stmt, index, value)
}

stmt_bind_named_f64 :: proc(stmt: ^Stmt, name: string, value: f64) -> (Error, bool) {
	index, err, ok := stmt_bind_named_index(stmt, name)
	if !ok {
		return err, false
	}
	return stmt_bind_f64(stmt, index, value)
}

stmt_bind_named_bool :: proc(stmt: ^Stmt, name: string, value: bool) -> (Error, bool) {
	index, err, ok := stmt_bind_named_index(stmt, name)
	if !ok {
		return err, false
	}
	return stmt_bind_bool(stmt, index, value)
}

stmt_bind_named_text :: proc(stmt: ^Stmt, name: string, value: string) -> (Error, bool) {
	index, err, ok := stmt_bind_named_index(stmt, name)
	if !ok {
		return err, false
	}
	return stmt_bind_text(stmt, index, value)
}

stmt_bind_named_blob :: proc(stmt: ^Stmt, name: string, value: []u8) -> (Error, bool) {
	index, err, ok := stmt_bind_named_index(stmt, name)
	if !ok {
		return err, false
	}
	return stmt_bind_blob(stmt, index, value)
}

stmt_bind_named :: proc(stmt: ^Stmt, name: string, arg: Bind_Arg) -> (Error, bool) {
	index, err, ok := stmt_bind_named_index(stmt, name)
	if !ok {
		return err, false
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
