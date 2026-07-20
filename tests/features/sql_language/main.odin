package main

import "core:fmt"
import "core:mem"
import "core:os"

run_case :: proc(name: string, body: proc(), count: ^int) {
	fmt.printf("RUN  %s\n", name)
	body()
	count^ += 1
	fmt.printf("PASS %s\n", name)
}

main :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	context.allocator = mem.tracking_allocator(&tracker)

	fmt.println("== SQLite SQL-language feature contracts ==")
	count := 0
	run_case(
		"storage_classes_affinity_boundaries",
		test_storage_classes_affinity_boundaries,
		&count,
	)
	run_case("expression_semantics", test_expression_semantics, &count)
	run_case("ddl_indexes", test_ddl_indexes, &count)
	run_case(
		"ddl_views_triggers_generated_columns",
		test_ddl_views_triggers_generated_columns,
		&count,
	)
	run_case("ddl_strict_without_rowid", test_ddl_strict_without_rowid, &count)
	run_case("dml_returning_and_atomicity", test_dml_returning_and_atomicity, &count)
	run_case("dml_conflicts_and_upsert", test_dml_conflicts_and_upsert, &count)
	run_case("constraints_core", test_constraints_core, &count)
	run_case("foreign_key_actions", test_foreign_key_actions, &count)
	run_case("deferred_foreign_keys", test_deferred_foreign_keys, &count)
	run_case("select_joins_and_subqueries", test_select_joins_and_subqueries, &count)
	run_case("select_aggregates_and_compounds", test_select_aggregates_and_compounds, &count)
	run_case("select_ordering_and_limits", test_select_ordering_and_limits, &count)
	run_case("select_ctes_and_windows", test_select_ctes_and_windows, &count)
	run_case("json_functions", test_json_functions, &count)
	run_case("date_time_functions", test_date_time_functions, &count)
	run_case("transactions_and_savepoints", test_transactions_and_savepoints, &count)

	expect_equal(count, 17, "registered SQL-language contract count")
	fmt.printf("== %d SQL-language feature contracts passed ==\n", count)

	leak_count := len(tracker.allocation_map)
	bad_free_count := len(tracker.bad_free_array)
	if leak_count > 0 {
		fmt.eprintf("=== %d allocations not freed ===\n", leak_count)
		for _, entry in tracker.allocation_map {
			fmt.eprintf("- %d bytes @ %v\n", entry.size, entry.location)
		}
	}
	if bad_free_count > 0 {
		fmt.eprintf("=== %d incorrect frees ===\n", bad_free_count)
		for entry in tracker.bad_free_array {
			fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
		}
	}
	mem.tracking_allocator_destroy(&tracker)

	if leak_count > 0 || bad_free_count > 0 {
		os.exit(1)
	}
	os.exit(0)
}
