package tests

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
		name    = "non-empty",
		payload = []u8{1, 2, 3},
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