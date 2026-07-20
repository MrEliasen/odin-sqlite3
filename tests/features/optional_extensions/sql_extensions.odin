package optional_extensions

import raw "../../../sqlite/raw/generated"

when ALL_FEATURE_BINDING_PROFILE {
	fts_insert :: proc(db: ^raw.Sqlite3, rowid: i64, title, body: string) {
		stmt := prepare_ok(db, "INSERT INTO docs(rowid, title, body) VALUES(?1, ?2, ?3)")
		defer finalize_ok(&stmt)
		bind_i64(stmt, 1, rowid)
		bind_text(stmt, 2, title)
		bind_text(stmt, 3, body)
		step_done(stmt)
	}

	// SQLITE-FEATURE-CONTRACT: extension.fts5.match-rank-mutation.v1
	// Feature: FTS5 supports phrase and prefix MATCH, rank ordering, highlighting, mutation, invalid-query failure, and persistence.
	// SQLite source: https://sqlite.org/fts5.html and the pinned SQLite amalgamation built with SQLITE_ENABLE_FTS5.
	// Requirement: MATCH selects tokenized rows, quoted terms form phrases, trailing-star terms perform prefix queries, lower rank sorts first, and UPDATE/DELETE maintain the index.
	// Adversarial cases: Bound phrase/prefix terms, repeated term ranking, highlight markers, empty indexed text, malformed MATCH syntax, update/delete, close and reopen.
	// Oracle: Ordered rowids and highlighted text come from FTS5 while independent ordinary row counts and reopened MATCH queries verify index/state consistency.
	// Guardrail: Do not treat CREATE VIRTUAL TABLE or module availability as behavioral coverage, and do not accept stale matches after UPDATE or DELETE.
	test_fts5_sql_contract :: proc() {
		path := temp_db_path("odin_sqlite_optional_fts5.sqlite3")
		defer delete(path)
		clean_db_files(path)
		defer clean_db_files(path)
		db := open_db(path)
		exec_ok(db, "CREATE VIRTUAL TABLE docs USING fts5(title, body, prefix='2 3')")
		fts_insert(db, 1, "Alpha", "quick brown fox running sqlite sqlite")
		fts_insert(db, 2, "Beta", "running with sqlite")
		fts_insert(db, 3, "Gamma", "quick blue hare")
		fts_insert(db, 4, "", "")

		phrase := prepare_ok(db, "SELECT rowid FROM docs WHERE docs MATCH ?1 ORDER BY rowid")
		bind_text(phrase, 1, "\"quick brown\"")
		step_row(phrase)
		expect_equal(i64(raw.column_int64(phrase, 0)), i64(1), "phrase MATCH rowid")
		step_done(phrase)
		finalize_ok(&phrase)

		prefix := prepare_ok(db, "SELECT rowid FROM docs WHERE docs MATCH ?1 ORDER BY rowid")
		bind_text(prefix, 1, "runn*")
		step_row(prefix)
		expect_equal(i64(raw.column_int64(prefix, 0)), i64(1), "first prefix MATCH rowid")
		step_row(prefix)
		expect_equal(i64(raw.column_int64(prefix, 0)), i64(2), "second prefix MATCH rowid")
		step_done(prefix)
		finalize_ok(&prefix)

		ranked := prepare_ok(db, "SELECT rowid, rank, highlight(docs, 1, '[', ']') FROM docs WHERE docs MATCH ?1 ORDER BY rank, rowid")
		bind_text(ranked, 1, "sqlite")
		step_row(ranked)
		expect_equal(i64(raw.column_int64(ranked, 0)), i64(1), "row with two occurrences must rank first")
		first_rank := raw.column_double(ranked, 1)
		first_highlight := column_text_copy(ranked, 2)
		defer delete(first_highlight)
		expect_contains(first_highlight, "[sqlite]", "highlight must mark matching terms")
		step_row(ranked)
		expect_equal(i64(raw.column_int64(ranked, 0)), i64(2), "single-occurrence row rank")
		second_rank := raw.column_double(ranked, 1)
		expect(first_rank < second_rank, "FTS5 lower rank must place the stronger match first")
		step_done(ranked)
		finalize_ok(&ranked)

		empty := prepare_ok(db, "SELECT typeof(title), length(title), typeof(body), length(body) FROM docs WHERE rowid=?1")
		bind_i64(empty, 1, 4)
		step_row(empty)
		expect_equal(string(raw.column_text(empty, 0)), "text", "empty FTS title type")
		expect_equal(i64(raw.column_int64(empty, 1)), i64(0), "empty FTS title length")
		expect_equal(string(raw.column_text(empty, 2)), "text", "empty FTS body type")
		expect_equal(i64(raw.column_int64(empty, 3)), i64(0), "empty FTS body length")
		step_done(empty)
		finalize_ok(&empty)

		bad := prepare_ok(db, "SELECT count(*) FROM docs WHERE docs MATCH ?1")
		bind_text(bad, 1, "\"")
		rc := raw.step(bad)
		expect_equal(primary_rc(rc), i32(raw.ERROR), "malformed FTS5 query must fail")
		finalize_rc := raw.finalize(bad)
		expect_equal(primary_rc(finalize_rc), i32(raw.ERROR), "finalize must preserve the prior MATCH error")
		bad = nil
		expect_equal(scalar_i64(db, "SELECT COUNT(*) FROM docs"), i64(4), "invalid MATCH must not mutate indexed rows")

		update := prepare_ok(db, "UPDATE docs SET body=?1 WHERE rowid=?2")
		bind_text(update, 1, "walking only")
		bind_i64(update, 2, 2)
		step_done(update)
		finalize_ok(&update)
		delete_stmt := prepare_ok(db, "DELETE FROM docs WHERE rowid=?1")
		bind_i64(delete_stmt, 1, 3)
		step_done(delete_stmt)
		finalize_ok(&delete_stmt)

		close_db(&db)
		db = open_db(path)
		prefix = prepare_ok(db, "SELECT rowid FROM docs WHERE docs MATCH ?1 ORDER BY rowid")
		bind_text(prefix, 1, "runn*")
		step_row(prefix)
		expect_equal(i64(raw.column_int64(prefix, 0)), i64(1), "updated FTS index must retain only the remaining prefix match")
		step_done(prefix)
		finalize_ok(&prefix)
		expect_equal(scalar_i64(db, "SELECT COUNT(*) FROM docs"), i64(3), "delete must persist in content table")
		close_db(&db)
	}

	rtree_insert :: proc(db: ^raw.Sqlite3, id: i64, min_x, max_x, min_y, max_y: f64) -> i32 {
		stmt := prepare_ok(db, "INSERT INTO boxes(id, minX, maxX, minY, maxY) VALUES(?1, ?2, ?3, ?4, ?5)")
		bind_i64(stmt, 1, id)
		bind_f64(stmt, 2, min_x)
		bind_f64(stmt, 3, max_x)
		bind_f64(stmt, 4, min_y)
		bind_f64(stmt, 5, max_y)
		rc := raw.step(stmt)
		finalize_rc := raw.finalize(stmt)
		if rc == raw.DONE {
			expect_rc(finalize_rc, raw.OK, "finalize successful R-Tree insert")
		} else {
			expect_equal(primary_rc(finalize_rc), primary_rc(rc), "finalize must preserve R-Tree insert failure")
		}
		return rc
	}

	// SQLITE-FEATURE-CONTRACT: extension.rtree.spatial-mutation-boundary.v1
	// Feature: R-Tree virtual tables implement containment, intersection, coordinate rounding, mutation, constraint atomicity, and persistence.
	// SQLite source: https://sqlite.org/rtree.html and the pinned SQLite amalgamation built with SQLITE_ENABLE_RTREE.
	// Requirement: Rectangle predicates return geometrically matching rows, lower/upper floating coordinates round outward, and min greater than max is rejected without insertion.
	// Adversarial cases: Overlap at boundaries, point rectangle at non-binary-exact 0.1, invalid coordinate ordering, bound UPDATE/DELETE, ordered results, and close/reopen.
	// Oracle: Ordered spatial query rowids are combined with stored-coordinate inequalities and an ordinary COUNT(*) before and after the failed insertion.
	// Guardrail: Do not assert exact 32-bit floating representations or count virtual-table creation as containment/intersection coverage.
	test_rtree_sql_contract :: proc() {
		path := temp_db_path("odin_sqlite_optional_rtree.sqlite3")
		defer delete(path)
		clean_db_files(path)
		defer clean_db_files(path)
		db := open_db(path)
		exec_ok(db, "CREATE VIRTUAL TABLE boxes USING rtree(id, minX, maxX, minY, maxY)")
		expect_rc(rtree_insert(db, 1, 0, 10, 0, 10), raw.DONE, "insert box 1")
		expect_rc(rtree_insert(db, 2, 5, 15, 5, 15), raw.DONE, "insert box 2")
		expect_rc(rtree_insert(db, 3, -10, -5, -10, -5), raw.DONE, "insert box 3")
		expect_rc(rtree_insert(db, 4, 0.1, 0.1, 0.1, 0.1), raw.DONE, "insert point box")

		contained := prepare_ok(db, "SELECT id FROM boxes WHERE minX>=?1 AND maxX<=?2 AND minY>=?3 AND maxY<=?4 ORDER BY id")
		bind_f64(contained, 1, 0)
		bind_f64(contained, 2, 10)
		bind_f64(contained, 3, 0)
		bind_f64(contained, 4, 10)
		step_row(contained)
		expect_equal(i64(raw.column_int64(contained, 0)), i64(1), "contained rectangle id")
		step_row(contained)
		expect_equal(i64(raw.column_int64(contained, 0)), i64(4), "contained point id")
		step_done(contained)
		finalize_ok(&contained)

		intersects := prepare_ok(db, "SELECT id FROM boxes WHERE maxX>=?1 AND minX<=?2 AND maxY>=?3 AND minY<=?4 ORDER BY id")
		for index in 1..=4 {
			bind_f64(intersects, i32(index), 8 if index == 1 || index == 3 else 12)
		}
		step_row(intersects)
		expect_equal(i64(raw.column_int64(intersects, 0)), i64(1), "first intersecting rectangle")
		step_row(intersects)
		expect_equal(i64(raw.column_int64(intersects, 0)), i64(2), "second intersecting rectangle")
		step_done(intersects)
		finalize_ok(&intersects)

		rounding := prepare_ok(db, "SELECT minX, maxX, typeof(minX), typeof(maxX) FROM boxes WHERE id=?1")
		bind_i64(rounding, 1, 4)
		step_row(rounding)
		expect(raw.column_double(rounding, 0) <= 0.1, "R-Tree lower bound must round down or remain exact")
		expect(raw.column_double(rounding, 1) >= 0.1, "R-Tree upper bound must round up or remain exact")
		expect_equal(string(raw.column_text(rounding, 2)), "real", "lower coordinate storage type")
		expect_equal(string(raw.column_text(rounding, 3)), "real", "upper coordinate storage type")
		step_done(rounding)
		finalize_ok(&rounding)

		before_count := scalar_i64(db, "SELECT COUNT(*) FROM boxes")
		rc := rtree_insert(db, 99, 10, 9, 0, 1)
		expect_equal(primary_rc(rc), i32(raw.CONSTRAINT), "minX greater than maxX must violate the R-Tree constraint")
		expect_equal(scalar_i64(db, "SELECT COUNT(*) FROM boxes"), before_count, "failed R-Tree insert must be atomic")

		update := prepare_ok(db, "UPDATE boxes SET minX=?1, maxX=?2, minY=?3, maxY=?4 WHERE id=?5")
		bind_f64(update, 1, 20)
		bind_f64(update, 2, 30)
		bind_f64(update, 3, 20)
		bind_f64(update, 4, 30)
		bind_i64(update, 5, 2)
		step_done(update)
		finalize_ok(&update)
		delete_stmt := prepare_ok(db, "DELETE FROM boxes WHERE id=?1")
		bind_i64(delete_stmt, 1, 3)
		step_done(delete_stmt)
		finalize_ok(&delete_stmt)
		close_db(&db)

		db = open_db(path)
		intersects = prepare_ok(db, "SELECT id FROM boxes WHERE maxX>=?1 AND minX<=?2 AND maxY>=?3 AND minY<=?4 ORDER BY id")
		for index in 1..=4 {
			bind_f64(intersects, i32(index), 8 if index == 1 || index == 3 else 12)
		}
		step_row(intersects)
		expect_equal(i64(raw.column_int64(intersects, 0)), i64(1), "only box 1 intersects after persisted update")
		step_done(intersects)
		finalize_ok(&intersects)
		expect_equal(scalar_i64(db, "SELECT COUNT(*) FROM boxes"), i64(3), "R-Tree update/delete persistent row count")
		close_db(&db)
	}

	json_insert :: proc(db: ^raw.Sqlite3, id: i64, document: string) -> i32 {
		stmt := prepare_ok(db, "INSERT INTO json_docs(id, doc) VALUES(?1, ?2)")
		bind_i64(stmt, 1, id)
		bind_text(stmt, 2, document)
		rc := raw.step(stmt)
		finalize_rc := raw.finalize(stmt)
		if rc == raw.DONE {
			expect_rc(finalize_rc, raw.OK, "finalize successful JSON insert")
		} else {
			expect_equal(primary_rc(finalize_rc), primary_rc(rc), "finalize must preserve JSON insert failure")
		}
		return rc
	}

	// SQLITE-FEATURE-CONTRACT: extension.json.functions-operators-tvf.v1
	// Feature: JSON scalar functions, extraction operators, table-valued functions, validation, mutation, and persistence preserve documented SQL types.
	// SQLite source: https://sqlite.org/json1.html and the pinned SQLite JSON implementation.
	// Requirement: json_extract/json_type and ->/->> distinguish JSON text, SQL scalars, JSON null, and missing paths; json_each emits array elements; malformed JSON errors and CHECK rejection is atomic.
	// Adversarial cases: Maximum signed integer, JSON null versus missing SQL NULL, empty array/object, bound paths/documents, ordered json_each rows, malformed input, json_set update, and close/reopen.
	// Oracle: SQLite typeof/json_type, exact scalar values, ordered table-valued rows, constraint result code, unchanged row count, and reopened state provide independent SQL oracles.
	// Guardrail: Do not conflate JSON null with SQL NULL, interpolate JSON into SQL, or accept malformed input based only on an error-message sentence.
	test_json_sql_contract :: proc() {
		path := temp_db_path("odin_sqlite_optional_json.sqlite3")
		defer delete(path)
		clean_db_files(path)
		defer clean_db_files(path)
		db := open_db(path)
		exec_ok(db, "CREATE TABLE json_docs(id INTEGER PRIMARY KEY, doc TEXT NOT NULL CHECK(json_valid(doc)))")
		document := "{\"n\":9223372036854775807,\"nullv\":null,\"arr\":[0,1,2],\"nested\":{\"name\":\"Ada\"}}"
		expect_rc(json_insert(db, 1, document), raw.DONE, "insert complex JSON document")
		expect_rc(json_insert(db, 2, "[]"), raw.DONE, "insert empty JSON array")
		expect_rc(json_insert(db, 3, "{}"), raw.DONE, "insert empty JSON object")

		extract := prepare_ok(db, "SELECT json_extract(?1, ?2), typeof(json_extract(?1, ?2)), (?1 -> ?3), (?1 ->> ?4), json_type(?1, ?5), json_type(?1, ?6)")
		bind_text(extract, 1, document)
		bind_text(extract, 2, "$.n")
		bind_text(extract, 3, "$.nested")
		bind_text(extract, 4, "$.nested.name")
		bind_text(extract, 5, "$.nullv")
		bind_text(extract, 6, "$.missing")
		step_row(extract)
		expect_equal(i64(raw.column_int64(extract, 0)), max(i64), "json_extract maximum signed integer")
		expect_equal(string(raw.column_text(extract, 1)), "integer", "JSON integer SQL type")
		expect_equal(string(raw.column_text(extract, 2)), "{\"name\":\"Ada\"}", "-> must return JSON text")
		expect_equal(string(raw.column_text(extract, 3)), "Ada", "->> must return an SQL text scalar")
		expect_equal(string(raw.column_text(extract, 4)), "null", "json_type must identify JSON null")
		expect_equal(raw.column_type(extract, 5), i32(raw.NULL), "missing JSON path must yield SQL NULL")
		step_done(extract)
		finalize_ok(&extract)

		each := prepare_ok(db, "SELECT key, value, type FROM json_each((SELECT doc FROM json_docs WHERE id=?1), ?2) ORDER BY CAST(key AS INTEGER)")
		bind_i64(each, 1, 1)
		bind_text(each, 2, "$.arr")
		for expected_value := i64(0); expected_value < 3; expected_value += 1 {
			step_row(each)
			expect_equal(i64(raw.column_int64(each, 0)), expected_value, "json_each ordered key")
			expect_equal(i64(raw.column_int64(each, 1)), expected_value, "json_each scalar value")
			expect_equal(string(raw.column_text(each, 2)), "integer", "json_each value type")
		}
		step_done(each)
		finalize_ok(&each)

		valid := prepare_ok(db, "SELECT json_valid(?1)")
		bind_text(valid, 1, "{not-json")
		step_row(valid)
		expect_equal(i64(raw.column_int64(valid, 0)), i64(0), "json_valid malformed input")
		step_done(valid)
		finalize_ok(&valid)
		before_count := scalar_i64(db, "SELECT COUNT(*) FROM json_docs")
		rc := json_insert(db, 99, "{not-json")
		expect_equal(primary_rc(rc), i32(raw.CONSTRAINT), "CHECK(json_valid) must reject malformed input")
		expect_equal(scalar_i64(db, "SELECT COUNT(*) FROM json_docs"), before_count, "rejected JSON insert must be atomic")

		malformed := prepare_ok(db, "SELECT json_extract(?1, ?2)")
		bind_text(malformed, 1, "{not-json")
		bind_text(malformed, 2, "$.x")
		rc = raw.step(malformed)
		expect_equal(primary_rc(rc), i32(raw.ERROR), "json_extract malformed input must fail")
		finalize_rc := raw.finalize(malformed)
		expect_equal(primary_rc(finalize_rc), i32(raw.ERROR), "finalize must preserve malformed JSON error")
		malformed = nil

		update := prepare_ok(db, "UPDATE json_docs SET doc=json_set(doc, ?1, ?2) WHERE id=?3")
		bind_text(update, 1, "$.nested.name")
		bind_text(update, 2, "Grace")
		bind_i64(update, 3, 1)
		step_done(update)
		finalize_ok(&update)
		close_db(&db)

		db = open_db(path)
		check := prepare_ok(db, "SELECT doc ->> ?1, json_extract(doc, ?2), json_type((SELECT doc FROM json_docs WHERE id=?3), '$') FROM json_docs WHERE id=?3")
		bind_text(check, 1, "$.nested.name")
		bind_text(check, 2, "$.n")
		bind_i64(check, 3, 1)
		step_row(check)
		expect_equal(string(raw.column_text(check, 0)), "Grace", "json_set update must persist")
		expect_equal(i64(raw.column_int64(check, 1)), max(i64), "maximum JSON integer must persist exactly")
		expect_equal(string(raw.column_text(check, 2)), "object", "reopened document root type")
		step_done(check)
		finalize_ok(&check)
		expect_equal(scalar_i64(db, "SELECT COUNT(*) FROM json_docs WHERE doc='[]' OR doc='{}'"), i64(2), "empty array and object must persist")
		close_db(&db)
	}
}
