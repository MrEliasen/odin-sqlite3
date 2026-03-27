package sqlite

import "core:strings"
import raw "raw/generated"

Wal_Checkpoint_Result :: struct {
	log_frames:           int,
	checkpointed_frames:  int,
}

db_wal_checkpoint :: proc(
	db: DB,
	mode: Checkpoint_Mode = .Passive,
	schema: string = "",
) -> (Wal_Checkpoint_Result, Error, bool) {
	if db.handle == nil {
		return Wal_Checkpoint_Result{}, error_from_db(db, int(raw.MISUSE), ""), false
	}

	c_schema := cstring(nil)
	if schema != "" {
		c_schema = strings.clone_to_cstring(schema)
	}
	defer delete(c_schema)

	log_frames: i32 = -1
	checkpointed_frames: i32 = -1

	rc := raw.wal_checkpoint_v2(
		db.handle,
		c_schema,
		i32(mode),
		&log_frames,
		&checkpointed_frames,
	)
	if rc != raw.OK {
		return Wal_Checkpoint_Result{
			log_frames          = int(log_frames),
			checkpointed_frames = int(checkpointed_frames),
		}, error_from_db(db, int(rc), ""), false
	}

	return Wal_Checkpoint_Result{
		log_frames          = int(log_frames),
		checkpointed_frames = int(checkpointed_frames),
	}, error_none(), true
}

db_is_interrupted :: proc(db: DB) -> bool {
	if db.handle == nil {
		return false
	}

	return raw.is_interrupted(db.handle) != 0
}

db_wal_checkpoint_passive :: proc(
	db: DB,
	schema: string = "",
) -> (Wal_Checkpoint_Result, Error, bool) {
	return db_wal_checkpoint(db, .Passive, schema)
}

db_wal_checkpoint_full :: proc(
	db: DB,
	schema: string = "",
) -> (Wal_Checkpoint_Result, Error, bool) {
	return db_wal_checkpoint(db, .Full, schema)
}

db_wal_checkpoint_restart :: proc(
	db: DB,
	schema: string = "",
) -> (Wal_Checkpoint_Result, Error, bool) {
	return db_wal_checkpoint(db, .Restart, schema)
}

db_wal_checkpoint_truncate :: proc(
	db: DB,
	schema: string = "",
) -> (Wal_Checkpoint_Result, Error, bool) {
	return db_wal_checkpoint(db, .Truncate, schema)
}