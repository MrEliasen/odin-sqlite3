package example_support

import "core:fmt"
import "core:mem"
import "core:os"

// run executes an example with the allocator used by the bindings replaced by
// Odin's tracking allocator. Any allocation left behind, or any invalid free,
// is a failed example rather than a diagnostic that CI can accidentally ignore.
run :: proc(example: proc()) {
	tracking_allocator: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking_allocator, context.allocator)
	context.allocator = mem.tracking_allocator(&tracking_allocator)

	example()

	leak_count := len(tracking_allocator.allocation_map)
	bad_free_count := len(tracking_allocator.bad_free_array)

	if leak_count > 0 {
		fmt.eprintf("=== %v allocations not freed: ===\n", leak_count)
		for _, entry in tracking_allocator.allocation_map {
			fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
		}
	}
	if bad_free_count > 0 {
		fmt.eprintf("=== %v incorrect frees: ===\n", bad_free_count)
		for entry in tracking_allocator.bad_free_array {
			fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
		}
	}

	mem.tracking_allocator_destroy(&tracking_allocator)

	if leak_count > 0 || bad_free_count > 0 {
		os.exit(1)
	}
}
