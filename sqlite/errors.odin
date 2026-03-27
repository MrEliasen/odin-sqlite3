package sqlite

import "core:fmt"
import raw "raw/generated"

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

error_none :: proc() -> Error {
	return Error{}
}

error_is_none :: proc(err: Error) -> bool {
	return err.code == 0 && err.extended_code == 0 && err.message == "" && err.sql == "" && err.ctx == "" && err.op == ""
}

error_with_context :: proc(err: Error, ctx: string) -> Error {
	if ctx == "" {
		return err
	}

	out := err
	out.ctx = ctx
	return out
}

error_with_op :: proc(err: Error, op: string) -> Error {
	if op == "" {
		return err
	}

	out := err
	out.op = op
	return out
}

error_with_sql :: proc(err: Error, sql: string) -> Error {
	if sql == "" {
		return err
	}

	out := err
	out.sql = sql
	return out
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

error_from_db :: proc(db: DB, code: int, sql: string = "") -> Error {
	err := Error{
		code = code,
		sql  = sql,
	}

	if db.handle != nil {
		err.extended_code = int(raw.extended_errcode(db.handle))

		msg := raw.errmsg(db.handle)
		if msg != nil {
			err.message = string(msg)
		}
	} else {
		err.extended_code = code

		msg := raw.errstr(i32(code))
		if msg != nil {
			err.message = string(msg)
		}
	}

	if err.message == "" {
		msg := raw.errstr(i32(code))
		if msg != nil {
			err.message = string(msg)
		}
	}

	return err
}

error_from_stmt :: proc(stmt: Stmt, code: int) -> Error {
	if stmt.db != nil {
		return error_from_db(DB{handle = stmt.db}, code, stmt.sql)
	}

	err := Error{
		code          = code,
		extended_code = code,
		sql           = stmt.sql,
	}

	msg := raw.errstr(i32(code))
	if msg != nil {
		err.message = string(msg)
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

error_string :: proc(err: Error) -> string {
	if error_is_none(err) {
		return "sqlite: ok"
	}

	if err.op != "" && err.message != "" && err.ctx != "" && err.sql != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d op=%q message=%q context=%q sql=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.op,
			err.message,
			err.ctx,
			err.sql,
		)
	}
	if err.op != "" && err.message != "" && err.ctx != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d op=%q message=%q context=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.op,
			err.message,
			err.ctx,
		)
	}
	if err.op != "" && err.message != "" && err.sql != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d op=%q message=%q sql=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.op,
			err.message,
			err.sql,
		)
	}
	if err.message != "" && err.ctx != "" && err.sql != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d message=%q context=%q sql=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.message,
			err.ctx,
			err.sql,
		)
	}
	if err.op != "" && err.ctx != "" && err.sql != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d op=%q context=%q sql=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.op,
			err.ctx,
			err.sql,
		)
	}
	if err.op != "" && err.message != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d op=%q message=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.op,
			err.message,
		)
	}
	if err.op != "" && err.ctx != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d op=%q context=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.op,
			err.ctx,
		)
	}
	if err.op != "" && err.sql != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d op=%q sql=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.op,
			err.sql,
		)
	}
	if err.message != "" && err.ctx != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d message=%q context=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.message,
			err.ctx,
		)
	}
	if err.message != "" && err.sql != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d message=%q sql=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.message,
			err.sql,
		)
	}
	if err.ctx != "" && err.sql != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d context=%q sql=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.ctx,
			err.sql,
		)
	}
	if err.op != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d op=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.op,
		)
	}
	if err.message != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d message=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.message,
		)
	}
	if err.ctx != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d context=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.ctx,
		)
	}
	if err.sql != "" {
		return fmt.tprintf(
			"sqlite: code=%d code_name=%q extended=%d sql=%q",
			err.code,
			error_code_name(err.code),
			err.extended_code,
			err.sql,
		)
	}

	return fmt.tprintf(
		"sqlite: code=%d code_name=%q extended=%d",
		err.code,
		error_code_name(err.code),
		err.extended_code,
	)
}