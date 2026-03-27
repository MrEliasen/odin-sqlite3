package sqlite

import "core:fmt"
import raw "raw/generated"

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

trace_callback_default :: proc "c" (trace_type: u32, ctx: rawptr, p: rawptr, x: rawptr) -> i32 {
	_ = ctx
	_ = p
	_ = x
	_ = trace_type
	return 0
}

db_trace_enable :: proc(db: ^DB, config: Trace_Config) -> (Error, bool) {
	if db == nil || db.handle == nil {
		return error_with_op(error_from_db(DB{}, int(raw.MISUSE)), "trace_enable"), false
	}

	mask := trace_event_mask(config)
	rc := raw.trace_v2(db.handle, mask, trace_callback_default, nil)
	if rc != raw.OK {
		return error_with_op(error_from_db(db^, int(rc)), "trace_enable"), false
	}

	delete(db.trace_config.events)

	new_config := config
	if len(config.events) > 0 {
		new_config.events = make([dynamic]Trace_Event, len(config.events))
		copy(new_config.events[:], config.events[:])
	} else {
		new_config.events = nil
	}

	db.trace_enabled = mask != 0
	db.trace_config = new_config
	return error_none(), true
}

db_trace_disable :: proc(db: ^DB) -> (Error, bool) {
	if db == nil || db.handle == nil {
		return error_with_op(error_from_db(DB{}, int(raw.MISUSE)), "trace_disable"), false
	}

	rc := raw.trace_v2(db.handle, 0, nil, nil)
	if rc != raw.OK {
		return error_with_op(error_from_db(db^, int(rc)), "trace_disable"), false
	}

	delete(db.trace_config.events)

	db.trace_enabled = false
	db.trace_config = Trace_Config{}
	return error_none(), true
}

db_trace_enabled :: proc(db: DB) -> bool {
	return db.handle != nil && db.trace_enabled
}

db_trace_config :: proc(db: DB) -> Trace_Config {
	return db.trace_config
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