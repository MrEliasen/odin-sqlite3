package sqlite

import "core:fmt"
import raw "raw/generated"

trace_config_clone :: proc(config: Trace_Config, allocator := context.allocator) -> Trace_Config {
	out := config
	if len(config.events) > 0 {
		out.events = make([dynamic]Trace_Event, len(config.events), allocator)
		copy(out.events[:], config.events[:])
	} else {
		out.events = nil
	}
	return out
}

trace_config_destroy :: proc(config: ^Trace_Config, allocator := context.allocator) {
	if config == nil {
		return
	}
	// Dynamic arrays retain their allocator internally.
	_ = allocator
	delete(config.events)
	config^ = Trace_Config{}
}

trace_event_mask :: proc(config: Trace_Config) -> u32 {
	mask := u32(0)

	for event in config.events {
		switch event {
		case .Statement:
			mask |= u32(raw.TRACE_STMT)
		case .Profile:
			mask |= u32(raw.TRACE_PROFILE)
		case .Row:
			mask |= u32(raw.TRACE_ROW)
		case .Close:
			mask |= u32(raw.TRACE_CLOSE)
		}
	}

	if config.include_row_events {
		mask |= u32(raw.TRACE_ROW)
	}
	if config.include_close_event {
		mask |= u32(raw.TRACE_CLOSE)
	}

	return mask
}

trace_event_name :: proc(event: Trace_Event) -> string {
	switch event {
	case .Statement:
		return "statement"
	case .Profile:
		return "profile"
	case .Row:
		return "row"
	case .Close:
		return "close"
	}

	return "unknown"
}

trace_should_emit :: proc(config: Trace_Config, event: Trace_Event, err: Error = Error{}) -> bool {
	if config.log_errors_only && error_is_none(err) {
		return false
	}

	for configured in config.events {
		if configured == event {
			return true
		}
	}

	if event == .Row && config.include_row_events {
		return true
	}
	if event == .Close && config.include_close_event {
		return true
	}

	return false
}

trace_stmt_sql_for_event :: proc(stmt: Stmt, config: Trace_Config) -> string {
	if config.log_expanded_sql {
		expanded := stmt_expanded_sql(stmt, context.temp_allocator)
		if expanded != "" {
			return expanded
		}
	}
	return stmt_sql(stmt)
}

trace_format_message :: proc(event: Trace_Event, sql: string, detail: string = "") -> string {
	prefix := fmt.tprintf("sqlite trace [%s]", trace_event_name(event))

	if sql != "" && detail != "" {
		return fmt.tprintf("%s sql=%q detail=%q", prefix, sql, detail)
	}
	if sql != "" {
		return fmt.tprintf("%s sql=%q", prefix, sql)
	}
	if detail != "" {
		return fmt.tprintf("%s detail=%q", prefix, detail)
	}
	return prefix
}

trace_default_logger :: proc(event: Trace_Event, message: string) {
	_ = event
	fmt.println(message)
}

// db_trace_enable configures wrapper-side trace logging on `db`. This does NOT
// register a SQLite-side trace callback (sqlite3_trace_v2). The wrapper's
// trace helpers — `db_trace_log_stmt`, `db_trace_log_profile`,
// `db_trace_log_row`, `db_trace_log_close` — are invoked by application code at
// the moments where logging is wanted, and they check the configured mask
// before dispatching to the supplied logger.
//
// The earlier design registered a no-op C callback with SQLite for every event
// the mask covered, which added overhead with no observable effect. If you
// need actual SQLite-internal trace events, call `raw.trace_v2` directly.
db_trace_enable :: proc(db: ^DB, config: Trace_Config) -> (Error, bool) {
	if db == nil || db.handle == nil {
		err := error_from_db(DB{}, int(raw.MISUSE))
		error_with_op(&err, "trace_enable")
		return err, false
	}

	mask := trace_event_mask(config)

	// Clone first because config may itself be a snapshot returned from this
	// DB. Deleting the old list before copying would read freed memory.
	new_config := trace_config_clone(config, context.allocator)
	if len(db.trace_config.events) > 0 {
		trace_config_destroy(&db.trace_config, db.trace_allocator)
	}

	db.trace_enabled = mask != 0
	db.trace_config = new_config
	db.trace_allocator = context.allocator
	return error_none(), true
}

db_trace_disable :: proc(db: ^DB) -> (Error, bool) {
	if db == nil || db.handle == nil {
		err := error_from_db(DB{}, int(raw.MISUSE))
		error_with_op(&err, "trace_disable")
		return err, false
	}

	if len(db.trace_config.events) > 0 {
		trace_config_destroy(&db.trace_config, db.trace_allocator)
	}

	db.trace_enabled = false
	db.trace_config = Trace_Config{}
	db.trace_allocator = {}
	return error_none(), true
}

db_trace_enabled :: proc(db: DB) -> bool {
	return db.handle != nil && db.trace_enabled
}

// db_trace_config returns an owned deep copy. Destroy it with
// trace_config_destroy using the same allocator.
db_trace_config :: proc(db: DB, allocator := context.allocator) -> Trace_Config {
	return trace_config_clone(db.trace_config, allocator)
}

db_trace_log_stmt :: proc(
	db: DB,
	stmt: Stmt,
	logger: Trace_Log_Proc = trace_default_logger,
	detail: string = "",
	err: Error = Error{},
) {
	if !db_trace_enabled(db) {
		return
	}
	if logger == nil {
		return
	}
	if !trace_should_emit(db.trace_config, .Statement, err) {
		return
	}

	sql := trace_stmt_sql_for_event(stmt, db.trace_config)
	logger(.Statement, trace_format_message(.Statement, sql, detail))
}

db_trace_log_sql :: proc(
	db: DB,
	sql: string,
	logger: Trace_Log_Proc = trace_default_logger,
	detail: string = "",
	err: Error = Error{},
) {
	if !db_trace_enabled(db) {
		return
	}
	if logger == nil {
		return
	}
	if !trace_should_emit(db.trace_config, .Statement, err) {
		return
	}

	logger(.Statement, trace_format_message(.Statement, sql, detail))
}

db_trace_log_profile :: proc(
	db: DB,
	stmt: Stmt,
	elapsed_ns: i64,
	logger: Trace_Log_Proc = trace_default_logger,
	err: Error = Error{},
) {
	if !db_trace_enabled(db) {
		return
	}
	if logger == nil {
		return
	}
	if !trace_should_emit(db.trace_config, .Profile, err) {
		return
	}

	sql := trace_stmt_sql_for_event(stmt, db.trace_config)
	detail := fmt.tprintf("elapsed_ns=%d", elapsed_ns)
	logger(.Profile, trace_format_message(.Profile, sql, detail))
}

db_trace_log_row :: proc(
	db: DB,
	stmt: Stmt,
	logger: Trace_Log_Proc = trace_default_logger,
	detail: string = "",
	err: Error = Error{},
) {
	if !db_trace_enabled(db) {
		return
	}
	if logger == nil {
		return
	}
	if !trace_should_emit(db.trace_config, .Row, err) {
		return
	}

	sql := trace_stmt_sql_for_event(stmt, db.trace_config)
	logger(.Row, trace_format_message(.Row, sql, detail))
}

db_trace_log_close :: proc(
	db: DB,
	logger: Trace_Log_Proc = trace_default_logger,
	detail: string = "",
	err: Error = Error{},
) {
	if !db_trace_enabled(db) {
		return
	}
	if logger == nil {
		return
	}
	if !trace_should_emit(db.trace_config, .Close, err) {
		return
	}

	logger(.Close, trace_format_message(.Close, "", detail))
}
