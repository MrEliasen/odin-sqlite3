package sqlite

import raw "raw/generated"

DB :: struct {
	handle:        ^raw.Sqlite3,
	trace_enabled: bool,
	trace_config:  Trace_Config,
}

Stmt :: struct {
	handle:             ^raw.Stmt,
	db:                 ^raw.Sqlite3,
	sql:                string,
	owned_sql:          bool,
	bound_text_storage: [dynamic]cstring,
	bound_blob_storage: [dynamic][]u8,
}

Blob :: struct {
	handle:      ^raw.Blob,
	db:          ^raw.Sqlite3,
	schema_name: string,
	table_name:  string,
	column_name: string,
	rowid:       i64,
	writeable:   bool,
}

Backup :: struct {
	handle:            ^raw.Backup,
	src_db:            ^raw.Sqlite3,
	dst_db:            ^raw.Sqlite3,
	src_schema_name:   string,
	dst_schema_name:   string,
	owned_src_schema:  bool,
	owned_dst_schema:  bool,
}

Step_Result :: enum {
	Invalid,
	Row,
	Done,
}

Checkpoint_Mode :: enum i32 {
	Noop     = i32(raw.CHECKPOINT_NOOP),
	Passive  = i32(raw.CHECKPOINT_PASSIVE),
	Full     = i32(raw.CHECKPOINT_FULL),
	Restart  = i32(raw.CHECKPOINT_RESTART),
	Truncate = i32(raw.CHECKPOINT_TRUNCATE),
}

Cache_Entry :: struct {
	stmt: ^Stmt,
	used: bool,
}

Stmt_Cache :: struct {
	entries: map[string]^Cache_Entry,
}

Error :: struct {
	code:          int,
	extended_code: int,
	message:       string,
	sql:           string,
	ctx:           string,
	op:            string,
}

Trace_Event :: enum {
	Statement,
	Profile,
	Row,
	Close,
}

Trace_Config :: struct {
	events:              [dynamic]Trace_Event,
	log_expanded_sql:    bool,
	log_errors_only:     bool,
	include_row_events:  bool,
	include_close_event: bool,
}

Blob_Open_Flags :: enum i32 {
	ReadOnly  = 0,
	ReadWrite = 1,
}

Backup_Step_Result :: enum {
	Invalid,
	Done,
	Busy,
	Locked,
	Ok,
}

Trace_Log_Proc :: proc(event: Trace_Event, message: string)

Bind_Kind :: enum {
	Null,
	I32,
	I64,
	F64,
	Bool,
	Text,
	Blob,
}

Bind_Value :: union #no_nil {
	i32,
	i64,
	f64,
	bool,
	string,
	[]u8,
}

Bind_Arg :: struct {
	kind:  Bind_Kind,
	value: Bind_Value,
}

bind_arg_null :: proc() -> Bind_Arg {
	return Bind_Arg{
		kind  = .Null,
		value = false,
	}
}

bind_arg_i32 :: proc(v: i32) -> Bind_Arg {
	return Bind_Arg{
		kind  = .I32,
		value = v,
	}
}

bind_arg_i64 :: proc(v: i64) -> Bind_Arg {
	return Bind_Arg{
		kind  = .I64,
		value = v,
	}
}

bind_arg_f64 :: proc(v: f64) -> Bind_Arg {
	return Bind_Arg{
		kind  = .F64,
		value = v,
	}
}

bind_arg_bool :: proc(v: bool) -> Bind_Arg {
	return Bind_Arg{
		kind  = .Bool,
		value = v,
	}
}

bind_arg_text :: proc(v: string) -> Bind_Arg {
	return Bind_Arg{
		kind  = .Text,
		value = v,
	}
}

bind_arg_blob :: proc(v: []u8) -> Bind_Arg {
	return Bind_Arg{
		kind  = .Blob,
		value = v,
	}
}

trace_config_default :: proc() -> Trace_Config {
	return Trace_Config{}
}

db_is_valid :: proc(db: DB) -> bool {
	return db.handle != nil
}

db_is_closed :: proc(db: DB) -> bool {
	return db.handle == nil
}

stmt_is_valid :: proc(stmt: Stmt) -> bool {
	return stmt.handle != nil
}

stmt_is_closed :: proc(stmt: Stmt) -> bool {
	return stmt.handle == nil
}

blob_is_valid :: proc(blob: Blob) -> bool {
	return blob.handle != nil
}

backup_is_valid :: proc(backup: Backup) -> bool {
	return backup.handle != nil
}