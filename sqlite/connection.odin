package sqlite

import "core:strings"
import raw "raw/generated"

// Request SQLite's serialized per-connection mode by default. Callers may
// supply different flags, but must externally serialize every use of a DB and
// its derived statements/blobs/backups if OPEN_NOMUTEX is selected. The
// wrapper's own mutable trace and statement-cache state is not synchronized.
DEFAULT_OPEN_FLAGS :: int(raw.OPEN_READWRITE | raw.OPEN_CREATE | raw.OPEN_URI | raw.OPEN_FULLMUTEX)

db_open :: proc(path: string, flags: int = DEFAULT_OPEN_FLAGS, vfs: string = "") -> (DB, Error, bool) {
	db := DB{}
	if flags < 0 || flags > int(max(i32)) {
		err := error_make(int(raw.RANGE), "sqlite: open flags exceed SQLite's i32 range")
		error_with_op(&err, "db_open")
		return DB{}, err, false
	}

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	c_vfs := cstring(nil)
	if vfs != "" {
		c_vfs = strings.clone_to_cstring(vfs)
	}
	defer delete(c_vfs)

	rc := raw.open_v2(c_path, &db.handle, i32(flags), c_vfs)
	if rc != raw.OK {
		err := error_from_db(db, int(rc), "")
		if db.handle != nil {
			_ = raw.close_v2(db.handle)
			db.handle = nil
		}
		return DB{}, err, false
	}

	rc = raw.extended_result_codes(db.handle, 1)
	if rc != raw.OK {
		err := error_from_db(db, int(rc), "")
		_ = raw.close_v2(db.handle)
		db.handle = nil
		return DB{}, err, false
	}

	return db, error_none(), true
}

db_open_into :: proc(db: ^DB, path: string, flags: int = DEFAULT_OPEN_FLAGS, vfs: string = "") -> (Error, bool) {
	if db == nil {
		return error_make(int(raw.MISUSE), "sqlite: db_open_into requires a non-nil DB pointer"), false
	}
	if db.handle != nil {
		return error_make(int(raw.MISUSE), "sqlite: db_open_into refuses to overwrite an already-open DB; close it first"), false
	}

	opened, err, ok := db_open(path, flags, vfs)
	if !ok {
		return err, false
	}

	db^ = opened
	return error_none(), true
}

db_close :: proc(db: ^DB) -> (Error, bool) {
	if db == nil || db.handle == nil {
		return error_none(), true
	}

	rc := raw.close_v2(db.handle)
	if rc != raw.OK {
		return error_from_db(db^, int(rc), ""), false
	}

	if len(db.trace_config.events) > 0 {
		trace_config_destroy(&db.trace_config, db.trace_allocator)
	}
	db.trace_config = Trace_Config{}
	db.trace_allocator = {}
	db.trace_enabled = false
	db.handle = nil
	return error_none(), true
}

// db_close_cleanup is for deferred cleanup paths without an error result
// channel. Prefer db_close when the caller can surface cleanup failures.
db_close_cleanup :: proc(db: ^DB) {
	err, _ := db_close(db)
	error_destroy(&err)
}

// db_errmsg returns SQLite's last error message for `db`.
//
// Lifetime: BORROWED. Per SQLite docs the pointer is valid only until the next
// SQLite call on the same DB. Clone with `strings.clone` if you need to retain
// the message. Most callers should prefer the `Error` value returned by
// wrapper procs — its `message` field is an owned copy.
db_errmsg :: proc(db: DB) -> string {
	if db.handle == nil {
		return ""
	}

	msg := raw.errmsg(db.handle)
	if msg == nil {
		return ""
	}

	return string(msg)
}

db_errcode :: proc(db: DB) -> int {
	if db.handle == nil {
		return 0
	}

	return int(raw.errcode(db.handle))
}

db_extended_errcode :: proc(db: DB) -> int {
	if db.handle == nil {
		return 0
	}

	return int(raw.extended_errcode(db.handle))
}

// db_errstr returns SQLite's English-language explanation of `code`.
//
// Lifetime: BORROWED from SQLite's static error-string table; valid for the
// program's lifetime (sqlite3.h: "The memory ... is managed internally and must
// not be freed").
db_errstr :: proc(code: int) -> string {
	if code < int(min(i32)) || code > int(max(i32)) {
		return ""
	}
	msg := raw.errstr(i32(code))
	if msg == nil {
		return ""
	}
	return string(msg)
}

db_set_extended_errors :: proc(db: DB, enabled: bool) -> (Error, bool) {
	if db.handle == nil {
		return error_from_db(db, int(raw.MISUSE), ""), false
	}

	onoff := 0
	if enabled {
		onoff = 1
	}

	rc := raw.extended_result_codes(db.handle, i32(onoff))
	return result_from_db(db, int(rc))
}

db_set_busy_timeout :: proc(db: DB, timeout_ms: int) -> (Error, bool) {
	if db.handle == nil {
		return error_from_db(db, int(raw.MISUSE), ""), false
	}
	if timeout_ms < int(min(i32)) || timeout_ms > int(max(i32)) {
		err := error_from_db(db, int(raw.RANGE))
		error_with_op(&err, "db_set_busy_timeout")
		error_with_context(&err, "timeout exceeds SQLite's i32 millisecond range")
		return err, false
	}

	rc := raw.busy_timeout(db.handle, i32(timeout_ms))
	return result_from_db(db, int(rc))
}

db_interrupt :: proc(db: DB) {
	if db.handle == nil {
		return
	}

	raw.interrupt(db.handle)
}

db_in_transaction :: proc(db: DB) -> bool {
	if db.handle == nil {
		return false
	}

	return raw.get_autocommit(db.handle) == 0
}
