package sqlite

import "core:strings"

cache_init :: proc() -> Stmt_Cache {
	return Stmt_Cache{
		entries = make(map[string]^Cache_Entry),
	}
}

cache_destroy_entry :: proc(cache: ^Stmt_Cache, sql: string, entry_ptr: ^Cache_Entry) -> (Error, bool) {
	if cache == nil {
		return error_none(), true
	}

	lookup_sql := sql
	if entry_ptr != nil && entry_ptr.stmt != nil && entry_ptr.stmt.owned_sql {
		lookup_sql = entry_ptr.stmt.sql
	}

	delete_key(&cache.entries, lookup_sql)

	if entry_ptr != nil {
		if entry_ptr.stmt != nil {
			err, finalize_ok := stmt_finalize(entry_ptr.stmt)
			if !finalize_ok {
				return err, false
			}
			free(entry_ptr.stmt)
		}

		free(entry_ptr)
	}

	return error_none(), true
}

cache_destroy :: proc(cache: ^Stmt_Cache) -> (Error, bool) {
	if cache == nil {
		return error_none(), true
	}

	err, ok := cache_clear(cache)
	if !ok {
		return err, false
	}

	delete(cache.entries)
	return error_none(), true
}

cache_has :: proc(cache: Stmt_Cache, sql: string) -> bool {
	if len(cache.entries) == 0 {
		return false
	}

	_, ok := cache.entries[sql]
	return ok
}

cache_count :: proc(cache: Stmt_Cache) -> int {
	return len(cache.entries)
}

cache_get :: proc(cache: ^Stmt_Cache, sql: string) -> (^Stmt, bool) {
	if cache == nil || len(cache.entries) == 0 {
		return nil, false
	}

	entry_ptr, ok := cache.entries[sql]
	if !ok || entry_ptr == nil || entry_ptr.stmt == nil {
		return nil, false
	}
	if !stmt_is_valid(entry_ptr.stmt^) {
		return nil, false
	}

	entry_ptr.used = true
	return entry_ptr.stmt, true
}

cache_put :: proc(cache: ^Stmt_Cache, stmt: Stmt) -> (Error, bool) {
	if cache == nil {
		return Error{
			code    = 1,
			message = "sqlite: statement cache pointer must not be nil",
		}, false
	}
	if !stmt_is_valid(stmt) {
		return error_from_stmt(stmt, 1), false
	}
	if stmt.sql == "" {
		return error_from_stmt(stmt, 1), false
	}

	owned_sql := strings.clone(stmt.sql)

	if old_ptr, exists := cache.entries[stmt.sql]; exists && old_ptr != nil {
		finalize_err, finalize_ok := cache_destroy_entry(cache, stmt.sql, old_ptr)
		if !finalize_ok {
			delete(owned_sql)
			return finalize_err, false
		}
	}

	stored_stmt := new(Stmt)
	stored_stmt^ = stmt
	stored_stmt.sql = owned_sql
	stored_stmt.owned_sql = true

	entry_ptr := new(Cache_Entry)
	entry_ptr^ = Cache_Entry{
		stmt = stored_stmt,
		used = true,
	}

	cache.entries[owned_sql] = entry_ptr
	return error_none(), true
}

cache_clear :: proc(cache: ^Stmt_Cache) -> (Error, bool) {
	if cache == nil {
		return error_none(), true
	}

	keys: [dynamic]string
	defer delete(keys)
	for sql in cache.entries {
		append(&keys, sql)
	}

	for sql in keys {
		entry_ptr, ok := cache.entries[sql]
		if !ok {
			continue
		}

		err, destroy_ok := cache_destroy_entry(cache, sql, entry_ptr)
		if !destroy_ok {
			return err, false
		}
	}

	return error_none(), true
}

cache_reset_usage :: proc(cache: ^Stmt_Cache) {
	if cache == nil {
		return
	}

	for sql in cache.entries {
		entry_ptr, ok := cache.entries[sql]
		if !ok || entry_ptr == nil {
			continue
		}
		entry_ptr.used = false
	}
}

cache_prune_unused :: proc(cache: ^Stmt_Cache) -> (int, Error, bool) {
	if cache == nil {
		return 0, error_none(), true
	}

	keys_to_remove: [dynamic]string
	defer delete(keys_to_remove)
	for sql, entry_ptr in cache.entries {
		if entry_ptr == nil || !entry_ptr.used {
			append(&keys_to_remove, sql)
		}
	}

	removed := 0
	for sql in keys_to_remove {
		entry_ptr, ok := cache.entries[sql]
		if !ok {
			continue
		}

		err, destroy_ok := cache_destroy_entry(cache, sql, entry_ptr)
		if !destroy_ok {
			return removed, err, false
		}

		removed += 1
	}

	return removed, error_none(), true
}

db_prepare_cached :: proc(
	db: DB,
	cache: ^Stmt_Cache,
	sql: string,
	flags: int = PERSISTENT_PREPARE_FLAGS,
) -> (^Stmt, Error, bool) {
	if cache == nil {
		stmt, err, ok := stmt_prepare(db, sql, flags)
		if !ok {
			return nil, err, false
		}

		stmt_ptr := new(Stmt)
		stmt_ptr^ = stmt
		return stmt_ptr, error_none(), true
	}

	if stmt_ptr, ok := cache_get(cache, sql); ok {
		err, reuse_ok := stmt_reuse(stmt_ptr)
		if !reuse_ok {
			return nil, err, false
		}
		return stmt_ptr, error_none(), true
	}

	stmt, err, ok := stmt_prepare(db, sql, flags)
	if !ok {
		return nil, err, false
	}

	put_err, put_ok := cache_put(cache, stmt)
	if !put_ok {
		temp_stmt := stmt
		_, _ = stmt_finalize(&temp_stmt)
		return nil, put_err, false
	}

	stmt_ptr, found := cache_get(cache, sql)
	if !found || stmt_ptr == nil {
		return nil, error_from_db(db, 1, sql), false
	}

	return stmt_ptr, error_none(), true
}