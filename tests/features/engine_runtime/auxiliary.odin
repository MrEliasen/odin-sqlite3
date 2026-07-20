package engine_runtime

import raw "../../../sqlite/raw/generated"

// SQLITE-FEATURE-CONTRACT: engine.backup.roundtrip-progress.v1
// Feature: Online backup copy, incremental progress counters, finish lifecycle, and durable destination state.
// SQLite source: input/sqlite3.h section "Online Backup API".
// Requirement: backup_step copies the source snapshot into the destination, reports nonincreasing remaining pages bounded by pagecount, returns SQLITE_DONE on completion, and backup_finish leaves both database handles usable and independent.
// Adversarial cases: Multi-page patterned BLOB, one-page incremental steps, progress checked on every step, distinct bound inserts on source and destination after finish, destination fully closed and reopened, and byte-for-byte verification through a new statement.
// Oracle: SQLite result codes and backup counters are paired with post-finish source/destination states {9,10} and {9,11}; a reopened destination validates copied and destination-only rows independently of the source handle.
// Guardrail: Do not treat backup_init symbol linkage as coverage, verify only through the source connection, accept a partial backup, or read backup counters after finish.
test_backup_roundtrip_and_progress :: proc() {
	source_path := make_temp_db_path("backup_source")
	defer delete(source_path)
	remove_db_files(source_path)
	defer remove_db_files(source_path)
	destination_path := make_temp_db_path("backup_destination")
	defer delete(destination_path)
	remove_db_files(destination_path)
	defer remove_db_files(destination_path)

	source := open_db(source_path)
	destination := open_db(destination_path)
	exec_ok(source, "CREATE TABLE backup_probe(id INTEGER PRIMARY KEY, payload BLOB)")
	payload := make([]u8, 256 * 1024)
	for _, index in payload {
		payload[index] = u8((index * 19 + 5) & 0xff)
	}
	insert := prepare_ok(source, "INSERT INTO backup_probe(id, payload) VALUES(?1, ?2)")
	bind_i64_ok(insert, 1, 9)
	bind_blob_ok(insert, 2, payload)
	delete(payload)
	step_done(insert)
	finalize_ok(&insert)

	backup := raw.backup_init(destination, "main", source, "main")
	expect(backup != nil, "sqlite3_backup_init must create a backup handle")
	previous_remaining := max(i32)
	step_count := 0
	completed := false
	for step_count < 10000 {
		step_count += 1
		rc := raw.backup_step(backup, 1)
		remaining := raw.backup_remaining(backup)
		page_count := raw.backup_pagecount(backup)
		expect(page_count > 1, "patterned payload must produce a multi-page source database")
		expect(remaining >= 0 && remaining <= page_count, "backup remaining pages must be bounded by page count")
		expect(remaining <= previous_remaining, "backup remaining pages must not increase without a source write")
		previous_remaining = remaining
		if rc == raw.DONE {
			expect_eq(remaining, i32(0), "completed backup remaining pages")
			completed = true
			break
		}
		expect_rc(rc, raw.OK, "incremental backup step")
	}
	expect(completed, "incremental backup must reach SQLITE_DONE")
	expect(step_count > 1, "one-page backup must require multiple steps for multi-page source")
	expect_rc(raw.backup_finish(backup), raw.OK, "finish completed backup")
	backup = nil

	source_after_finish := []u8{0x53, 0x52, 0x43}
	source_insert := prepare_ok(source, "INSERT INTO backup_probe(id, payload) VALUES(?1, ?2)")
	bind_i64_ok(source_insert, 1, 10)
	bind_blob_ok(source_insert, 2, source_after_finish)
	step_done(source_insert)
	finalize_ok(&source_insert)

	destination_after_finish := []u8{0x44, 0x53, 0x54}
	destination_insert := prepare_ok(destination, "INSERT INTO backup_probe(id, payload) VALUES(?1, ?2)")
	bind_i64_ok(destination_insert, 1, 11)
	bind_blob_ok(destination_insert, 2, destination_after_finish)
	step_done(destination_insert)
	finalize_ok(&destination_insert)

	source_state := prepare_ok(source, "SELECT id FROM backup_probe ORDER BY id")
	step_row(source_state)
	expect_eq(i64(raw.column_int64(source_state, 0)), i64(9), "source retains copied row after backup finish")
	step_row(source_state)
	expect_eq(i64(raw.column_int64(source_state, 0)), i64(10), "source accepts source-only row after backup finish")
	step_done(source_state)
	finalize_ok(&source_state)

	destination_state := prepare_ok(destination, "SELECT id FROM backup_probe ORDER BY id")
	step_row(destination_state)
	expect_eq(i64(raw.column_int64(destination_state, 0)), i64(9), "destination retains copied row after backup finish")
	step_row(destination_state)
	expect_eq(i64(raw.column_int64(destination_state, 0)), i64(11), "destination accepts destination-only row after backup finish")
	step_done(destination_state)
	finalize_ok(&destination_state)

	close_db(&destination)
	close_db(&source)

	reopened := open_db(destination_path)
	reader := prepare_ok(reopened, "SELECT id, payload FROM backup_probe WHERE id=?1")
	bind_i64_ok(reader, 1, 9)
	step_row(reader)
	expect_eq(i64(raw.column_int64(reader, 0)), i64(9), "backed-up row key")
	expect_eq(raw.column_type(reader, 1), raw.BLOB, "backed-up payload type")
	expect_eq(raw.column_bytes(reader, 1), i32(256 * 1024), "backed-up payload length")
	actual := ([^]u8)(raw.column_blob(reader, 1))[:256 * 1024]
	for _, index in actual {
		expect_eq(actual[index], u8((index * 19 + 5) & 0xff), "backed-up payload byte %d", index)
	}
	step_done(reader)
	finalize_ok(&reader)

	destination_only := prepare_ok(reopened, "SELECT payload FROM backup_probe WHERE id=?1")
	bind_i64_ok(destination_only, 1, 11)
	step_row(destination_only)
	expect_column_blob(destination_only, 0, destination_after_finish)
	step_done(destination_only)
	finalize_ok(&destination_only)
	expect_eq(query_i64(reopened, "SELECT count(*) FROM backup_probe"), i64(2), "reopened destination contains copied and destination-only rows")
	close_db(&reopened)
}

// SQLITE-FEATURE-CONTRACT: engine.blob.incremental-bounds-reopen.v1
// Feature: Incremental BLOB open/read/write/reopen/close lifecycle and bounds atomicity.
// SQLite source: input/sqlite3.h section "Incremental BLOB I/O".
// Requirement: A read-write BLOB handle updates bytes in place without changing length, out-of-range access returns SQLITE_ERROR without a partial write, blob_reopen retargets the handle, and writes through a read-only handle return SQLITE_READONLY.
// Adversarial cases: Middle write, write crossing the final byte, full read after failure, reopen to a second row, and write attempt using a read-only handle.
// Oracle: Exact result codes and BLOB-handle reads are followed by an ordered SQL hex query through a distinct prepared statement.
// Guardrail: Do not resize the BLOB through incremental I/O, accept prefix mutation on a failed write, use a closed handle, or validate only through blob_read.
test_incremental_blob_bounds_and_reopen :: proc() {
	db := open_db(":memory:")
	defer close_db(&db)
	exec_ok(db, "CREATE TABLE blob_probe(id INTEGER PRIMARY KEY, payload BLOB)")
	insert := prepare_ok(db, "INSERT INTO blob_probe(id, payload) VALUES(?1, ?2)")
	for id in i64(1) ..= 2 {
		bind_i64_ok(insert, 1, id)
		expect_rc(raw.bind_zeroblob(insert, 2, 8), raw.OK, "bind eight-byte zeroblob")
		step_done(insert)
		expect_rc(raw.reset(insert), raw.OK, "reset zeroblob insert")
	}
	finalize_ok(&insert)

	blob: ^raw.Blob
	expect_rc(raw.blob_open(db, "main", "blob_probe", "payload", 1, 1, &blob), raw.OK, "open read-write incremental blob")
	expect(blob != nil, "blob_open must return a handle")
	expect_eq(raw.blob_bytes(blob), i32(8), "incremental blob byte length")
	middle := []u8{1, 2, 3, 4}
	expect_rc(raw.blob_write(blob, rawptr(&middle[0]), i32(len(middle)), 2), raw.OK, "write middle blob bytes")
	expected_first := []u8{0, 0, 1, 2, 3, 4, 0, 0}
	read_buffer: [8]u8
	expect_rc(raw.blob_read(blob, rawptr(&read_buffer[0]), 8, 0), raw.OK, "read full incremental blob")
	for byte, index in read_buffer {
		expect_eq(byte, expected_first[index], "incremental blob byte %d before failure", index)
	}

	overflow := []u8{9, 9}
	expect_rc(raw.blob_write(blob, rawptr(&overflow[0]), i32(len(overflow)), 7), raw.ERROR, "out-of-range incremental blob write")
	expect_rc(raw.blob_read(blob, rawptr(&read_buffer[0]), 8, 0), raw.OK, "read blob after failed write")
	for byte, index in read_buffer {
		expect_eq(byte, expected_first[index], "failed blob write leaves byte %d unchanged", index)
	}

	expect_rc(raw.blob_reopen(blob, 2), raw.OK, "retarget blob handle to second row")
	second_prefix := []u8{8}
	expect_rc(raw.blob_write(blob, rawptr(&second_prefix[0]), 1, 0), raw.OK, "write retargeted blob")
	expect_rc(raw.blob_close(blob), raw.OK, "close read-write blob")
	blob = nil

	read_only_blob: ^raw.Blob
	expect_rc(raw.blob_open(db, "main", "blob_probe", "payload", 1, 0, &read_only_blob), raw.OK, "open read-only incremental blob")
	expect_primary_rc(raw.blob_write(read_only_blob, rawptr(&second_prefix[0]), 1, 0), raw.READONLY, "write through read-only blob handle")
	// sqlite3_blob_close unconditionally closes a valid handle even when it
	// returns an error code. The header does not promise a specific close code
	// after the preceding failed write, so cleanup must not invent one.
	_ = raw.blob_close(read_only_blob)
	read_only_blob = nil

	oracle := prepare_ok(db, "SELECT hex(payload) FROM blob_probe ORDER BY id")
	step_row(oracle)
	expect_column_text(oracle, 0, "0000010203040000")
	step_row(oracle)
	expect_column_text(oracle, 0, "0800000000000000")
	step_done(oracle)
	finalize_ok(&oracle)
}

// SQLITE-FEATURE-CONTRACT: engine.serialize.deserialize-readonly-ownership.v1
// Feature: Database serialization, deserialization, no-copy access, read-only enforcement, and FREEONCLOSE ownership.
// SQLite source: input/sqlite3.h sections "Serialize a database", "Deserialize a database", and "Flags for sqlite3_deserialize()".
// Requirement: serialize returns an SQLite-allocated complete image; deserialize exposes that image as the main database, READONLY rejects writes, NOCOPY exposes the contiguous deserialized image, and FREEONCLOSE transfers release responsibility to SQLite.
// Adversarial cases: Bound text and embedded-zero BLOB content, exact serialized size, combined FREEONCLOSE and READONLY flags, no-copy serialization, failed bound insert, and close-driven ownership release under allocator/sanitizer gates.
// Oracle: A distinct deserialized connection reads exact typed values and bytes, stable SQLITE_READONLY is required for mutation, NOCOPY reports the same image size, and clean teardown is checked by ASan plus the tracking harness.
// Guardrail: Do not free the buffer after successful FREEONCLOSE transfer, mutate a NOCOPY pointer, silently skip SQLITE_OMIT_DESERIALIZE, or treat a non-NULL pointer alone as data correctness.
test_serialize_deserialize_readonly_ownership :: proc() {
	expect_eq(raw.compileoption_used("OMIT_DESERIALIZE"), i32(0), "pinned qualification build must provide serialize/deserialize")
	source := open_db(":memory:")
	exec_ok(source, "CREATE TABLE serialized_probe(id INTEGER PRIMARY KEY, value TEXT, payload BLOB)")
	insert := prepare_ok(source, "INSERT INTO serialized_probe(id, value, payload) VALUES(?1, ?2, ?3)")
	bind_i64_ok(insert, 1, 5)
	bind_text_ok(insert, 2, "serialized-value")
	payload := []u8{0xaa, 0x00, 0xbb, 0xcc}
	bind_blob_ok(insert, 3, payload)
	step_done(insert)
	finalize_ok(&insert)

	serialized_size: raw.Int64
	serialized := raw.serialize(source, "main", &serialized_size, 0)
	expect(serialized != nil, "sqlite3_serialize must return an owned image")
	expect(serialized_size > 0, "serialized image must have positive size")

	destination := open_db(":memory:")
	deserialize_flags := u32(raw.DESERIALIZE_FREEONCLOSE | raw.DESERIALIZE_READONLY)
	deserialize_rc := raw.deserialize(
		destination,
		"main",
		serialized,
		serialized_size,
		serialized_size,
		deserialize_flags,
	)
	if deserialize_rc != raw.OK {
		raw.free(rawptr(serialized))
	}
	expect_rc(deserialize_rc, raw.OK, "deserialize read-only image with ownership transfer")
	serialized = nil

	reader := prepare_ok(destination, "SELECT id, value, payload FROM serialized_probe")
	step_row(reader)
	expect_eq(i64(raw.column_int64(reader, 0)), i64(5), "deserialized row key")
	expect_column_text(reader, 1, "serialized-value")
	expect_column_blob(reader, 2, payload)
	step_done(reader)
	finalize_ok(&reader)

	nocopy_size: raw.Int64
	nocopy := raw.serialize(destination, "main", &nocopy_size, u32(raw.SERIALIZE_NOCOPY))
	expect(nocopy != nil, "deserialized database must expose a contiguous NOCOPY image")
	expect_eq(nocopy_size, serialized_size, "NOCOPY serialized image size")

	failed_write := prepare_ok(destination, "INSERT INTO serialized_probe(id, value, payload) VALUES(?1, ?2, ?3)")
	bind_i64_ok(failed_write, 1, 6)
	bind_text_ok(failed_write, 2, "forbidden")
	bind_blob_ok(failed_write, 3, payload)
	write_rc := raw.step(failed_write)
	expect_primary_rc(write_rc, raw.READONLY, "write to READONLY deserialized database")
	expect_primary_rc(raw.finalize(failed_write), raw.READONLY, "finalize failed deserialized write")
	failed_write = nil
	expect_eq(query_i64(destination, "SELECT count(*) FROM serialized_probe"), i64(1), "failed deserialized write leaves row count unchanged")

	close_db(&destination)
	close_db(&source)
}
