package sqlite

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
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
// - `using inner: Inner` (embedded) struct fields are walked recursively; their fields map by
//   their own names/tags against the same column set
//
// Range checking:
// - integer columns that do not fit the destination field type return an Error with
//   code = `raw.MISMATCH` and a context message naming field, column and value
// - assigning a negative i64 column to an unsigned destination field is also rejected with
//   `raw.MISMATCH`
//
// Ownership:
// - when mapping `string` or `[]u8` fields, this proc copies SQLite column data using `allocator`
// - any copied field data written into `out` is owned by the caller
// - when `allocator` is a non-temporary allocator, the caller is responsible for releasing those
//   mapped fields when appropriate
// - decoding is transactional: any failure leaves all of `out` unchanged
// - by default, a non-empty mapped string/[]u8 destination is rejected because
//   its ownership cannot be inferred; pass .Delete_Existing only when those
//   mapped values were allocated by `allocator`
//
// Lifetime:
// - copied `string` and `[]u8` fields remain valid independently of later `step/reset/finalize` calls
stmt_scan_struct :: proc(
	stmt: Stmt,
	out: ^$T,
	allocator := context.allocator,
	replace_mode: Row_Replace_Mode = .Reject_Non_Empty,
) -> (Error, bool) {
	if out == nil {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, "output pointer must not be nil")
		return err, false
	}

	if stmt.handle == nil {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, "statement handle is not valid")
		return err, false
	}

	type_info := type_info_of(typeid_of(T))
	if type_info == nil {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, "type info not available for output type")
		return err, false
	}

	base_info := reflect.type_info_base(type_info)
	if !reflect.is_struct(base_info) {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, "output type must be a struct")
		return err, false
	}

	column_index_by_name := row_mapping_build_column_index(stmt, context.temp_allocator)
	defer row_mapping_destroy_column_index(column_index_by_name, context.temp_allocator)

	// Decode into a zeroed temporary so neither partial scalar writes nor
	// newly allocated fields can mutate/free caller memory on failure.
	temp := T{}
	err, ok := row_mapping_assign_struct(rawptr(&temp), base_info, stmt, column_index_by_name, allocator)
	if !ok {
		row_mapping_free_struct_owned(rawptr(&temp), base_info, allocator)
		return err, false
	}

	err, ok = row_mapping_preflight_commit(rawptr(out), base_info, stmt, column_index_by_name, replace_mode)
	if !ok {
		row_mapping_free_struct_owned(rawptr(&temp), base_info, allocator)
		return err, false
	}

	row_mapping_commit_struct(rawptr(out), rawptr(&temp), base_info, column_index_by_name, allocator, replace_mode)

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
// - on mid-row scan failure any field memory copied into `out` is freed before returning
db_query_one_struct :: proc(
	db: DB,
	sql: string,
	out: ^$T,
	flags: int = DEFAULT_PREPARE_FLAGS,
	allocator := context.allocator,
	replace_mode: Row_Replace_Mode = .Reject_Non_Empty,
) -> (Error, bool) {
	stmt, err, ok := db_query_one(db, sql, flags)
	if !ok {
		error_with_op(&err, query_one_struct_op)
		return err, false
	}
	defer stmt_finalize_cleanup(&stmt)

	scan_err, scan_ok := stmt_scan_struct(stmt, out, allocator, replace_mode)
	if !scan_ok {
		error_with_op(&scan_err, query_one_struct_op)
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
// - on mid-row scan failure any field memory copied into `out` is freed before returning
db_query_optional_struct :: proc(
	db: DB,
	sql: string,
	out: ^$T,
	flags: int = DEFAULT_PREPARE_FLAGS,
	allocator := context.allocator,
	replace_mode: Row_Replace_Mode = .Reject_Non_Empty,
) -> (bool, Error, bool) {
	stmt, found, err, ok := db_query_optional(db, sql, flags)
	if !ok {
		error_with_op(&err, query_optional_struct_op)
		return false, err, false
	}
	if !found {
		return false, error_none(), true
	}
	defer stmt_finalize_cleanup(&stmt)

	scan_err, scan_ok := stmt_scan_struct(stmt, out, allocator, replace_mode)
	if !scan_ok {
		error_with_op(&scan_err, query_optional_struct_op)
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
// - if step or scan fails mid-iteration, all previously appended rows have their copied field
//   memory freed and the dynamic array itself is released before this proc returns
db_query_all_struct :: proc(
	db: DB,
	sql: string,
	$T: typeid,
	flags: int = DEFAULT_PREPARE_FLAGS,
	allocator := context.allocator,
) -> ([]T, Error, bool) {
	stmt, err, ok := db_query_all(db, sql, flags)
	if !ok {
		error_with_op(&err, query_all_struct_op)
		return nil, err, false
	}
	defer stmt_finalize_cleanup(&stmt)

	type_info := type_info_of(typeid_of(T))
	base_info := reflect.type_info_base(type_info)
	if base_info == nil || !reflect.is_struct(base_info) {
		err2 := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err2, query_all_struct_op)
		error_with_context(&err2, "output type must be a struct")
		return nil, err2, false
	}

	// Precompute the column-name → index map once per query rather than re-scanning column names
	// for every field of every row.
	column_index_by_name := row_mapping_build_column_index(stmt, context.temp_allocator)
	defer row_mapping_destroy_column_index(column_index_by_name, context.temp_allocator)

	rows := make([dynamic]T, 0, 0, allocator)
	for {
		has_row, step_err, step_ok := stmt_next(stmt)
		if !step_ok {
			row_mapping_free_rows(&rows, base_info, allocator)
			delete(rows)
			error_with_op(&step_err, query_all_struct_op)
			return nil, step_err, false
		}
		if !has_row {
			break
		}

		row := T{}
		scan_err, scan_ok := row_mapping_assign_struct(rawptr(&row), base_info, stmt, column_index_by_name, allocator)
		if !scan_ok {
			// Free this row's partial owned data, then free all previously appended rows.
			row_mapping_free_struct_owned(rawptr(&row), base_info, allocator)
			row_mapping_free_rows(&rows, base_info, allocator)
			delete(rows)
			error_with_op(&scan_err, query_all_struct_op)
			return nil, scan_err, false
		}

		append(&rows, row)
	}

	return rows[:], error_none(), true
}

// row_mapping_build_column_index returns a freshly allocated `map[string]int` from
// SQLite column name → column index for `stmt`. Keys are owned clones allocated
// with `allocator`, so they remain valid if SQLite automatically re-prepares the
// statement during the first step. Release the result with
// `row_mapping_destroy_column_index` and the same allocator.
row_mapping_build_column_index :: proc(stmt: Stmt, allocator := context.temp_allocator) -> map[string]int {
	out: map[string]int
	column_count := stmt_column_count(stmt)
	if column_count <= 0 {
		return out
	}
	out = make(map[string]int, column_count, allocator)
	for i := 0; i < column_count; i += 1 {
		name := stmt_column_name(stmt, i)
		if name == "" {
			continue
		}
		// First occurrence wins to match the previous linear-scan behaviour.
		if _, exists := out[name]; !exists {
			owned_name := strings.clone(name, allocator)
			out[owned_name] = i
		}
	}
	return out
}

// row_mapping_destroy_column_index releases both the map storage and every
// cloned key. `allocator` must be the allocator used to build the index.
row_mapping_destroy_column_index :: proc(by_name: map[string]int, allocator := context.temp_allocator) {
	for key, _ in by_name {
		delete(key, allocator)
	}
	delete(by_name)
}

row_mapping_lookup_column_index :: proc(by_name: map[string]int, column_name: string) -> (int, bool) {
	idx, found := by_name[column_name]
	return idx, found
}

// row_mapping_assign_struct walks the fields of the struct described by `struct_info` rooted at
// `base_ptr`, mapping each to a column from `column_index_by_name`. `using` (embedded) struct
// fields are recursed with the base pointer adjusted by the outer field offset; their inner
// offsets stack on top so the final field pointer is `base + outer.offset + inner.offset`.
//
// On error, the caller is responsible for freeing any owned data already written into the
// struct. `stmt_scan_struct` and `db_query_all_struct` do this via
// `row_mapping_free_struct_owned`.
row_mapping_assign_struct :: proc(
	base_ptr: rawptr,
	struct_info: ^reflect.Type_Info,
	stmt: Stmt,
	column_index_by_name: map[string]int,
	allocator: runtime.Allocator,
) -> (Error, bool) {
	if base_ptr == nil || struct_info == nil {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, "internal: nil struct pointer or type info")
		return err, false
	}

	if !reflect.is_struct(struct_info) {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, "output type must be a struct")
		return err, false
	}

	fields := reflect.struct_fields_zipped(struct_info.id)
	for field in fields {
		field_info := reflect.type_info_base(field.type)
		if field_info == nil {
			err := error_from_stmt(stmt, int(raw.MISUSE))
			error_with_op(&err, row_mapping_op)
			error_with_context(&err, row_mapping_field_error_context("field type info unavailable", field, -1))
			return err, false
		}

		field_ptr := rawptr(uintptr(base_ptr) + field.offset)

		// `using inner: Inner_Struct` recurses into the inner struct using the same column set.
		if field.is_using && reflect.is_struct(field_info) {
			inner_err, inner_ok := row_mapping_assign_struct(field_ptr, field_info, stmt, column_index_by_name, allocator)
			if !inner_ok {
				return inner_err, false
			}
			continue
		}

		column_name := row_mapping_field_column_name(field)
		if column_name == "" {
			continue
		}

		column_index, found := row_mapping_lookup_column_index(column_index_by_name, column_name)
		if !found {
			continue
		}

		assign_err, assign_ok := row_mapping_assign_field_typed(field_ptr, field_info, field, stmt, column_index, allocator)
		if !assign_ok {
			return assign_err, false
		}
	}

	return error_none(), true
}

// Validate the ownership-sensitive part of a commit before changing any
// destination field. This makes the default replacement policy atomic too.
row_mapping_preflight_commit :: proc(
	dst_ptr: rawptr,
	struct_info: ^reflect.Type_Info,
	stmt: Stmt,
	column_index_by_name: map[string]int,
	replace_mode: Row_Replace_Mode,
) -> (Error, bool) {
	fields := reflect.struct_fields_zipped(struct_info.id)
	for field in fields {
		field_info := reflect.type_info_base(field.type)
		if field_info == nil {
			continue
		}
		field_ptr := rawptr(uintptr(dst_ptr) + field.offset)

		if field.is_using && reflect.is_struct(field_info) {
			err, ok := row_mapping_preflight_commit(field_ptr, field_info, stmt, column_index_by_name, replace_mode)
			if !ok {
				return err, false
			}
			continue
		}

		column_name := row_mapping_field_column_name(field)
		_, mapped := row_mapping_lookup_column_index(column_index_by_name, column_name)
		if !mapped || replace_mode == .Delete_Existing {
			continue
		}

		non_empty := false
		#partial switch field_variant in field_info.variant {
		case reflect.Type_Info_String:
			if !field_variant.is_cstring {
				non_empty = len((^string)(field_ptr)^) > 0
			}
		case reflect.Type_Info_Slice:
			elem_info := reflect.type_info_base(field_variant.elem)
			if elem_info != nil && elem_info.id == typeid_of(u8) {
				non_empty = len((^[]u8)(field_ptr)^) > 0
			}
		}

		if non_empty {
			err := error_from_stmt(stmt, int(raw.MISUSE))
			error_with_op(&err, row_mapping_op)
			error_with_context(&err, row_mapping_field_error_context(
				"destination already contains data; pass Row_Replace_Mode.Delete_Existing only when it is owned by the supplied allocator",
				field,
				-1,
			))
			return err, false
		}
	}

	return error_none(), true
}

// Commit only fields that have matching result columns. Newly decoded string
// and blob allocations move from src to dst; src is a stack value and has no
// automatic destructor.
row_mapping_commit_struct :: proc(
	dst_ptr: rawptr,
	src_ptr: rawptr,
	struct_info: ^reflect.Type_Info,
	column_index_by_name: map[string]int,
	allocator: runtime.Allocator,
	replace_mode: Row_Replace_Mode,
) {
	fields := reflect.struct_fields_zipped(struct_info.id)
	for field in fields {
		field_info := reflect.type_info_base(field.type)
		if field_info == nil {
			continue
		}

		dst_field := rawptr(uintptr(dst_ptr) + field.offset)
		src_field := rawptr(uintptr(src_ptr) + field.offset)
		if field.is_using && reflect.is_struct(field_info) {
			row_mapping_commit_struct(dst_field, src_field, field_info, column_index_by_name, allocator, replace_mode)
			continue
		}

		column_name := row_mapping_field_column_name(field)
		_, mapped := row_mapping_lookup_column_index(column_index_by_name, column_name)
		if !mapped {
			continue
		}

		if replace_mode == .Delete_Existing {
			#partial switch field_variant in field_info.variant {
			case reflect.Type_Info_String:
				if !field_variant.is_cstring {
					old := (^string)(dst_field)
					if len(old^) > 0 {
						delete(old^, allocator)
					}
				}
			case reflect.Type_Info_Slice:
				elem_info := reflect.type_info_base(field_variant.elem)
				if elem_info != nil && elem_info.id == typeid_of(u8) {
					old := (^[]u8)(dst_field)
					if len(old^) > 0 {
						delete(old^, allocator)
					}
				}
			}
		}

		mem.copy_non_overlapping(dst_field, src_field, field_info.size)
	}
}

// row_mapping_free_struct_owned walks the fields of `struct_info` rooted at `base_ptr` and frees
// any `string` or `[]u8` field memory using `allocator`. Empty values (`len == 0`) are skipped so
// the empty-text / nil-blob sentinels do not produce double frees. After freeing, the field is
// reset to its zero value so calling this proc twice is safe.
//
// The walk mirrors `row_mapping_assign_struct`: `using` embedded structs are recursed.
row_mapping_free_struct_owned :: proc(
	base_ptr: rawptr,
	struct_info: ^reflect.Type_Info,
	allocator: runtime.Allocator,
) {
	if base_ptr == nil || struct_info == nil {
		return
	}
	if !reflect.is_struct(struct_info) {
		return
	}

	fields := reflect.struct_fields_zipped(struct_info.id)
	for field in fields {
		field_info := reflect.type_info_base(field.type)
		if field_info == nil {
			continue
		}

		field_ptr := rawptr(uintptr(base_ptr) + field.offset)

		if field.is_using && reflect.is_struct(field_info) {
			row_mapping_free_struct_owned(field_ptr, field_info, allocator)
			continue
		}

		#partial switch field_variant in field_info.variant {
		case reflect.Type_Info_String:
			if field_variant.is_cstring {
				continue
			}
			s_ptr := (^string)(field_ptr)
			if len(s_ptr^) > 0 {
				delete(s_ptr^, allocator)
			}
			s_ptr^ = ""
		case reflect.Type_Info_Slice:
			elem_info := reflect.type_info_base(field_variant.elem)
			if elem_info == nil || elem_info.id != typeid_of(u8) {
				continue
			}
			b_ptr := (^[]u8)(field_ptr)
			if len(b_ptr^) > 0 {
				delete(b_ptr^, allocator)
			}
			b_ptr^ = nil
		}
	}
}

// row_mapping_free_rows frees the owned string/[]u8 fields of every element currently appended
// to `rows`. It does NOT free `rows` itself; the caller must call `delete(rows^)` afterwards.
row_mapping_free_rows :: proc(
	rows: ^$D/[dynamic]$T,
	struct_info: ^reflect.Type_Info,
	allocator: runtime.Allocator,
) {
	if rows == nil {
		return
	}
	for i := 0; i < len(rows); i += 1 {
		row_mapping_free_struct_owned(rawptr(&rows[i]), struct_info, allocator)
	}
}

// row_mapping_assign_field_typed dispatches by field type-info variant. The caller has already
// resolved `field_ptr` and `field_info`. This proc never copies owned strings unless the
// destination field type accepts them; the helpers it calls write directly into `field_ptr`.
row_mapping_assign_field_typed :: proc(
	field_ptr: rawptr,
	field_info: ^reflect.Type_Info,
	field: reflect.Struct_Field,
	stmt: Stmt,
	column_index: int,
	allocator: runtime.Allocator,
) -> (Error, bool) {
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
	     reflect.Type_Info_Fixed_Capacity_Dynamic_Array,
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
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, row_mapping_field_error_context("unsupported destination field type", field, column_index))
		return err, false
	}

	err := error_from_stmt(stmt, int(raw.MISUSE))
	error_with_op(&err, row_mapping_op)
	error_with_context(&err, row_mapping_field_error_context("unsupported destination field type", field, column_index))
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
			v := stmt_get_i64(stmt, column_index)
			if v < i64(min(i8)) || v > i64(max(i8)) {
				return row_mapping_integer_range_error(stmt, field, column_index, v, "i8", i64(min(i8)), i64(max(i8))), false
			}
			value = i8(v)
		}
		(^i8)(field_ptr)^ = value
	case field_info.id == typeid_of(i16):
		value := i16(0)
		if !is_null {
			v := stmt_get_i64(stmt, column_index)
			if v < i64(min(i16)) || v > i64(max(i16)) {
				return row_mapping_integer_range_error(stmt, field, column_index, v, "i16", i64(min(i16)), i64(max(i16))), false
			}
			value = i16(v)
		}
		(^i16)(field_ptr)^ = value
	case field_info.id == typeid_of(i32):
		value := i32(0)
		if !is_null {
			v := stmt_get_i64(stmt, column_index)
			if v < i64(min(i32)) || v > i64(max(i32)) {
				return row_mapping_integer_range_error(stmt, field, column_index, v, "i32", i64(min(i32)), i64(max(i32))), false
			}
			value = i32(v)
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
			v := stmt_get_i64(stmt, column_index)
			when size_of(int) < size_of(i64) {
				if v < i64(min(int)) || v > i64(max(int)) {
					return row_mapping_integer_range_error(stmt, field, column_index, v, "int", i64(min(int)), i64(max(int))), false
				}
			}
			value = int(v)
		}
		(^int)(field_ptr)^ = value
	case field_info.id == typeid_of(u8):
		value := u8(0)
		if !is_null {
			v := stmt_get_i64(stmt, column_index)
			if v < 0 || v > i64(max(u8)) {
				return row_mapping_integer_range_error(stmt, field, column_index, v, "u8", 0, i64(max(u8))), false
			}
			value = u8(v)
		}
		(^u8)(field_ptr)^ = value
	case field_info.id == typeid_of(u16):
		value := u16(0)
		if !is_null {
			v := stmt_get_i64(stmt, column_index)
			if v < 0 || v > i64(max(u16)) {
				return row_mapping_integer_range_error(stmt, field, column_index, v, "u16", 0, i64(max(u16))), false
			}
			value = u16(v)
		}
		(^u16)(field_ptr)^ = value
	case field_info.id == typeid_of(u32):
		value := u32(0)
		if !is_null {
			v := stmt_get_i64(stmt, column_index)
			if v < 0 || v > i64(max(u32)) {
				return row_mapping_integer_range_error(stmt, field, column_index, v, "u32", 0, i64(max(u32))), false
			}
			value = u32(v)
		}
		(^u32)(field_ptr)^ = value
	case field_info.id == typeid_of(u64):
		value := u64(0)
		if !is_null {
			v := stmt_get_i64(stmt, column_index)
			if v < 0 {
				return row_mapping_integer_range_error(stmt, field, column_index, v, "u64", 0, i64(max(i64))), false
			}
			value = u64(v)
		}
		(^u64)(field_ptr)^ = value
	case field_info.id == typeid_of(uint):
		value := uint(0)
		if !is_null {
			v := stmt_get_i64(stmt, column_index)
			if v < 0 {
				return row_mapping_integer_range_error(stmt, field, column_index, v, "uint", 0, i64(max(i64))), false
			}
			when size_of(uint) < size_of(i64) {
				if u64(v) > u64(max(uint)) {
					return row_mapping_integer_range_error(stmt, field, column_index, v, "uint", 0, i64(max(uint))), false
				}
			}
			value = uint(v)
		}
		(^uint)(field_ptr)^ = value
	case:
		sign_desc := "unsigned"
		if field_variant.signed {
			sign_desc = "signed"
		}
		err := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, fmt.tprintf(
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

row_mapping_integer_range_error :: proc(
	stmt: Stmt,
	field: reflect.Struct_Field,
	column_index: int,
	value: i64,
	target_type: string,
	min_val: i64,
	max_val: i64,
) -> Error {
	err := error_from_stmt(stmt, int(raw.MISMATCH))
	error_with_op(&err, row_mapping_op)
	error_with_context(&err, fmt.tprintf(
		"field=%s column=%s column_index=%d detail=value %d does not fit %s (range %d..%d)",
		field.name,
		row_mapping_field_column_name(field),
		column_index,
		value,
		target_type,
		min_val,
		max_val,
	))
	return err
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
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, row_mapping_field_error_context("unsupported float field type", field, column_index))
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
	allocator: runtime.Allocator,
) -> (Error, bool) {
	if field_variant.is_cstring {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, row_mapping_field_error_context("cstring fields are not supported by struct row mapping", field, column_index))
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
	allocator: runtime.Allocator,
) -> (Error, bool) {
	elem_info := reflect.type_info_base(field_variant.elem)
	if elem_info == nil || elem_info.id != typeid_of(u8) {
		err := error_from_stmt(stmt, int(raw.MISUSE))
		error_with_op(&err, row_mapping_op)
		error_with_context(&err, row_mapping_field_error_context("only []u8 slice fields are supported", field, column_index))
		return err, false
	}

	value := ([]u8)(nil)
	if !stmt_is_null(stmt, column_index) {
		value = stmt_get_blob(stmt, column_index, allocator)
	}

	(^[]u8)(field_ptr)^ = value
	return error_none(), true
}

// row_mapping_find_column_index performs a linear column-name lookup. Retained for callers that
// don't have a precomputed index map; `db_query_all_struct` and `stmt_scan_struct` use the
// hoisted-map path instead.
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
