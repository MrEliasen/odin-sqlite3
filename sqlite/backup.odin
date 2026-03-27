package sqlite

import "core:fmt"
import "core:strings"
import raw "raw/generated"

Backup_Progress :: struct {
	remaining_pages: int,
	total_pages:     int,
}

backup_result_from_backup :: proc(backup: Backup, code: int, op: string) -> (Error, bool) {
	if is_ok(code) {
		return error_none(), true
	}

	err_db := DB{}
	if backup.dst_db != nil {
		err_db.handle = backup.dst_db
	} else if backup.src_db != nil {
		err_db.handle = backup.src_db
	}

	err := error_with_op(error_from_db(err_db, code), op)

	if backup.dst_schema_name != "" || backup.src_schema_name != "" {
		err = error_with_context(
			err,
			fmt.tprintf("dst_schema=%s src_schema=%s", backup.dst_schema_name, backup.src_schema_name),
		)
	}

	return err, false
}

backup_progress :: proc(backup: Backup) -> Backup_Progress {
	if backup.handle == nil {
		return Backup_Progress{}
	}

	return Backup_Progress{
		remaining_pages = int(raw.backup_remaining(backup.handle)),
		total_pages     = int(raw.backup_pagecount(backup.handle)),
	}
}

backup_init :: proc(
	dst_db: DB,
	src_db: DB,
	dst_schema: string = "main",
	src_schema: string = "main",
) -> (Backup, Error, bool) {
	if dst_db.handle == nil || src_db.handle == nil {
		err := error_with_op(error_from_db(DB{}, int(raw.MISUSE)), "backup_init")
		err = error_with_context(err, "source and destination databases must both be open")
		return Backup{}, err, false
	}
	if dst_schema == "" || src_schema == "" {
		err := error_with_op(error_from_db(dst_db, int(raw.MISUSE)), "backup_init")
		err = error_with_context(err, "source and destination schema names must be non-empty")
		return Backup{}, err, false
	}

	c_dst_schema := strings.clone_to_cstring(dst_schema)
	defer delete(c_dst_schema)

	c_src_schema := strings.clone_to_cstring(src_schema)
	defer delete(c_src_schema)

	handle := raw.backup_init(dst_db.handle, c_dst_schema, src_db.handle, c_src_schema)
	if handle == nil {
		err := error_with_op(error_from_db(dst_db, db_errcode(dst_db)), "backup_init")
		err = error_with_context(
			err,
			fmt.tprintf("dst_schema=%s src_schema=%s", dst_schema, src_schema),
		)
		return Backup{}, err, false
	}

	backup := Backup{
		handle           = handle,
		src_db           = src_db.handle,
		dst_db           = dst_db.handle,
		src_schema_name  = strings.clone(src_schema),
		dst_schema_name  = strings.clone(dst_schema),
		owned_src_schema = true,
		owned_dst_schema = true,
	}

	return backup, error_none(), true
}

backup_step :: proc(backup: Backup, page_count: int) -> (Backup_Step_Result, Error, bool) {
	if backup.handle == nil {
		err := error_with_op(error_from_db(DB{}, int(raw.MISUSE)), "backup_step")
		return .Invalid, err, false
	}

	rc := raw.backup_step(backup.handle, i32(page_count))
	switch rc {
	case raw.DONE:
		return .Done, error_none(), true
	case raw.OK:
		return .Ok, error_none(), true
	case raw.BUSY:
		return .Busy, error_none(), true
	case raw.LOCKED:
		return .Locked, error_none(), true
	}

	err, ok := backup_result_from_backup(backup, int(rc), "backup_step")
	if !ok {
		return .Invalid, err, false
	}

	return .Invalid, error_none(), false
}

backup_finish :: proc(backup: ^Backup) -> (Error, bool) {
	if backup == nil || backup.handle == nil {
		return error_none(), true
	}

	handle := backup.handle
	backup.handle = nil

	rc := raw.backup_finish(handle)

	if backup.owned_src_schema && backup.src_schema_name != "" {
		delete(backup.src_schema_name)
	}
	if backup.owned_dst_schema && backup.dst_schema_name != "" {
		delete(backup.dst_schema_name)
	}

	backup.src_schema_name = ""
	backup.dst_schema_name = ""
	backup.owned_src_schema = false
	backup.owned_dst_schema = false
	backup.src_db = nil
	backup.dst_db = nil

	if rc != raw.OK {
		err := error_with_op(error_from_db(DB{}, int(rc)), "backup_finish")
		return err, false
	}

	return error_none(), true
}

backup_step_all :: proc(
	backup: ^Backup,
	page_count_per_step: int = -1,
) -> (Backup_Progress, Error, bool) {
	if backup == nil || backup.handle == nil {
		err := error_with_op(error_from_db(DB{}, int(raw.MISUSE)), "backup_step_all")
		return Backup_Progress{}, err, false
	}

	for {
		result, err, ok := backup_step(backup^, page_count_per_step)
		if !ok {
			return backup_progress(backup^), err, false
		}

		switch result {
		case .Done:
			return backup_progress(backup^), error_none(), true
		case .Ok:
			continue
		case .Busy, .Locked:
			wait_err, wait_ok := backup_result_from_backup(backup^, int(raw.BUSY), "backup_step_all")
			if result == .Locked {
				wait_err, wait_ok = backup_result_from_backup(backup^, int(raw.LOCKED), "backup_step_all")
			}
			return backup_progress(backup^), wait_err, wait_ok
		case .Invalid:
			err := error_with_op(error_from_db(DB{}, int(raw.ERROR)), "backup_step_all")
			err = error_with_context(err, "backup_step returned invalid state")
			return backup_progress(backup^), err, false
		}
	}
}