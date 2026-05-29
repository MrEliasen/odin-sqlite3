package sqlite

import "core:fmt"
import "core:strings"
import raw "raw/generated"

// Error is a value type carrying ownership of its string fields when those
// strings are non-empty.
//
// Ownership contract:
//   - On a successful call (`ok == true`) every wrapper returns `error_none()`
//     which has all-empty strings; no destroy needed.
//   - On a failing call (`ok == false`) the returned Error may carry owned
//     `message` / `sql` / `ctx` / `op` strings allocated from
//     `context.allocator` at the call site. The caller must release them with
//     `error_destroy` once the Error has been logged or transformed, or pass
//     the Error onward to a caller who will.
//   - The helper procs `error_with_op` / `error_with_context` / `error_with_sql`
//     consume their input Error (taking ownership of its existing strings) and
//     return a replacement that holds the new field. Do not keep using the
//     input after passing it in.
//
// `error_string` and `error_summary` allocate via `context.temp_allocator`. The
// returned string is only valid until the next temp-allocator reset. Clone if
// you need to retain it across SQLite calls.
is_ok :: proc(code: int) -> bool {
	return code == int(raw.OK)
}

is_row :: proc(code: int) -> bool {
	return code == int(raw.ROW)
}

is_done :: proc(code: int) -> bool {
	return code == int(raw.DONE)
}

step_result_from_code :: proc(code: int) -> Step_Result {
	if code == int(raw.ROW) {
		return Step_Result.Row
	}
	if code == int(raw.DONE) {
		return Step_Result.Done
	}
	return Step_Result.Invalid
}

// error_none returns a zero-value Error that owns no memory. Safe to discard.
error_none :: proc() -> Error {
	return Error{}
}

error_is_none :: proc(err: Error) -> bool {
	return err.code == 0 && err.extended_code == 0 && err.message == "" && err.sql == "" && err.ctx == "" && err.op == ""
}

// error_make constructs an Error with a cloned message. Use this rather than
// `Error{message = "..."}` literals so the returned Error is safe to release
// with `error_destroy`.
error_make :: proc(code: int, message: string = "") -> Error {
	err := Error{code = code, extended_code = code}
	if message != "" {
		err.message = strings.clone(message)
	}
	return err
}

// error_destroy releases any owned strings inside err. Safe to call on a
// zero-value Error, and idempotent: a second call is a no-op because the
// fields have been zeroed.
error_destroy :: proc(err: ^Error) {
	if err == nil {
		return
	}
	if len(err.message) > 0 {
		delete(err.message)
		err.message = ""
	}
	if len(err.sql) > 0 {
		delete(err.sql)
		err.sql = ""
	}
	if len(err.ctx) > 0 {
		delete(err.ctx)
		err.ctx = ""
	}
	if len(err.op) > 0 {
		delete(err.op)
		err.op = ""
	}
	err.code = 0
	err.extended_code = 0
}

// error_with_context attaches `ctx` to `err` in-place, freeing any prior ctx.
// Pass an empty `ctx` to clear the field. Safe on nil err pointer.
error_with_context :: proc(err: ^Error, ctx: string) {
	if err == nil {
		return
	}
	if len(err.ctx) > 0 {
		delete(err.ctx)
		err.ctx = ""
	}
	if ctx != "" {
		err.ctx = strings.clone(ctx)
	}
}

// error_with_op attaches `op` to `err` in-place, freeing any prior op.
error_with_op :: proc(err: ^Error, op: string) {
	if err == nil {
		return
	}
	if len(err.op) > 0 {
		delete(err.op)
		err.op = ""
	}
	if op != "" {
		err.op = strings.clone(op)
	}
}

// error_with_sql attaches `sql` to `err` in-place, freeing any prior sql.
error_with_sql :: proc(err: ^Error, sql: string) {
	if err == nil {
		return
	}
	if len(err.sql) > 0 {
		delete(err.sql)
		err.sql = ""
	}
	if sql != "" {
		err.sql = strings.clone(sql)
	}
}

error_has_sql :: proc(err: Error) -> bool {
	return err.sql != ""
}

error_has_context :: proc(err: Error) -> bool {
	return err.ctx != ""
}

error_has_op :: proc(err: Error) -> bool {
	return err.op != ""
}

// error_primary_code masks an SQLite result code down to its primary 8-bit
// portion. Extended result codes are constructed as
// `(primary | (extension << 8))`, so masking with 0xFF recovers the primary.
error_primary_code :: proc(code: int) -> int {
	return code & 0xFF
}

// error_from_db builds an Error from a SQLite return code, cloning the
// connection's error message into the returned Error. `sql` is also cloned if
// non-empty.
//
// `err.code` is normalized to the primary SQLite result code (e.g. CONSTRAINT
// = 19) and `err.extended_code` carries the extended variant (e.g.
// CONSTRAINT_UNIQUE = 2067). Callers can switch on `err.code` for general
// error handling and inspect `err.extended_code` for fine-grained branches.
//
// If the supplied `code` matches the connection's current `errcode`, the
// extended variant from `sqlite3_extended_errcode` overrides — this is the
// common case after a SQLite call returned a CONSTRAINT primary code. When
// the caller is synthesizing an error (e.g. raw.MISMATCH from a wrapper-side
// range check), the supplied `code` is honored as-is.
error_from_db :: proc(db: DB, code: int, sql: string = "") -> Error {
	primary := error_primary_code(code)
	err := Error{
		code          = primary,
		extended_code = code,
	}

	if sql != "" {
		err.sql = strings.clone(sql)
	}

	if db.handle != nil {
		// `connection_code` may be primary or extended depending on whether
		// `sqlite3_extended_result_codes` is enabled on the connection. We
		// trust SQLite-state-driven enrichment only when the supplied code is
		// the same code SQLite is currently reporting — that prevents a
		// wrapper-synthesized error (e.g. MISMATCH from a range check) from
		// picking up the unrelated errmsg of a prior SQLite call.
		connection_code := int(raw.errcode(db.handle))
		connection_primary := error_primary_code(connection_code)
		caller_matches_connection := connection_code != 0 &&
			(connection_code == code || connection_primary == primary)

		if caller_matches_connection {
			ext := int(raw.extended_errcode(db.handle))
			if ext != 0 {
				err.extended_code = ext
				err.code = error_primary_code(ext)
			}

			msg := raw.errmsg(db.handle)
			if msg != nil {
				err.message = strings.clone(string(msg))
			}
		}
	}

	if err.message == "" {
		msg := raw.errstr(i32(err.code))
		if msg != nil {
			err.message = strings.clone(string(msg))
		}
	}

	return err
}

error_from_stmt :: proc(stmt: Stmt, code: int) -> Error {
	if stmt.db != nil {
		return error_from_db(DB{handle = stmt.db}, code, stmt.sql)
	}

	err := Error{
		code          = error_primary_code(code),
		extended_code = code,
	}

	if stmt.sql != "" {
		err.sql = strings.clone(stmt.sql)
	}

	msg := raw.errstr(i32(err.code))
	if msg != nil {
		err.message = strings.clone(string(msg))
	}

	return err
}

result_from_db :: proc(db: DB, code: int, sql: string = "") -> (Error, bool) {
	if is_ok(code) {
		return error_none(), true
	}
	return error_from_db(db, code, sql), false
}

result_from_stmt :: proc(stmt: Stmt, code: int) -> (Error, bool) {
	if is_ok(code) {
		return error_none(), true
	}
	return error_from_stmt(stmt, code), false
}

step_result_or_error :: proc(stmt: Stmt, code: int) -> (Step_Result, Error, bool) {
	if code == int(raw.ROW) {
		return Step_Result.Row, error_none(), true
	}
	if code == int(raw.DONE) {
		return Step_Result.Done, error_none(), true
	}
	return Step_Result.Invalid, error_from_stmt(stmt, code), false
}

error_ok :: proc(err: Error) -> bool {
	return err.code == 0
}

error_code_name :: proc(code: int) -> string {
	switch code {
	case int(raw.OK):
		return "SQLITE_OK"
	case int(raw.ERROR):
		return "SQLITE_ERROR"
	case int(raw.INTERNAL):
		return "SQLITE_INTERNAL"
	case int(raw.PERM):
		return "SQLITE_PERM"
	case int(raw.ABORT):
		return "SQLITE_ABORT"
	case int(raw.BUSY):
		return "SQLITE_BUSY"
	case int(raw.LOCKED):
		return "SQLITE_LOCKED"
	case int(raw.NOMEM):
		return "SQLITE_NOMEM"
	case int(raw.READONLY):
		return "SQLITE_READONLY"
	case int(raw.INTERRUPT):
		return "SQLITE_INTERRUPT"
	case int(raw.IOERR):
		return "SQLITE_IOERR"
	case int(raw.CORRUPT):
		return "SQLITE_CORRUPT"
	case int(raw.NOTFOUND):
		return "SQLITE_NOTFOUND"
	case int(raw.FULL):
		return "SQLITE_FULL"
	case int(raw.CANTOPEN):
		return "SQLITE_CANTOPEN"
	case int(raw.PROTOCOL):
		return "SQLITE_PROTOCOL"
	case int(raw.EMPTY):
		return "SQLITE_EMPTY"
	case int(raw.SCHEMA):
		return "SQLITE_SCHEMA"
	case int(raw.TOOBIG):
		return "SQLITE_TOOBIG"
	case int(raw.CONSTRAINT):
		return "SQLITE_CONSTRAINT"
	case int(raw.MISMATCH):
		return "SQLITE_MISMATCH"
	case int(raw.MISUSE):
		return "SQLITE_MISUSE"
	case int(raw.NOLFS):
		return "SQLITE_NOLFS"
	case int(raw.AUTH):
		return "SQLITE_AUTH"
	case int(raw.FORMAT):
		return "SQLITE_FORMAT"
	case int(raw.RANGE):
		return "SQLITE_RANGE"
	case int(raw.NOTADB):
		return "SQLITE_NOTADB"
	case int(raw.NOTICE):
		return "SQLITE_NOTICE"
	case int(raw.WARNING):
		return "SQLITE_WARNING"
	case int(raw.ROW):
		return "SQLITE_ROW"
	case int(raw.DONE):
		return "SQLITE_DONE"
	}

	return fmt.tprintf("SQLITE_%d", code)
}

// error_summary renders a short single-line summary using context.temp_allocator.
error_summary :: proc(err: Error) -> string {
	if error_is_none(err) {
		return "sqlite: ok"
	}

	code_name := error_code_name(err.code)

	if err.message != "" {
		return fmt.tprintf("%s (%d): %s", code_name, err.code, err.message)
	}

	return fmt.tprintf("%s (%d)", code_name, err.code)
}

// error_string renders a detailed multi-field summary using context.temp_allocator.
// The returned string is only valid until the next temp-allocator reset.
error_string :: proc(err: Error) -> string {
	if error_is_none(err) {
		return "sqlite: ok"
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "sqlite: code=%d code_name=%q extended=%d",
		err.code, error_code_name(err.code), err.extended_code)
	if err.op != "" {
		fmt.sbprintf(&b, " op=%q", err.op)
	}
	if err.message != "" {
		fmt.sbprintf(&b, " message=%q", err.message)
	}
	if err.ctx != "" {
		fmt.sbprintf(&b, " context=%q", err.ctx)
	}
	if err.sql != "" {
		fmt.sbprintf(&b, " sql=%q", err.sql)
	}
	return strings.to_string(b)
}
