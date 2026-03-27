package tests

import "core:fmt"
import "core:mem"
import "core:os"

run_test :: proc(name: string, test_proc: proc()) {
	fmt.printf("RUN  %s\n", name)
	test_proc()
	fmt.printf("PASS %s\n", name)
}

run_connection_tests :: proc() {
	run_test("connection_open_close", test_connection_open_close)
	run_test("connection_open_into", test_connection_open_into)
	run_test("connection_invalid_open_reports_error", test_connection_invalid_open_reports_error)
	run_test("connection_error_string_helpers", test_connection_error_string_helpers)
	run_test("connection_busy_timeout_and_extended_errors", test_connection_busy_timeout_and_extended_errors)
	run_test("connection_errmsg_and_errcode_after_sql_error", test_connection_errmsg_and_errcode_after_sql_error)
	run_test("connection_transaction_state_tracks_autocommit", test_connection_transaction_state_tracks_autocommit)
	run_test("connection_interrupt_flag_roundtrip", test_connection_interrupt_flag_roundtrip)
}

run_statement_tests :: proc() {
	run_test("statement_prepare_step_finalize", test_statement_prepare_step_finalize)
	run_test("statement_reset_allows_reuse", test_statement_reset_allows_reuse)
	run_test("statement_clear_bindings_resets_parameters", test_statement_clear_bindings_resets_parameters)
	run_test("statement_sql_and_expanded_sql", test_statement_sql_and_expanded_sql)
	run_test("statement_readonly_detection", test_statement_readonly_detection)
	run_test("statement_data_count_matches_row_state", test_statement_data_count_matches_row_state)
	run_test("statement_next_reports_row_and_done", test_statement_next_reports_row_and_done)
	run_test("column_reader_types_and_nulls", test_column_reader_types_and_nulls)
	run_test("column_decltype_for_table_columns", test_column_decltype_for_table_columns)
	run_test("statement_bind_parameter_metadata", test_statement_bind_parameter_metadata)
	run_test("statement_named_binding_and_reuse", test_statement_named_binding_and_reuse)
	run_test("statement_invalid_sql_returns_error", test_statement_invalid_sql_returns_error)
}

run_bind_tests :: proc() {
	run_test("bind_primitive_parameters", test_bind_primitive_parameters)
	run_test("bind_null_parameter", test_bind_null_parameter)
	run_test("bind_text_parameter_roundtrip", test_bind_text_parameter_roundtrip)
	run_test("bind_empty_text_parameter_roundtrip", test_bind_empty_text_parameter_roundtrip)
	run_test("bind_blob_parameter_roundtrip", test_bind_blob_parameter_roundtrip)
	run_test("bind_empty_blob_parameter_roundtrip", test_bind_empty_blob_parameter_roundtrip)
	run_test("bind_zeroblob_parameter_roundtrip", test_bind_zeroblob_parameter_roundtrip)
	run_test("bind_named_parameters_roundtrip", test_bind_named_parameters_roundtrip)
	run_test("bind_generic_bind_arg_roundtrip", test_bind_generic_bind_arg_roundtrip)
	run_test("bind_named_generic_bind_arg_roundtrip", test_bind_named_generic_bind_arg_roundtrip)
	run_test("bind_batch_positional_args", test_bind_batch_positional_args)
	run_test("bind_batch_positional_args_slice", test_bind_batch_positional_args_slice)
	run_test("bind_batch_positional_args_allows_fewer_parameters", test_bind_batch_positional_args_allows_fewer_parameters)
	run_test("bind_batch_positional_args_errors_on_too_many_parameters", test_bind_batch_positional_args_errors_on_too_many_parameters)
	run_test("bind_batch_positional_args_does_not_auto_clear_bindings", test_bind_batch_positional_args_does_not_auto_clear_bindings)
	run_test("bind_reuse_does_not_leave_stale_parameters", test_bind_reuse_does_not_leave_stale_parameters)
	run_test("bind_reset_preserves_bindings_until_cleared", test_bind_reset_preserves_bindings_until_cleared)
	run_test("bind_invalid_index_returns_range_error", test_bind_invalid_index_returns_range_error)
	run_test("bind_missing_named_parameter_returns_range_error", test_bind_missing_named_parameter_returns_range_error)
}

run_transaction_tests :: proc() {
	run_test("exec_changes_and_last_insert_rowid", test_exec_changes_and_last_insert_rowid)
	run_test("exec_query_helpers", test_exec_query_helpers)
	run_test("exec_scalar_and_exists_helpers", test_exec_scalar_and_exists_helpers)
	run_test("transaction_begin_commit_and_rollback", test_transaction_begin_commit_and_rollback)
	run_test("transaction_begin_modes", test_transaction_begin_modes)
	run_test("transaction_savepoint_release_and_rollback_to", test_transaction_savepoint_release_and_rollback_to)
	run_test("transaction_with_transaction_helper", test_transaction_with_transaction_helper)
	run_test("transaction_with_savepoint_helper", test_transaction_with_savepoint_helper)
	run_test("transaction_invalid_savepoint_name_is_rejected", test_transaction_invalid_savepoint_name_is_rejected)
	run_test("cache_prepare_reuse_and_clear", test_cache_prepare_reuse_and_clear)
	run_test("cache_usage_tracking_and_prune_unused", test_cache_usage_tracking_and_prune_unused)
	run_test("operational_busy_timeout_and_wal_checkpoint", test_operational_busy_timeout_and_wal_checkpoint)
	run_test("operational_stmt_consume_done_and_with_stmt", test_operational_stmt_consume_done_and_with_stmt)
}

run_error_and_extra_api_tests :: proc() {
	run_test("structured_error_model", test_structured_error_model)
	run_test("tracing_and_debug_helpers", test_tracing_and_debug_helpers)
	run_test("blob_api", test_blob_api)
	run_test("backup_api", test_backup_api)
	run_test("row_mapping_by_field_name", test_row_mapping_by_field_name)
	run_test("row_mapping_by_struct_tag", test_row_mapping_by_struct_tag)
	run_test("row_mapping_unmatched_fields_are_ignored", test_row_mapping_unmatched_fields_are_ignored)
	run_test("row_mapping_nulls_follow_wrapper_defaults", test_row_mapping_nulls_follow_wrapper_defaults)
	run_test("row_mapping_extra_columns_are_ignored", test_row_mapping_extra_columns_are_ignored)
	run_test("row_mapping_requires_exact_name_without_tag", test_row_mapping_requires_exact_name_without_tag)
	run_test("row_mapping_unsupported_field_type_returns_error", test_row_mapping_unsupported_field_type_returns_error)
	run_test("row_mapping_is_additive_to_explicit_getters", test_row_mapping_is_additive_to_explicit_getters)
	run_test("struct_query_one_wrapper", test_struct_query_one_wrapper)
	run_test("struct_query_optional_wrapper_found_and_missing", test_struct_query_optional_wrapper_found_and_missing)
	run_test("struct_query_all_wrapper", test_struct_query_all_wrapper)
	run_test("p3_deferral_contract", test_p3_deferral_contract)
}

main :: proc() {
    tracking_allocator: mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking_allocator, context.allocator)
    context.allocator = mem.tracking_allocator(&tracking_allocator)

	fmt.println("== odin-sqlite smoke tests ==")

	run_connection_tests()
	run_statement_tests()
	run_bind_tests()
	run_transaction_tests()
	run_error_and_extra_api_tests()

	fmt.println("== all smoke tests passed ==")

    if len(tracking_allocator.allocation_map) > 0 {
        fmt.eprintf("=== %v allocations not freed: ===\n", len(tracking_allocator.allocation_map))
        for _, entry in tracking_allocator.allocation_map {
            fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
        }
    }

    // Check for bad frees (optional, often checked per-frame in games)
    if len(tracking_allocator.bad_free_array) > 0 {
        fmt.eprintf("=== %v incorrect frees: ===\n", len(tracking_allocator.bad_free_array))
        for entry in tracking_allocator.bad_free_array {
            fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
        }
    }
    mem.tracking_allocator_destroy(&tracking_allocator)

	os.exit(0)
}
