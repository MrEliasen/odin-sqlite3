package sqlite

import "core:fmt"
import "core:reflect"
import raw "raw/generated"

row_mapping_op :: "stmt_scan_struct"
query_one_struct_op :: "db_query_one_struct"
query_optional_struct_op :: "db_query_optional_struct"
query_all_struct_op :: "db_query_all_struct"

// stmt_scan_struct maps the current row of `stmt` into `out` using reflection.
//
// Mapping:
// - fields map by exact column name by default
// - a field tag of the form `sqlite:"column_name"` overrides the source column name
// - supported destination field types are the explicit wrapper value types currently handled by
//   this package (integers, floats, bool, string, and []u8)
//
// Ownership:
// - when mapping `string` or `[]u8` fields, this proc copies SQLite column data using `allocator`
// - any copied field data written into `out` is owned by the caller
// - when `allocator` is a non-temporary allocator, the caller is responsible for releasing those
//   mapped fields when appropriate
//
// Lifetime:
// - copied `string` and `[]u8` fields remain valid independently of later `step/reset/finalize` calls
stmt_scan_struct :: proc(stmt: Stmt, out: ^$T, allocator := context.allocator) -> (Error, bool) {
	if out == nil {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, "output pointer must not be nil")
		return err, false
	}

	if stmt.handle == nil {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, "statement handle is not valid")
		return err, false
	}

	type_info := type_info_of(typeid_of(T))
	if type_info == nil {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, "type info not available for output type")
		return err, false
	}

	base_info := reflect.type_info_base(type_info)
	if !reflect.is_struct(base_info) {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, "output type must be a struct")
		return err, false
	}

	fields := reflect.struct_fields_zipped(typeid_of(T))
	for field in fields {
		column_name := row_mapping_field_column_name(field)
		if column_name == "" {
			continue
		}

		column_index, found := row_mapping_find_column_index(stmt, column_name)
		if !found {
			continue
		}

		assign_err, assign_ok := row_mapping_assign_field(out, field, stmt, column_index, allocator)
		if !assign_ok {
			return assign_err, false
		}
	}

	return error_none(), true
}

// db_query_one_struct prepares `sql`, requires exactly one row to be present, and maps that row
// into `out` using `stmt_scan_struct`.
//
// Ownership:
// - this proc follows the same ownership rules as `stmt_scan_struct`
// - when mapped fields include copied `string` or `[]u8` values, that copied memory is owned by
//   the caller through `out`
// - when `allocator` is a non-temporary allocator, the caller is responsible for releasing those
//   mapped fields when appropriate
db_query_one_struct :: proc(
	db: DB,
	sql: string,
	out: ^$T,
	flags: int = DEFAULT_PREPARE_FLAGS,
	allocator := context.allocator,
) -> (Error, bool) {
	stmt, err, ok := db_query_one(db, sql, flags)
	if !ok {
		err = error_with_op(err, query_one_struct_op)
		return err, false
	}
	defer stmt_finalize(&stmt)

	scan_err, scan_ok := stmt_scan_struct(stmt, out, allocator)
	if !scan_ok {
		scan_err = error_with_op(scan_err, query_one_struct_op)
		return scan_err, false
	}

	return error_none(), true
}

// db_query_optional_struct prepares `sql`, treats "no row" as a normal outcome, and when a row is
// present maps it into `out` using `stmt_scan_struct`.
//
// Ownership:
// - when a row is found, this proc follows the same ownership rules as `stmt_scan_struct`
// - copied `string` and `[]u8` field data written into `out` is owned by the caller
// - when no row is found, `out` is left unchanged
// - when `allocator` is a non-temporary allocator, the caller is responsible for releasing mapped
//   fields when appropriate
db_query_optional_struct :: proc(
	db: DB,
	sql: string,
	out: ^$T,
	flags: int = DEFAULT_PREPARE_FLAGS,
	allocator := context.allocator,
) -> (bool, Error, bool) {
	stmt, found, err, ok := db_query_optional(db, sql, flags)
	if !ok {
		err = error_with_op(err, query_optional_struct_op)
		return false, err, false
	}
	if !found {
		return false, error_none(), true
	}
	defer stmt_finalize(&stmt)

	scan_err, scan_ok := stmt_scan_struct(stmt, out, allocator)
	if !scan_ok {
		scan_err = error_with_op(scan_err, query_optional_struct_op)
		return false, scan_err, false
	}

	return true, error_none(), true
}

// db_query_all_struct prepares `sql`, maps every row into a value of `T`, and returns the results
// as a slice allocated with `allocator`.
//
// Ownership:
// - the returned slice itself is owned by the caller
// - when `T` contains mapped `string` or `[]u8` fields, those copied field values are also owned
//   by the caller
// - when `allocator` is a non-temporary allocator, the caller is responsible for releasing any
//   owned nested field data as appropriate and then releasing the returned slice itself
db_query_all_struct :: proc(
	db: DB,
	sql: string,
	$T: typeid,
	flags: int = DEFAULT_PREPARE_FLAGS,
	allocator := context.allocator,
) -> ([]T, Error, bool) {
	stmt, err, ok := db_query_all(db, sql, flags)
	if !ok {
		err = error_with_op(err, query_all_struct_op)
		return nil, err, false
	}
	defer stmt_finalize(&stmt)

	rows := make([dynamic]T, 0, 0, allocator)
	for {
		has_row, step_err, step_ok := stmt_next(stmt)
		if !step_ok {
			delete(rows)
			step_err = error_with_op(step_err, query_all_struct_op)
			return nil, step_err, false
		}
		if !has_row {
			break
		}

		row := T{}
		scan_err, scan_ok := stmt_scan_struct(stmt, &row, allocator)
		if !scan_ok {
			delete(rows)
			scan_err = error_with_op(scan_err, query_all_struct_op)
			return nil, scan_err, false
		}

		append(&rows, row)
	}

	return rows[:], error_none(), true
}

row_mapping_find_column_index :: proc(stmt: Stmt, column_name: string) -> (int, bool) {
	column_count := stmt_column_count(stmt)
	for i := 0; i < column_count; i += 1 {
		if stmt_column_name(stmt, i) == column_name {
			return i, true
		}
	}
	return 0, false
}

row_mapping_field_column_name :: proc(field: reflect.Struct_Field) -> string {
	tag_name, has_tag := reflect.struct_tag_lookup(field.tag, "sqlite")
	if has_tag && tag_name != "" {
		return tag_name
	}
	return field.name
}

row_mapping_assign_field :: proc(
	out: ^$T,
	field: reflect.Struct_Field,
	stmt: Stmt,
	column_index: int,
	allocator := context.allocator,
) -> (Error, bool) {
	field_ptr := row_mapping_field_pointer(out, field)
	if field_ptr == nil {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, row_mapping_field_error_context("field pointer could not be resolved", field, column_index))
		return err, false
	}

	field_info := reflect.type_info_base(field.type)
	if field_info == nil {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, row_mapping_field_error_context("field type info unavailable", field, column_index))
		return err, false
	}

	switch field_variant in field_info.variant {
	case reflect.Type_Info_Integer:
		return row_mapping_assign_integer(field_ptr, field_info, field_variant, stmt, field, column_index)
	case reflect.Type_Info_Float:
		return row_mapping_assign_float(field_ptr, field_info, stmt, field, column_index)
	case reflect.Type_Info_Boolean:
		return row_mapping_assign_bool(field_ptr, stmt, field, column_index)
	case reflect.Type_Info_String:
		return row_mapping_assign_string(field_ptr, field_variant, stmt, field, column_index, allocator)
	case reflect.Type_Info_Slice:
		return row_mapping_assign_slice(field_ptr, field_variant, stmt, field, column_index, allocator)
	case reflect.Type_Info_Named,
	     reflect.Type_Info_Rune,
	     reflect.Type_Info_Complex,
	     reflect.Type_Info_Quaternion,
	     reflect.Type_Info_Any,
	     reflect.Type_Info_Type_Id,
	     reflect.Type_Info_Pointer,
	     reflect.Type_Info_Multi_Pointer,
	     reflect.Type_Info_Procedure,
	     reflect.Type_Info_Array,
	     reflect.Type_Info_Enumerated_Array,
	     reflect.Type_Info_Dynamic_Array,
	     reflect.Type_Info_Parameters,
	     reflect.Type_Info_Struct,
	     reflect.Type_Info_Union,
	     reflect.Type_Info_Enum,
	     reflect.Type_Info_Map,
	     reflect.Type_Info_Bit_Set,
	     reflect.Type_Info_Simd_Vector,
	     reflect.Type_Info_Matrix,
	     reflect.Type_Info_Soa_Pointer,
	     reflect.Type_Info_Bit_Field:
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, row_mapping_field_error_context("unsupported destination field type", field, column_index))
		return err, false
	}

	err := error_from_stmt(stmt, int(raw.MISUSE))
	err = error_with_op(err, row_mapping_op)
	err = error_with_context(err, row_mapping_field_error_context("unsupported destination field type", field, column_index))
	return err, false
}

row_mapping_assign_integer :: proc(
	field_ptr: rawptr,
	field_info: ^reflect.Type_Info,
	field_variant: reflect.Type_Info_Integer,
	stmt: Stmt,
	field: reflect.Struct_Field,
	column_index: int,
) -> (Error, bool) {
	is_null := stmt_is_null(stmt, column_index)

	switch {
	case field_info.id == typeid_of(i8):
		value := i8(0)
		if !is_null {
			value = i8(stmt_get_i64(stmt, column_index))
		}
		(^i8)(field_ptr)^ = value
	case field_info.id == typeid_of(i16):
		value := i16(0)
		if !is_null {
			value = i16(stmt_get_i64(stmt, column_index))
		}
		(^i16)(field_ptr)^ = value
	case field_info.id == typeid_of(i32):
		value := i32(0)
		if !is_null {
			value = stmt_get_i32(stmt, column_index)
		}
		(^i32)(field_ptr)^ = value
	case field_info.id == typeid_of(i64):
		value := i64(0)
		if !is_null {
			value = stmt_get_i64(stmt, column_index)
		}
		(^i64)(field_ptr)^ = value
	case field_info.id == typeid_of(int):
		value := int(0)
		if !is_null {
			value = int(stmt_get_i64(stmt, column_index))
		}
		(^int)(field_ptr)^ = value
	case field_info.id == typeid_of(u8):
		value := u8(0)
		if !is_null {
			value = u8(stmt_get_i64(stmt, column_index))
		}
		(^u8)(field_ptr)^ = value
	case field_info.id == typeid_of(u16):
		value := u16(0)
		if !is_null {
			value = u16(stmt_get_i64(stmt, column_index))
		}
		(^u16)(field_ptr)^ = value
	case field_info.id == typeid_of(u32):
		value := u32(0)
		if !is_null {
			value = u32(stmt_get_i64(stmt, column_index))
		}
		(^u32)(field_ptr)^ = value
	case field_info.id == typeid_of(u64):
		value := u64(0)
		if !is_null {
			value = u64(stmt_get_i64(stmt, column_index))
		}
		(^u64)(field_ptr)^ = value
	case field_info.id == typeid_of(uint):
		value := uint(0)
		if !is_null {
			value = uint(stmt_get_i64(stmt, column_index))
		}
		(^uint)(field_ptr)^ = value
	case:
		sign_desc := "unsigned"
		if field_variant.signed {
			sign_desc = "signed"
		}
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, fmt.tprintf(
			"field=%s column=%s column_index=%d detail=unsupported %s integer field type",
			field.name,
			row_mapping_field_column_name(field),
			column_index,
			sign_desc,
		))
		return err, false
	}

	return error_none(), true
}

row_mapping_assign_float :: proc(
	field_ptr: rawptr,
	field_info: ^reflect.Type_Info,
	stmt: Stmt,
	field: reflect.Struct_Field,
	column_index: int,
) -> (Error, bool) {
	is_null := stmt_is_null(stmt, column_index)

	switch {
	case field_info.id == typeid_of(f32):
		value := f32(0)
		if !is_null {
			value = f32(stmt_get_f64(stmt, column_index))
		}
		(^f32)(field_ptr)^ = value
	case field_info.id == typeid_of(f64):
		value := f64(0)
		if !is_null {
			value = stmt_get_f64(stmt, column_index)
		}
		(^f64)(field_ptr)^ = value
	case:
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, row_mapping_field_error_context("unsupported float field type", field, column_index))
		return err, false
	}

	return error_none(), true
}

row_mapping_assign_bool :: proc(
	field_ptr: rawptr,
	stmt: Stmt,
	field: reflect.Struct_Field,
	column_index: int,
) -> (Error, bool) {
	value := false
	if !stmt_is_null(stmt, column_index) {
		value = stmt_get_bool(stmt, column_index)
	}

	(^bool)(field_ptr)^ = value
	return error_none(), true
}

row_mapping_assign_string :: proc(
	field_ptr: rawptr,
	field_variant: reflect.Type_Info_String,
	stmt: Stmt,
	field: reflect.Struct_Field,
	column_index: int,
	allocator := context.allocator,
) -> (Error, bool) {
	if field_variant.is_cstring {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, row_mapping_field_error_context("cstring fields are not supported by struct row mapping", field, column_index))
		return err, false
	}

	value := ""
	if !stmt_is_null(stmt, column_index) {
		value = stmt_get_text(stmt, column_index, allocator)
	}

	(^string)(field_ptr)^ = value
	return error_none(), true
}

row_mapping_assign_slice :: proc(
	field_ptr: rawptr,
	field_variant: reflect.Type_Info_Slice,
	stmt: Stmt,
	field: reflect.Struct_Field,
	column_index: int,
	allocator := context.allocator,
) -> (Error, bool) {
	elem_info := reflect.type_info_base(field_variant.elem)
	if elem_info == nil || elem_info.id != typeid_of(u8) {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		err = error_with_op(err, row_mapping_op)
		err = error_with_context(err, row_mapping_field_error_context("only []u8 slice fields are supported", field, column_index))
		return err, false
	}

	value := ([]u8)(nil)
	if !stmt_is_null(stmt, column_index) {
		value = stmt_get_blob(stmt, column_index, allocator)
	}

	(^[]u8)(field_ptr)^ = value
	return error_none(), true
}

row_mapping_field_pointer :: proc(out: ^$T, field: reflect.Struct_Field) -> rawptr {
	return rawptr(uintptr(rawptr(out)) + field.offset)
}

row_mapping_field_error_context :: proc(message: string, field: reflect.Struct_Field, column_index: int) -> string {
	column_name := row_mapping_field_column_name(field)
	if column_name == "" {
		column_name = field.name
	}

	return fmt.tprintf(
		"field=%s column=%s column_index=%d detail=%s",
		field.name,
		column_name,
		column_index,
		message,
	)
}

