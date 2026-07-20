package tests

import "core:mem"
import "core:strings"
import sqlite "../sqlite"

Row_User_Basic :: struct {
	id:     i64,
	name:   string,
	active: bool,
	score:  f64,
}

Row_Query_All_User :: struct {
	id:   i64,
	name: string,
}

Row_Query_Optional_User :: struct {
	id:   i64,
	name: string,
}

Row_User_Tagged :: struct {
	id:           i64,
	display_name: string `sqlite:"user_name"`,
	active:       bool   `sqlite:"is_active"`,
}

Row_User_Partial :: struct {
	id:      i64,
	missing: string,
}

Row_User_Nulls :: struct {
	id:      i64,
	name:    string,
	payload: []u8,
	score:   f64,
	active:  bool,
}

Row_User_Unsupported :: struct {
	id:   i64,
	meta: struct {
		value: i64,
	},
}

Row_Inner_Sub :: struct {
	first: string,
	last:  string,
}

Row_User_With_Using :: struct {
	id:           i64,
	using person: Row_Inner_Sub,
	active:       bool,
}

Row_Small_Int :: struct {
	id:    i64,
	tiny:  i8,
	value: i64,
}

Row_With_String_And_Small_Int :: struct {
	id:    i64,
	name:  string,
	tiny:  i8,
}

Row_Replace_Owned :: struct {
	name:    string,
	payload: []u8,
}

test_row_mapping_by_field_name :: proc() {
	test_db := test_db_open("row_mapping_by_field_name")
	defer test_db_close(&test_db)

	sql := "SELECT 7 AS id, 'alice' AS name, 1 AS active, 9.5 AS score"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_User_Basic{}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	expect_no_error(err, ok, "stmt_scan_struct should map matching field names")

	expect_eq(row.id, i64(7), "field-name mapping should populate id")
	expect_eq(row.name, "alice", "field-name mapping should populate name")
	expect_true(row.active, "field-name mapping should populate bool field")
	expect_eq(row.score, 9.5, "field-name mapping should populate f64 field")
}

test_row_mapping_column_index_owns_keys_across_reprepare :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	tracked := mem.tracking_allocator(&tracker)

	test_db := test_db_open("row_mapping_column_index_owns_keys_across_reprepare")
	defer test_db_close(&test_db)
	exec_ok(test_db.db, "CREATE TABLE reprepare_rows(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	exec_ok(test_db.db, "INSERT INTO reprepare_rows(name) VALUES ('alpha')")

	other, open_err, open_ok := sqlite.db_open(test_db.path)
	expect_no_error(open_err, open_ok, "open second connection for schema change")
	defer {
		close_err, close_ok := sqlite.db_close(&other)
		expect_no_error(close_err, close_ok, "close second schema-change connection")
	}

	id_alias := "row_mapping_owned_identifier_column"
	name_alias := "row_mapping_owned_display_name_column"
	sql := "SELECT id AS row_mapping_owned_identifier_column, " +
		"name AS row_mapping_owned_display_name_column FROM reprepare_rows"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	borrowed_id := sqlite.stmt_column_name(stmt, 0)
	column_index := sqlite.row_mapping_build_column_index(stmt, tracked)
	owned_id := ""
	for key, _ in column_index {
		if key == id_alias {
			owned_id = key
		}
	}
	expect_eq(owned_id, id_alias, "column index should contain the first alias")
	expect_true(
		raw_data(owned_id) != raw_data(borrowed_id),
		"column-index keys must be cloned instead of borrowing SQLite metadata",
	)

	// Changing the schema after prepare forces sqlite3_step() to automatically
	// re-prepare this sqlite3_prepare_v2 statement, invalidating borrowed column
	// name pointers from the original prepared program.
	exec_ok(other, "ALTER TABLE reprepare_rows ADD COLUMN extra INTEGER")
	step_expect_row(stmt, sql)

	id_index, id_found := sqlite.row_mapping_lookup_column_index(column_index, id_alias)
	name_index, name_found := sqlite.row_mapping_lookup_column_index(column_index, name_alias)
	expect_true(id_found, "owned id key should survive automatic reprepare")
	expect_true(name_found, "owned name key should survive automatic reprepare")
	expect_eq(id_index, 0, "owned id key should retain its column index")
	expect_eq(name_index, 1, "owned name key should retain its column index")

	sqlite.row_mapping_destroy_column_index(column_index, tracked)
	expect_eq(len(tracker.allocation_map), 0, "destroying the column index must release its map and cloned keys")
	expect_eq(len(tracker.bad_free_array), 0, "destroying cloned column keys must not perform invalid frees")
}

test_row_mapping_by_struct_tag :: proc() {
	test_db := test_db_open("row_mapping_by_struct_tag")
	defer test_db_close(&test_db)

	sql := "SELECT 11 AS id, 'bravo' AS user_name, 0 AS is_active"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_User_Tagged{}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	expect_no_error(err, ok, "stmt_scan_struct should honor sqlite field tags")

	expect_eq(row.id, i64(11), "tag-based mapping should still map regular field names")
	expect_eq(row.display_name, "bravo", "tag-based mapping should populate renamed text field")
	expect_false(row.active, "tag-based mapping should populate renamed bool field")
}

test_row_mapping_unmatched_fields_are_ignored :: proc() {
	test_db := test_db_open("row_mapping_unmatched_fields_are_ignored")
	defer test_db_close(&test_db)

	sql := "SELECT 21 AS id"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_User_Partial{
		missing = "keep-me",
	}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	expect_no_error(err, ok, "stmt_scan_struct should ignore unmatched fields")

	expect_eq(row.id, i64(21), "matched field should still be populated")
	expect_eq(row.missing, "keep-me", "unmatched field should remain unchanged")
}

test_row_mapping_nulls_follow_wrapper_defaults :: proc() {
	test_db := test_db_open("row_mapping_nulls_follow_wrapper_defaults")
	defer test_db_close(&test_db)

	sql := "SELECT 31 AS id, NULL AS name, NULL AS payload, NULL AS score, NULL AS active"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_User_Nulls{
		score   = 4.5,
		active  = true,
	}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	expect_no_error(err, ok, "stmt_scan_struct should handle null columns")

	expect_eq(row.id, i64(31), "non-null column should still map normally")
	expect_eq(row.name, "", "NULL text should map to empty string")
	expect_true(row.payload == nil, "NULL blob should map to nil slice")
	expect_eq(row.score, 0.0, "NULL float should map to zero value")
	expect_false(row.active, "NULL integer/bool should map to false")
}

test_row_mapping_extra_columns_are_ignored :: proc() {
	test_db := test_db_open("row_mapping_extra_columns_are_ignored")
	defer test_db_close(&test_db)

	sql := "SELECT 41 AS id, 'delta' AS name, 1 AS active, 123 AS ignored_col, 'skip' AS another_ignored_col"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_User_Basic{}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	expect_no_error(err, ok, "stmt_scan_struct should ignore extra result columns")

	expect_eq(row.id, i64(41), "extra columns should not interfere with id mapping")
	expect_eq(row.name, "delta", "extra columns should not interfere with name mapping")
	expect_true(row.active, "extra columns should not interfere with active mapping")
}

test_row_mapping_requires_exact_name_without_tag :: proc() {
	test_db := test_db_open("row_mapping_requires_exact_name_without_tag")
	defer test_db_close(&test_db)

	sql := "SELECT 'echo' AS user_name"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_User_Partial{
		missing = "unchanged",
	}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	expect_no_error(err, ok, "stmt_scan_struct should not fail when no field matches a column")

	expect_eq(row.missing, "unchanged", "without a tag or exact field name match, field should remain unchanged")
}

test_row_mapping_unsupported_field_type_returns_error :: proc() {
	test_db := test_db_open("row_mapping_unsupported_field_type")
	defer test_db_close(&test_db)

	sql := "SELECT 51 AS id, 99 AS meta"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_User_Unsupported{}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	defer sqlite.error_destroy(&err)
	expect_false(ok, "stmt_scan_struct should fail for unsupported destination field types")
	expect_false(sqlite.error_ok(err), "unsupported field type should return a wrapper error")
	expect_string_contains(sqlite.error_string(err), "stmt_scan_struct", "unsupported mapping error should include operation context")
}

test_row_mapping_is_additive_to_explicit_getters :: proc() {
	test_db := test_db_open("row_mapping_is_additive_to_explicit_getters")
	defer test_db_close(&test_db)

	sql := "SELECT 61 AS id, 'foxtrot' AS name, 1 AS active, 7.25 AS score"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_User_Basic{}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	expect_no_error(err, ok, "stmt_scan_struct should succeed on a visible row")

	expect_eq(sqlite.stmt_get_i64(stmt, 0), i64(61), "explicit getter should still work after struct scan")
	expect_eq(sqlite.stmt_get_text(stmt, 1, context.temp_allocator), "foxtrot", "explicit text getter should still work after struct scan")
	expect_true(sqlite.stmt_get_bool(stmt, 2), "explicit bool getter should still work after struct scan")
	expect_eq(sqlite.stmt_get_f64(stmt, 3), 7.25, "explicit f64 getter should still work after struct scan")

	expect_eq(row.id, i64(61), "struct scan should map id")
	expect_eq(row.name, "foxtrot", "struct scan should map name")
	expect_true(row.active, "struct scan should map active")
	expect_eq(row.score, 7.25, "struct scan should map score")
}

test_struct_query_one_wrapper :: proc() {
	test_db := test_db_open("struct_query_one_wrapper")
	defer test_db_close(&test_db)

	row := Row_User_Basic{}
	err, ok := sqlite.db_query_one_struct(
		test_db.db,
		"SELECT 71 AS id, 'golf' AS name, 1 AS active, 4.25 AS score",
		&row,
		sqlite.DEFAULT_PREPARE_FLAGS,
		context.temp_allocator,
	)
	expect_no_error(err, ok, "db_query_one_struct should map a single row into the output struct")

	expect_eq(row.id, i64(71), "db_query_one_struct should populate id")
	expect_eq(row.name, "golf", "db_query_one_struct should populate name")
	expect_true(row.active, "db_query_one_struct should populate active")
	expect_eq(row.score, 4.25, "db_query_one_struct should populate score")
}

test_struct_query_optional_wrapper_found_and_missing :: proc() {
	test_db := test_db_open("struct_query_optional_wrapper_found_and_missing")
	defer test_db_close(&test_db)

	found_row := Row_Query_Optional_User{}
	found, err, ok := sqlite.db_query_optional_struct(
		test_db.db,
		"SELECT 81 AS id, 'hotel' AS name",
		&found_row,
		sqlite.DEFAULT_PREPARE_FLAGS,
		context.temp_allocator,
	)
	expect_no_error(err, ok, "db_query_optional_struct should succeed when a row exists")
	expect_true(found, "db_query_optional_struct should report found when a row exists")
	expect_eq(found_row.id, i64(81), "db_query_optional_struct should populate id on found row")
	expect_eq(found_row.name, "hotel", "db_query_optional_struct should populate name on found row")

	missing_row := Row_Query_Optional_User{
		id   = -1,
		name = "unchanged",
	}
	found, err, ok = sqlite.db_query_optional_struct(
		test_db.db,
		"SELECT 1 AS id, 'never-used' AS name WHERE 0",
		&missing_row,
		sqlite.DEFAULT_PREPARE_FLAGS,
		context.temp_allocator,
	)
	expect_no_error(err, ok, "db_query_optional_struct should succeed when no row exists")
	expect_false(found, "db_query_optional_struct should report not found when no row exists")
	expect_eq(missing_row.id, i64(-1), "db_query_optional_struct should leave output unchanged when no row exists")
	expect_eq(missing_row.name, "unchanged", "db_query_optional_struct should leave output unchanged when no row exists")
}

test_struct_query_all_wrapper :: proc() {
	test_db := test_db_open("struct_query_all_wrapper")
	defer test_db_close(&test_db)

	rows, err, ok := sqlite.db_query_all_struct(
		test_db.db,
		"SELECT 1 AS id, 'alpha' AS name UNION ALL SELECT 2 AS id, 'beta' AS name UNION ALL SELECT 3 AS id, 'gamma' AS name ORDER BY id",
		Row_Query_All_User,
		sqlite.DEFAULT_PREPARE_FLAGS,
		context.temp_allocator,
	)
	expect_no_error(err, ok, "db_query_all_struct should collect all rows into a slice")

	expect_eq(len(rows), 3, "db_query_all_struct should return all rows")
	expect_eq(rows[0].id, i64(1), "db_query_all_struct should populate first row id")
	expect_eq(rows[0].name, "alpha", "db_query_all_struct should populate first row name")
	expect_eq(rows[1].id, i64(2), "db_query_all_struct should populate second row id")
	expect_eq(rows[1].name, "beta", "db_query_all_struct should populate second row name")
	expect_eq(rows[2].id, i64(3), "db_query_all_struct should populate third row id")
	expect_eq(rows[2].name, "gamma", "db_query_all_struct should populate third row name")
}

test_row_mapping_using_inner_struct :: proc() {
	test_db := test_db_open("row_mapping_using_inner_struct")
	defer test_db_close(&test_db)

	sql := "SELECT 91 AS id, 'ada' AS first, 'lovelace' AS last, 1 AS active"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_User_With_Using{}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	expect_no_error(err, ok, "stmt_scan_struct should descend into `using` embedded struct fields")

	expect_eq(row.id, i64(91), "outer field should map")
	expect_eq(row.first, "ada", "inner `using` field `first` should map by name")
	expect_eq(row.last, "lovelace", "inner `using` field `last` should map by name")
	expect_true(row.active, "outer field after `using` should still map")
}

test_row_mapping_integer_range_error :: proc() {
	test_db := test_db_open("row_mapping_integer_range_error")
	defer test_db_close(&test_db)

	// 1000 is well outside the [-128, 127] range of i8.
	sql := "SELECT 1 AS id, 1000 AS tiny, 5 AS value"
	stmt := prepare_ok(test_db.db, sql)
	defer finalize_ok(&stmt, sql)

	step_expect_row(stmt, sql)

	row := Row_Small_Int{}
	err, ok := sqlite.stmt_scan_struct(stmt, &row, context.temp_allocator)
	defer sqlite.error_destroy(&err)

	expect_false(ok, "stmt_scan_struct should fail when i64 value does not fit i8")
	expect_eq(err.code, 20, "out-of-range integer should report SQLITE_MISMATCH (code 20)")
	expect_string_contains(sqlite.error_string(err), "does not fit i8", "range error should name the destination type")
	expect_string_contains(sqlite.error_string(err), "stmt_scan_struct", "range error should carry op context")
}

test_row_mapping_db_query_all_struct_leaves_no_leaks_on_error :: proc() {
	// Use a private tracking allocator so we can assert the post-error state ourselves.
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)

	tracked := mem.tracking_allocator(&tracker)

	test_db := test_db_open("row_mapping_db_query_all_struct_leaves_no_leaks_on_error")
	defer test_db_close(&test_db)

	// First two rows scan fine and copy strings into the tracking allocator. The third row
	// has tiny=999 which overflows i8 and triggers an error mid-iteration. The wrapper must
	// release every previously-appended row's string memory before returning.
	sql := "SELECT 1 AS id, 'aaa' AS name, 1 AS tiny UNION ALL " +
		"SELECT 2 AS id, 'bbb' AS name, 2 AS tiny UNION ALL " +
		"SELECT 3 AS id, 'ccc' AS name, 999 AS tiny"

	rows, err, ok := sqlite.db_query_all_struct(
		test_db.db,
		sql,
		Row_With_String_And_Small_Int,
		sqlite.DEFAULT_PREPARE_FLAGS,
		tracked,
	)
	defer sqlite.error_destroy(&err)

	expect_false(ok, "db_query_all_struct should fail when a row scan overflows")
	expect_true(rows == nil, "db_query_all_struct should not return rows on error")
	expect_eq(err.code, 20, "range error mid-iteration should report SQLITE_MISMATCH (code 20)")

	leak_count := len(tracker.allocation_map)
	bad_free_count := len(tracker.bad_free_array)
	expect_eq(leak_count, 0, "db_query_all_struct error path must free all per-row owned data")
	expect_eq(bad_free_count, 0, "db_query_all_struct error path must not double-free")
}

test_row_mapping_failure_leaves_preexisting_fields_untouched :: proc() {
	test_db := test_db_open("row_mapping_failure_leaves_preexisting_fields_untouched")
	defer test_db_close(&test_db)

	stmt := prepare_ok(test_db.db, "SELECT 1 AS id, 'new' AS name, 999 AS tiny")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	row := Row_With_String_And_Small_Int{id = 77, name = "borrowed", tiny = 7}
	err, ok := sqlite.stmt_scan_struct(stmt, &row)
	defer sqlite.error_destroy(&err)
	expect_false(ok, "overflow after decoding text should fail transactionally")
	expect_eq(row.id, i64(77), "failed scan must leave scalar fields unchanged")
	expect_eq(row.name, "borrowed", "failed scan must not free or overwrite borrowed caller text")
	expect_eq(row.tiny, i8(7), "failed scan must leave later fields unchanged")
}

test_row_mapping_replacement_contract_is_explicit_and_leak_free :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	tracked := mem.tracking_allocator(&tracker)

	test_db := test_db_open("row_mapping_replacement_contract_is_explicit_and_leak_free")
	defer test_db_close(&test_db)
	stmt := prepare_ok(test_db.db, "SELECT 'new' AS name, x'010203' AS payload")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	row := Row_Replace_Owned{
		name = strings.clone("old", tracked),
		payload = make([]u8, 2, tracked),
	}
	row.payload[0] = 9
	row.payload[1] = 8

	// The default refuses to guess ownership and leaves the destination intact.
	reject_err, reject_ok := sqlite.stmt_scan_struct(stmt, &row, tracked)
	defer sqlite.error_destroy(&reject_err)
	expect_false(reject_ok, "non-empty mapped owned fields require an explicit replacement mode")
	expect_eq(row.name, "old", "rejected replacement must leave existing text unchanged")
	expect_eq(row.payload[0], u8(9), "rejected replacement must leave existing blob unchanged")

	err, ok := sqlite.stmt_scan_struct(stmt, &row, tracked, .Delete_Existing)
	expect_no_error(err, ok, "explicit allocator-owned replacement should succeed")
	expect_eq(row.name, "new", "explicit replacement should install decoded text")
	expect_eq(len(row.payload), 3, "explicit replacement should install decoded blob")
	expect_eq(row.payload[2], u8(3), "decoded replacement blob should preserve bytes")

	delete(row.name, tracked)
	delete(row.payload, tracked)
	expect_eq(len(tracker.allocation_map), 0, "replacement should release old fields and caller cleanup should release new fields")
	expect_eq(len(tracker.bad_free_array), 0, "replacement contract must not free unrelated memory")
}
