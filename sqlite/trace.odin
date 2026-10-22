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

// trace_settings_from_config copies `config` into DB's inline Trace_Settings
// without allocating. Duplicate (and out-of-range) events are dropped; the first
// occurrence of each event keeps its position.
@(private)
trace_settings_from_config :: proc(config: Trace_Config) -> Trace_Settings {
	settings := Trace_Settings{
		log_expanded_sql    = config.log_expanded_sql,
		log_errors_only     = config.log_errors_only,
		include_row_events  = config.include_row_events,
		include_close_event = config.include_close_event,
	}
	seen: bit_set[Trace_Event]
	for event in config.events {
		if event < min(Trace_Event) || event > max(Trace_Event) || event in seen {
			continue
		}
		seen += {event}
		settings.events[settings.event_count] = event
		settings.event_count += 1
	}
	return settings
}

// trace_settings_to_config returns an owned Trace_Config holding `settings`.
@(private)
trace_settings_to_config :: proc(settings: Trace_Settings, allocator := context.allocator) -> Trace_Config {
	settings := settings
	config := Trace_Config{
		log_expanded_sql    = settings.log_expanded_sql,
		log_errors_only     = settings.log_errors_only,
		include_row_events  = settings.include_row_events,
		include_close_event = settings.include_close_event,
	}
	if settings.event_count > 0 {
		config.events = make([dynamic]Trace_Event, settings.event_count, allocator)
		copy(config.events[:], settings.events[:settings.event_count])
	}
	return config
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
	return trace_emit_allowed(
		config.events[:],
		config.log_errors_only,
		config.include_row_events,
		config.include_close_event,
		event,
		err,
	)
}

// trace_settings_should_emit is trace_should_emit for DB's inline settings.
@(private)
trace_settings_should_emit :: proc(settings: Trace_Settings, event: Trace_Event, err: Error) -> bool {
	settings := settings
	return trace_emit_allowed(
		settings.events[:settings.event_count],
		settings.log_errors_only,
		settings.include_row_events,
		settings.include_close_event,
		event,
		err,
	)
}

@(private)
trace_emit_allowed :: proc(
	events: []Trace_Event,
	log_errors_only: bool,
	include_row_events: bool,
	include_close_event: bool,
	event: Trace_Event,
	err: Error,
) -> bool {
	if log_errors_only && error_is_none(err) {
		return false
	}

	for configured in events {
		if configured == event {
			return true
		}
	}

	if event == .Row && include_row_events {
		return true
	}
	if event == .Close && include_close_event {
		return true
	}

	return false
}

trace_stmt_sql_for_event :: proc(stmt: Stmt, config: Trace_Config) -> string {
	return trace_stmt_sql(stmt, config.log_expanded_sql)
}

@(private)
trace_stmt_sql :: proc(stmt: Stmt, log_expanded_sql: bool) -> string {
	if log_expanded_sql {
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

	// Copied inline: nothing is allocated or freed, so copies of `db` made
	// before or after this call never share (or dangle into) trace storage.
	db.trace_enabled = mask != 0
	db.trace_settings = trace_settings_from_config(config)
	return error_none(), true
}

db_trace_disable :: proc(db: ^DB) -> (Error, bool) {
	if db == nil || db.handle == nil {
		err := error_from_db(DB{}, int(raw.MISUSE))
		error_with_op(&err, "trace_disable")
		return err, false
	}

	db.trace_enabled = false
	db.trace_settings = Trace_Settings{}
	return error_none(), true
}

db_trace_enabled :: proc(db: DB) -> bool {
	return db.handle != nil && db.trace_enabled
}

// db_trace_config returns an owned deep copy. Destroy it with
// trace_config_destroy using the same allocator.
db_trace_config :: proc(db: DB, allocator := context.allocator) -> Trace_Config {
	return trace_settings_to_config(db.trace_settings, allocator)
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
	if !trace_settings_should_emit(db.trace_settings, .Statement, err) {
		return
	}

	sql := trace_stmt_sql(stmt, db.trace_settings.log_expanded_sql)
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
	if !trace_settings_should_emit(db.trace_settings, .Statement, err) {
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
	if !trace_settings_should_emit(db.trace_settings, .Profile, err) {
		return
	}

	sql := trace_stmt_sql(stmt, db.trace_settings.log_expanded_sql)
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
	if !trace_settings_should_emit(db.trace_settings, .Row, err) {
		return
	}

	sql := trace_stmt_sql(stmt, db.trace_settings.log_expanded_sql)
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
	if !trace_settings_should_emit(db.trace_settings, .Close, err) {
		return
	}

	logger(.Close, trace_format_message(.Close, "", detail))
}
