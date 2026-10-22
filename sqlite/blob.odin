package sqlite

import "base:runtime"
import "core:fmt"
import "core:strings"
import raw "raw/generated"

blob_result_from_blob :: proc(blob: Blob, code: int) -> (Error, bool) {
	if is_ok(code) {
		return error_none(), true
	}

	err := error_from_db(DB{handle = blob.db}, code)
	error_with_op(&err, "blob")
	error_with_context(
		&err,
		fmt.tprintf("schema=%s table=%s column=%s", blob.schema_name, blob.table_name, blob.column_name),
	)
	return err, false
}

blob_open :: proc(
	db: DB,
	schema: string,
	table: string,
	column: string,
	rowid: i64,
	flags: Blob_Open_Flags = .ReadOnly,
	allocator := context.allocator,
) -> (Blob, Error, bool) {
	if db.handle == nil {
		err := error_from_db(db, int(raw.MISUSE))
		error_with_op(&err, "blob_open")
		return Blob{}, err, false
	}
	if schema == "" || table == "" || column == "" {
		err := error_from_db(db, int(raw.MISUSE))
		error_with_op(&err, "blob_open")
		error_with_context(&err, "schema, table, and column must be non-empty")
		return Blob{}, err, false
	}
	if text_has_nul(schema) || text_has_nul(table) || text_has_nul(column) {
		return Blob{}, error_embedded_nul(db, "blob_open", "schema, table, or column name"), false
	}

	// sqlite3_blob_open dereferences a nil table/column name (no API armor).
	c_schema, schema_err := strings.clone_to_cstring(schema)
	defer delete(c_schema)
	c_table, table_err := strings.clone_to_cstring(table)
	defer delete(c_table)
	c_column, column_err := strings.clone_to_cstring(column)
	defer delete(c_column)
	for alloc_err in ([3]runtime.Allocator_Error{schema_err, table_err, column_err}) {
		if alloc_err != nil {
			return Blob{}, error_alloc("blob_open", alloc_err), false
		}
	}

	// Name clones are diagnostics only; an allocation failure leaves them empty.
	blob := Blob{
		db          = db.handle,
		schema_name = strings.clone(schema, allocator),
		table_name  = strings.clone(table, allocator),
		column_name = strings.clone(column, allocator),
		rowid       = rowid,
		writeable   = flags == .ReadWrite,
		allocator   = allocator,
	}

	rc := raw.blob_open(
		db.handle,
		c_schema,
		c_table,
		c_column,
		raw.Int64(rowid),
		i32(flags),
		&blob.handle,
	)
	if rc != raw.OK {
		delete(blob.schema_name, allocator)
		delete(blob.table_name, allocator)
		delete(blob.column_name, allocator)

		err := error_from_db(db, int(rc))
		error_with_op(&err, "blob_open")
		error_with_context(
			&err,
			fmt.tprintf("schema=%s table=%s column=%s", schema, table, column),
		)
		return Blob{}, err, false
	}

	if blob.handle == nil {
		delete(blob.schema_name, allocator)
		delete(blob.table_name, allocator)
		delete(blob.column_name, allocator)

		err := error_from_db(db, int(raw.ERROR))
		error_with_op(&err, "blob_open")
		error_with_context(
			&err,
			fmt.tprintf("schema=%s table=%s column=%s", schema, table, column),
		)
		return Blob{}, err, false
	}

	return blob, error_none(), true
}

blob_close :: proc(blob: ^Blob) -> (Error, bool) {
	if blob == nil || blob.handle == nil {
		return error_none(), true
	}

	rc := raw.blob_close(blob.handle)
	close_err := error_none()
	close_ok := true
	if rc != raw.OK {
		// sqlite3_blob_close finalizes the blob's statement, which frees a
		// connection already closed with db_close (sqlite3_close_v2). The
		// connection must not be read, so build the error from the code.
		closed_blob := blob^
		closed_blob.db = nil
		close_err, close_ok = blob_result_from_blob(closed_blob, int(rc))
		error_with_op(&close_err, "blob_close")
	}

	allocator := owner_allocator(blob.allocator)
	delete(blob.schema_name, allocator)
	delete(blob.table_name, allocator)
	delete(blob.column_name, allocator)

	blob.handle = nil
	blob.db = nil
	blob.schema_name = ""
	blob.table_name = ""
	blob.column_name = ""
	blob.rowid = 0
	blob.writeable = false
	blob.allocator = {}

	return close_err, close_ok
}

blob_close_cleanup :: proc(blob: ^Blob) {
	err, _ := blob_close(blob)
	error_destroy(&err)
}

blob_bytes :: proc(blob: Blob) -> int {
	if blob.handle == nil {
		return 0
	}

	return int(raw.blob_bytes(blob.handle))
}

blob_reopen :: proc(blob: ^Blob, rowid: i64) -> (Error, bool) {
	if blob == nil || blob.handle == nil {
		err := error_from_db(DB{}, int(raw.MISUSE))
		error_with_op(&err, "blob_reopen")
		return err, false
	}

	rc := raw.blob_reopen(blob.handle, raw.Int64(rowid))
	if rc != raw.OK {
		return blob_result_from_blob(blob^, int(rc))
	}

	blob.rowid = rowid
	return error_none(), true
}

blob_read_into :: proc(blob: Blob, out: []u8, offset: int = 0) -> (int, Error, bool) {
	if blob.handle == nil {
		err := error_from_db(DB{}, int(raw.MISUSE))
		error_with_op(&err, "blob_read_into")
		return 0, err, false
	}
	if offset < 0 {
		err := error_from_db(DB{handle = blob.db}, int(raw.ERROR))
		error_with_op(&err, "blob_read_into")
		error_with_context(&err, "offset must be >= 0")
		return 0, err, false
	}
	if len(out) > int(max(i32)) || offset > int(max(i32)) {
		err := error_from_db(DB{handle = blob.db}, int(raw.TOOBIG))
		error_with_op(&err, "blob_read_into")
		error_with_context(&err, "len or offset exceeds 2 GiB; sqlite3_blob_read uses i32")
		return 0, err, false
	}
	if len(out) == 0 {
		return 0, error_none(), true
	}

	rc := raw.blob_read(blob.handle, rawptr(&out[0]), i32(len(out)), i32(offset))
	if rc != raw.OK {
		return 0, blob_result_from_blob(blob, int(rc))
	}

	return len(out), error_none(), true
}

// blob_read_all reads the full blob into a newly allocated slice using `allocator`.
//
// Ownership:
// - the returned slice is owned by the caller
// - when the returned slice is allocated from a non-temporary allocator, the caller is
//   responsible for releasing it with `delete(...)` when appropriate
//
// Lifetime:
// - the returned slice is a copy and remains valid independently of later blob handle operations
blob_read_all :: proc(blob: Blob, allocator := context.allocator) -> ([]u8, Error, bool) {
	if blob.handle == nil {
		err := error_from_db(DB{}, int(raw.MISUSE))
		error_with_op(&err, "blob_read_all")
		return nil, err, false
	}

	size := blob_bytes(blob)
	if size <= 0 {
		return []u8{}, error_none(), true
	}

	out, alloc_err := make([]u8, size, allocator)
	if alloc_err != nil {
		return nil, error_alloc("blob_read_all", alloc_err), false
	}
	read_n, err, ok := blob_read_into(blob, out, 0)
	if !ok {
		delete(out, allocator)
		return nil, err, false
	}
	if read_n != size {
		delete(out, allocator)

		short_err := error_from_db(DB{handle = blob.db}, int(raw.ERROR))
		error_with_op(&short_err, "blob_read_all")
		error_with_context(&short_err, "blob read returned fewer bytes than expected")
		return nil, short_err, false
	}

	return out, error_none(), true
}

blob_write :: proc(blob: Blob, data: []u8, offset: int = 0) -> (Error, bool) {
	if blob.handle == nil {
		err := error_from_db(DB{}, int(raw.MISUSE))
		error_with_op(&err, "blob_write")
		return err, false
	}
	if !blob.writeable {
		err := error_from_db(DB{handle = blob.db}, int(raw.READONLY))
		error_with_op(&err, "blob_write")
		error_with_context(&err, "blob handle was opened read-only")
		return err, false
	}
	if offset < 0 {
		err := error_from_db(DB{handle = blob.db}, int(raw.ERROR))
		error_with_op(&err, "blob_write")
		error_with_context(&err, "offset must be >= 0")
		return err, false
	}
	if len(data) > int(max(i32)) || offset > int(max(i32)) {
		err := error_from_db(DB{handle = blob.db}, int(raw.TOOBIG))
		error_with_op(&err, "blob_write")
		error_with_context(&err, "len or offset exceeds 2 GiB; sqlite3_blob_write uses i32")
		return err, false
	}
	if len(data) == 0 {
		return error_none(), true
	}

	rc := raw.blob_write(blob.handle, rawptr(&data[0]), i32(len(data)), i32(offset))
	if rc != raw.OK {
		err, ok := blob_result_from_blob(blob, int(rc))
		return err, ok
	}

	return error_none(), true
}
