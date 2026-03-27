package sqlite

import "core:fmt"
import "core:strings"
import raw "raw/generated"

blob_result_from_blob :: proc(blob: Blob, code: int) -> (Error, bool) {
	if is_ok(code) {
		return error_none(), true
	}

	err := error_from_db(DB{handle = blob.db}, code)
	err = error_with_op(err, "blob")
	err = error_with_context(
		err,
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
) -> (Blob, Error, bool) {
	if db.handle == nil {
		return Blob{}, error_with_op(error_from_db(db, int(raw.MISUSE)), "blob_open"), false
	}
	if schema == "" || table == "" || column == "" {
		err := error_with_op(error_from_db(db, int(raw.MISUSE)), "blob_open")
		err = error_with_context(err, "schema, table, and column must be non-empty")
		return Blob{}, err, false
	}

	c_schema := strings.clone_to_cstring(schema)
	defer delete(c_schema)

	c_table := strings.clone_to_cstring(table)
	defer delete(c_table)

	c_column := strings.clone_to_cstring(column)
	defer delete(c_column)

	blob := Blob{
		db          = db.handle,
		schema_name = strings.clone(schema),
		table_name  = strings.clone(table),
		column_name = strings.clone(column),
		rowid       = rowid,
		writeable   = flags == .ReadWrite,
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
		delete(blob.schema_name)
		delete(blob.table_name)
		delete(blob.column_name)

		err := error_with_op(error_from_db(db, int(rc)), "blob_open")
		err = error_with_context(
			err,
			fmt.tprintf("schema=%s table=%s column=%s", schema, table, column),
		)
		return Blob{}, err, false
	}

	if blob.handle == nil {
		delete(blob.schema_name)
		delete(blob.table_name)
		delete(blob.column_name)

		err := error_with_op(error_from_db(db, int(raw.ERROR)), "blob_open")
		err = error_with_context(
			err,
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

	delete(blob.schema_name)
	delete(blob.table_name)
	delete(blob.column_name)

	blob.handle = nil
	blob.db = nil
	blob.schema_name = ""
	blob.table_name = ""
	blob.column_name = ""
	blob.rowid = 0
	blob.writeable = false

	if rc != raw.OK {
		err := error_with_op(error_from_db(DB{}, int(rc)), "blob_close")
		return err, false
	}

	return error_none(), true
}

blob_bytes :: proc(blob: Blob) -> int {
	if blob.handle == nil {
		return 0
	}

	return int(raw.blob_bytes(blob.handle))
}

blob_reopen :: proc(blob: ^Blob, rowid: i64) -> (Error, bool) {
	if blob == nil || blob.handle == nil {
		return error_with_op(error_from_db(DB{}, int(raw.MISUSE)), "blob_reopen"), false
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
		return 0, error_with_op(error_from_db(DB{}, int(raw.MISUSE)), "blob_read_into"), false
	}
	if offset < 0 {
		err := error_with_op(error_from_db(DB{handle = blob.db}, int(raw.ERROR)), "blob_read_into")
		err = error_with_context(err, "offset must be >= 0")
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
		return nil, error_with_op(error_from_db(DB{}, int(raw.MISUSE)), "blob_read_all"), false
	}

	size := blob_bytes(blob)
	if size <= 0 {
		return []u8{}, error_none(), true
	}

	out := make([]u8, size, allocator)
	read_n, err, ok := blob_read_into(blob, out, 0)
	if !ok {
		delete(out, allocator)
		return nil, err, false
	}
	if read_n != size {
		delete(out, allocator)

		short_err := error_with_op(error_from_db(DB{handle = blob.db}, int(raw.ERROR)), "blob_read_all")
		short_err = error_with_context(short_err, "blob read returned fewer bytes than expected")
		return nil, short_err, false
	}

	return out, error_none(), true
}

blob_write :: proc(blob: Blob, data: []u8, offset: int = 0) -> (Error, bool) {
	if blob.handle == nil {
		return error_with_op(error_from_db(DB{}, int(raw.MISUSE)), "blob_write"), false
	}
	if !blob.writeable {
		err := error_with_op(error_from_db(DB{handle = blob.db}, int(raw.READONLY)), "blob_write")
		err = error_with_context(err, "blob handle was opened read-only")
		return err, false
	}
	if offset < 0 {
		err := error_with_op(error_from_db(DB{handle = blob.db}, int(raw.ERROR)), "blob_write")
		err = error_with_context(err, "offset must be >= 0")
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