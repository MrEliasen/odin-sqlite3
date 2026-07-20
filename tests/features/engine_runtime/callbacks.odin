package engine_runtime

import raw "../../../sqlite/raw/generated"

Function_State :: struct {
	scalar_calls: i32,
	destructor_calls: i32,
}

Aggregate_State :: struct {
	sum: i64,
	count: i32,
}

Collation_State :: struct {
	compare_calls: i32,
	destructor_calls: i32,
}

Authorizer_State :: struct {
	delete_actions: i32,
	deny_delete: bool,
}

scalar_twice_callback :: proc "c" (sqlite_context: ^raw.Context, argument_count: i32, arguments: ^^raw.Value) {
	state := (^Function_State)(raw.user_data(sqlite_context))
	if state != nil {
		state.scalar_calls += 1
	}
	if argument_count != 1 || arguments == nil {
		raw.result_error_code(sqlite_context, raw.MISUSE)
		return
	}
	value := arguments^
	if raw.value_type(value) == raw.NULL {
		raw.result_null(sqlite_context)
		return
	}
	raw.result_int64(sqlite_context, raw.Int64(i64(raw.value_int64(value)) * 2))
}

function_destructor_callback :: proc "c" (application_data: rawptr) {
	state := (^Function_State)(application_data)
	if state != nil {
		state.destructor_calls += 1
	}
}

aggregate_total_step_callback :: proc "c" (sqlite_context: ^raw.Context, argument_count: i32, arguments: ^^raw.Value) {
	if argument_count != 1 || arguments == nil {
		raw.result_error_code(sqlite_context, raw.MISUSE)
		return
	}
	memory := raw.aggregate_context(sqlite_context, i32(size_of(Aggregate_State)))
	if memory == nil {
		raw.result_error_nomem(sqlite_context)
		return
	}
	state := (^Aggregate_State)(memory)
	value := arguments^
	if raw.value_type(value) != raw.NULL {
		state.sum += i64(raw.value_int64(value))
		state.count += 1
	}
}

aggregate_total_final_callback :: proc "c" (sqlite_context: ^raw.Context) {
	memory := raw.aggregate_context(sqlite_context, 0)
	if memory == nil {
		raw.result_null(sqlite_context)
		return
	}
	state := (^Aggregate_State)(memory)
	if state.count == 0 {
		raw.result_null(sqlite_context)
		return
	}
	raw.result_int64(sqlite_context, raw.Int64(state.sum))
}

reverse_collation_callback :: proc "c" (
	application_data: rawptr,
	left_size: i32,
	left_pointer: rawptr,
	right_size: i32,
	right_pointer: rawptr,
) -> i32 {
	state := (^Collation_State)(application_data)
	if state != nil {
		state.compare_calls += 1
	}
	left := ([^]u8)(left_pointer)[:int(left_size)]
	right := ([^]u8)(right_pointer)[:int(right_size)]
	shared_size := len(left)
	if len(right) < shared_size {
		shared_size = len(right)
	}
	for index in 0 ..< shared_size {
		if left[index] < right[index] {
			return 1
		}
		if left[index] > right[index] {
			return -1
		}
	}
	if len(left) < len(right) {
		return 1
	}
	if len(left) > len(right) {
		return -1
	}
	return 0
}

collation_destructor_callback :: proc "c" (application_data: rawptr) {
	state := (^Collation_State)(application_data)
	if state != nil {
		state.destructor_calls += 1
	}
}

authorizer_callback :: proc "c" (
	application_data: rawptr,
	action_code: i32,
	first_detail: cstring,
	second_detail: cstring,
	database_name: cstring,
	trigger_name: cstring,
) -> i32 {
	_ = first_detail
	_ = second_detail
	_ = database_name
	_ = trigger_name
	state := (^Authorizer_State)(application_data)
	if state != nil && action_code == raw.DELETE {
		state.delete_actions += 1
		if state.deny_delete {
			return raw.DENY
		}
	}
	return raw.OK
}

// SQLITE-FEATURE-CONTRACT: engine.callbacks.scalar-aggregate-registration.v1
// Feature: Connection-local scalar and aggregate SQL function registration, NULL handling, application data, and destructor lifetime.
// SQLite source: input/sqlite3.h sections "Create Or Redefine SQL Functions", "Obtaining SQL Values", "Setting The Result Of An SQL Function", and "Aggregate Context".
// Requirement: Registered callbacks receive bound values and application data, scalar NULL handling is explicit, aggregate context is independently zero-initialized for every group, registrations are connection-local, and xDestroy runs on replacement and close.
// Adversarial cases: Scalar integer and NULL arguments, two distinguishable aggregate groups containing different values and NULL, empty aggregate input, use from an unregistered second connection, replacement of the same function signature, and connection teardown.
// Oracle: Ordered grouped totals of 3 and 30 plus an empty-input NULL prove independent aggregate contexts; scalar results, callback counters, independent-connection prepare failure, and exact destructor counts complete the callback oracle.
// Guardrail: Do not invoke callback procs directly as the oracle, assume global registration, allocate callback state in SQLite-private memory, or omit teardown verification.
test_scalar_aggregate_function_registration :: proc() {
	db := open_db(":memory:")
	function_state := Function_State{}
	function_flags := i32(raw.UTF8 | raw.DETERMINISTIC)
	expect_rc(
		raw.create_function_v2(
			db,
			"engine_twice",
			1,
			function_flags,
			rawptr(&function_state),
			scalar_twice_callback,
			nil,
			nil,
			function_destructor_callback,
		),
		raw.OK,
		"register scalar function",
	)
	expect_rc(
		raw.create_function_v2(
			db,
			"engine_total",
			1,
			i32(raw.UTF8),
			nil,
			nil,
			aggregate_total_step_callback,
			aggregate_total_final_callback,
			nil,
		),
		raw.OK,
		"register aggregate function",
	)

	scalar_statement := prepare_ok(db, "SELECT engine_twice(?1), engine_twice(?2)")
	bind_i64_ok(scalar_statement, 1, 21)
	bind_null_ok(scalar_statement, 2)
	step_row(scalar_statement)
	expect_eq(i64(raw.column_int64(scalar_statement, 0)), i64(42), "scalar callback result")
	expect_eq(raw.column_type(scalar_statement, 1), raw.NULL, "scalar callback NULL result")
	step_done(scalar_statement)
	finalize_ok(&scalar_statement)
	expect_eq(function_state.scalar_calls, i32(2), "scalar callback invocation count")

	exec_ok(db, "CREATE TABLE aggregate_input(group_id INTEGER, value INTEGER)")
	insert := prepare_ok(db, "INSERT INTO aggregate_input(group_id, value) VALUES(?1, ?2)")
	aggregate_values := []struct {
		group_id: i64,
		value: i64,
	}{{1, 1}, {1, 2}, {2, 10}, {2, 20}}
	for item in aggregate_values {
		bind_i64_ok(insert, 1, item.group_id)
		bind_i64_ok(insert, 2, item.value)
		step_done(insert)
		expect_rc(raw.reset(insert), raw.OK, "reset aggregate input insert")
	}
	bind_i64_ok(insert, 1, 1)
	bind_null_ok(insert, 2)
	step_done(insert)
	finalize_ok(&insert)

	aggregate_statement := prepare_ok(
		db,
		"SELECT group_id, engine_total(value) FROM aggregate_input GROUP BY group_id ORDER BY group_id",
	)
	step_row(aggregate_statement)
	expect_eq(i64(raw.column_int64(aggregate_statement, 0)), i64(1), "first aggregate group key")
	expect_eq(i64(raw.column_int64(aggregate_statement, 1)), i64(3), "first aggregate context total including NULL input")
	step_row(aggregate_statement)
	expect_eq(i64(raw.column_int64(aggregate_statement, 0)), i64(2), "second aggregate group key")
	expect_eq(i64(raw.column_int64(aggregate_statement, 1)), i64(30), "second aggregate context starts independently at zero")
	step_done(aggregate_statement)
	finalize_ok(&aggregate_statement)

	empty_aggregate := prepare_ok(db, "SELECT engine_total(value) FROM aggregate_input WHERE value>?1")
	bind_i64_ok(empty_aggregate, 1, 100)
	step_row(empty_aggregate)
	expect_eq(raw.column_type(empty_aggregate, 0), raw.NULL, "aggregate over empty input returns NULL")
	step_done(empty_aggregate)
	finalize_ok(&empty_aggregate)

	independent := open_db(":memory:")
	unregistered_statement: ^raw.Stmt
	unregistered_rc := prepare_rc(independent, "SELECT engine_twice(?1)", &unregistered_statement)
	expect_primary_rc(unregistered_rc, raw.ERROR, "function is not registered on independent connection")
	if unregistered_statement != nil {
		_ = raw.finalize(unregistered_statement)
	}
	close_db(&independent)

	expect_rc(
		raw.create_function_v2(
			db,
			"engine_twice",
			1,
			function_flags,
			rawptr(&function_state),
			scalar_twice_callback,
			nil,
			nil,
			function_destructor_callback,
		),
		raw.OK,
		"replace scalar function",
	)
	expect_eq(function_state.destructor_calls, i32(1), "replacement invokes prior destructor")
	close_db(&db)
	expect_eq(function_state.destructor_calls, i32(2), "connection close invokes replacement destructor")
}

// SQLITE-FEATURE-CONTRACT: engine.callbacks.collation-authorizer-teardown.v1
// Feature: Custom collation ordering, collation destructor lifetime, and authorizer denial.
// SQLite source: input/sqlite3.h sections "Define New Collating Sequences" and "Compile-Time Authorization Callbacks".
// Requirement: A registered UTF-8 collation controls ORDER BY comparisons; an authorizer returning SQLITE_DENY for SQLITE_DELETE makes preparation fail with SQLITE_AUTH; removing each registration restores ordinary behavior and destroys collation application data once.
// Adversarial cases: Reverse ordering across three bound strings, DELETE with a bound key, state check after denial, callback removal, successful retry, and use of the deleted collation name.
// Oracle: Ordered rows and callback counts prove collation dispatch; SQLITE_AUTH plus unchanged row count proves denial atomicity; post-removal DELETE succeeds and collation prepare fails.
// Guardrail: Do not sort expected values in host code, accept a DELETE that ran before denial, inspect parser internals, or leave callback-owned application data registered at close.
test_collation_authorizer_and_teardown :: proc() {
	db := open_db(":memory:")
	defer close_db(&db)
	exec_ok(db, "CREATE TABLE words(value TEXT)")
	exec_ok(db, "CREATE TABLE guarded(id INTEGER PRIMARY KEY)")

	word_insert := prepare_ok(db, "INSERT INTO words(value) VALUES(?1)")
	word_values := []string{"alpha", "gamma", "beta"}
	for value in word_values {
		bind_text_ok(word_insert, 1, value)
		step_done(word_insert)
		expect_rc(raw.reset(word_insert), raw.OK, "reset word insert")
	}
	finalize_ok(&word_insert)
	expect_rc(insert_i64(db, "INSERT INTO guarded(id) VALUES(?1)", 1), raw.DONE, "insert guarded row")

	collation_state := Collation_State{}
	expect_rc(
		raw.create_collation_v2(
			db,
			"ENGINE_REVERSE",
			i32(raw.UTF8),
			rawptr(&collation_state),
			reverse_collation_callback,
			collation_destructor_callback,
		),
		raw.OK,
		"register reverse collation",
	)
	ordered := prepare_ok(db, "SELECT value FROM words ORDER BY value COLLATE ENGINE_REVERSE")
	expected_values := []string{"gamma", "beta", "alpha"}
	for expected_value in expected_values {
		step_row(ordered)
		expect_column_text(ordered, 0, expected_value)
	}
	step_done(ordered)
	finalize_ok(&ordered)
	expect(collation_state.compare_calls > 0, "ORDER BY must invoke custom collation")

	authorizer_state := Authorizer_State{deny_delete = true}
	expect_rc(raw.set_authorizer(db, authorizer_callback, rawptr(&authorizer_state)), raw.OK, "install authorizer")
	denied: ^raw.Stmt
	denied_rc := prepare_rc(db, "DELETE FROM guarded WHERE id=?1", &denied)
	expect_primary_rc(denied_rc, raw.AUTH, "authorizer denied DELETE preparation")
	expect(authorizer_state.delete_actions > 0, "authorizer must observe SQLITE_DELETE")
	if denied != nil {
		_ = raw.finalize(denied)
	}
	expect_eq(query_i64(db, "SELECT count(*) FROM guarded"), i64(1), "denied DELETE leaves row unchanged")

	expect_rc(raw.set_authorizer(db, nil, nil), raw.OK, "remove authorizer")
	allowed := prepare_ok(db, "DELETE FROM guarded WHERE id=?1")
	bind_i64_ok(allowed, 1, 1)
	step_done(allowed)
	finalize_ok(&allowed)
	expect_eq(query_i64(db, "SELECT count(*) FROM guarded"), i64(0), "DELETE succeeds after authorizer removal")

	expect_rc(
		raw.create_collation_v2(db, "ENGINE_REVERSE", i32(raw.UTF8), nil, nil, nil),
		raw.OK,
		"delete custom collation",
	)
	expect_eq(collation_state.destructor_calls, i32(1), "collation deletion invokes destructor exactly once")
	missing_collation: ^raw.Stmt
	missing_collation_rc := prepare_rc(db, "SELECT value FROM words ORDER BY value COLLATE ENGINE_REVERSE", &missing_collation)
	expect_primary_rc(missing_collation_rc, raw.ERROR, "deleted collation is unavailable")
	if missing_collation != nil {
		_ = raw.finalize(missing_collation)
	}
}
