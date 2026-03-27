package tests

import "core:fmt"
import "core:os"

root_path :: ""

expect_file_contains :: proc(path: string, needle: string, message: string) {
	data, ok := os.read_entire_file(path, context.allocator)
	expect_true(ok == os.ERROR_NONE, "%s | failed reading %q: %v", message, path, ok)
	defer delete(data)

	text := string(data)
	expect_string_contains(text, needle, message)
}

expect_file_not_contains :: proc(path: string, needle: string, message: string) {
	data, ok := os.read_entire_file(path, context.allocator)
	expect_true(ok == os.ERROR_NONE, "%s | failed reading %q: %v", message, path, ok)
	defer delete(data)

	text := string(data)
	expect_false(
		contains_string(text, needle),
		fmt.tprintf("%s | unexpectedly found %q in %q", message, needle, path),
	)
}

test_p3_priorities_are_explicitly_deferred :: proc() {
	expect_file_contains(
		root_path + "PRIORITIES.md",
		"## P3",
		"priority plan should contain a dedicated P3 section",
	)
	expect_file_contains(
		root_path + "PRIORITIES.md",
		"1. **Reflection-based row mapping**",
		"priority plan should explicitly defer reflection-based row mapping",
	)
	expect_file_contains(
		root_path + "PRIORITIES.md",
		"2. **Struct-tag mapping**",
		"priority plan should explicitly defer struct-tag mapping",
	)
	expect_file_contains(
		root_path + "PRIORITIES.md",
		"## Stage 16 — Reflection-based row mapping [P3]",
		"priority plan should keep reflection-based row mapping in the deferred stage list",
	)
	expect_file_contains(
		root_path + "PRIORITIES.md",
		"This should not be foundational.",
		"priority plan should state that row mapping is not foundational",
	)
}

test_implementation_spec_forbids_mapping_first_design :: proc() {
	expect_file_contains(
		root_path + "IMPLEMENTATION_SPEC.md",
		"- **Do not** start with reflection-based row mapping",
		"implementation spec should explicitly forbid starting with reflection-based row mapping",
	)
	expect_file_contains(
		root_path + "IMPLEMENTATION_SPEC.md",
		"- **Do not** start with regex/tag-driven struct decoding",
		"implementation spec should explicitly forbid regex/tag-driven struct decoding",
	)
	expect_file_contains(
		root_path + "IMPLEMENTATION_SPEC.md",
		"- ORM features",
		"implementation spec non-goals should continue to exclude ORM features",
	)
	expect_file_contains(
		root_path + "IMPLEMENTATION_SPEC.md",
		"- automatic struct mapping",
		"implementation spec non-goals should continue to exclude automatic struct mapping",
	)
}

test_wrapper_surface_does_not_introduce_row_mapping_abstractions :: proc() {
	expect_file_not_contains(
		root_path + "sqlite/package.odin",
		"row_map",
		"package surface should not advertise row mapping helpers",
	)
	expect_file_not_contains(
		root_path + "sqlite/package.odin",
		"struct_tag",
		"package surface should not advertise struct-tag mapping helpers",
	)
	expect_file_not_contains(
		root_path + "sqlite/package.odin",
		"query_builder",
		"package surface should not advertise query builder helpers",
	)

	expect_file_contains(
		root_path + "README.md",
		"The project is not currently pursuing:",
		"readme should explicitly document deferred and excluded abstraction categories",
	)
	expect_file_contains(
		root_path + "README.md",
		"- reflection/tag mapping",
		"readme should explicitly document that reflection/tag mapping is not currently being pursued",
	)
	expect_file_contains(
		root_path + "README.md",
		"- query builders",
		"readme should explicitly document that query builders are not currently being pursued",
	)
	expect_file_contains(
		root_path + "README.md",
		"- ORM features",
		"readme should explicitly document that ORM features are not currently being pursued",
	)
}

test_p3_deferral_contract :: proc() {
	test_p3_priorities_are_explicitly_deferred()
	test_implementation_spec_forbids_mapping_first_design()
	test_wrapper_surface_does_not_introduce_row_mapping_abstractions()
}