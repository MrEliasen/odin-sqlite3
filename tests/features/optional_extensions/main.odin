package optional_extensions

import "core:fmt"
import "core:mem"
import "core:os"

when ALL_FEATURE_BINDING_PROFILE {
	main :: proc() {
		tracking: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking, context.allocator)
		context.allocator = mem.tracking_allocator(&tracking)

		fmt.println("== SQLite optional/extensions feature contracts ==")
		require_all_feature_sqlite()

		run_case("column_metadata", test_column_metadata_contract)
		run_case("normalized_sql", test_normalized_sql_contract)
		run_case("preupdate_events_depth_count", test_preupdate_events_depth_count_contract)
		run_case("preupdate_blobwrite_lifecycle", test_preupdate_blobwrite_lifecycle_contract)
		run_case("session_changeset_roundtrip_conflict", test_session_changeset_roundtrip_conflict_contract)
		run_case("snapshot_wal_lifecycle", test_snapshot_wal_lifecycle_contract)
		run_case("unlock_notify_shared_cache", test_unlock_notify_shared_cache_contract)
		run_case("statement_scanstatus", test_statement_scanstatus_contract)
		run_case("fts5_sql", test_fts5_sql_contract)
		run_case("rtree_sql", test_rtree_sql_contract)
		run_case("json_sql", test_json_sql_contract)

		fmt.println("== all optional/extensions contracts passed ==")
		leaks := len(tracking.allocation_map)
		bad_frees := len(tracking.bad_free_array)
		if leaks > 0 {
			fmt.eprintf("%d tracked allocations were not freed\n", leaks)
			for _, entry in tracking.allocation_map {
				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}
		}
		if bad_frees > 0 {
			fmt.eprintf("%d invalid frees were detected\n", bad_frees)
		}
		mem.tracking_allocator_destroy(&tracking)
		if leaks != 0 || bad_frees != 0 {
			os.exit(1)
		}
	}
} else {
	main :: proc() {
		fmt.eprintln("REFUSED: optional/extensions contracts require all seven SQLITE_HAS_* defines and the pinned all-feature SQLite library")
		os.exit(2)
	}
}
