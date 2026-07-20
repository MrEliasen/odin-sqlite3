package sqlite

import "core:strings"
import raw "raw/generated"

cache_init :: proc() -> Stmt_Cache {
	return Stmt_Cache{
		entries = make(map[Stmt_Cache_Key]^Cache_Entry),
	}
}

@(private)
cache_flags_valid :: proc(flags: int) -> bool {
	return flags >= 0 && u64(flags) <= u64(max(u32))
}

@(private)
cache_key :: proc(sql: string, flags: u32) -> Stmt_Cache_Key {
	return Stmt_Cache_Key{sql = sql, flags = flags}
}

// cache_destroy_entry removes the entry from the cache and releases its heap
// allocations regardless of stmt_finalize's result. If finalize returns an
// Error, that Error is propagated to the caller — the entry/stmt have still
// been freed by the time the proc returns.
cache_destroy_entry :: proc(cache: ^Stmt_Cache, key: Stmt_Cache_Key, entry_ptr: ^Cache_Entry) -> (Error, bool) {
	if cache == nil {
		return error_none(), true
	}

	delete_key(&cache.entries, key)

	if entry_ptr == nil {
		if len(cache.entries) == 0 {
			cache.db = nil
		}
		return error_none(), true
	}

	finalize_err := error_none()
	finalize_ok := true
	if entry_ptr.stmt != nil {
		fe, fo := stmt_finalize(entry_ptr.stmt)
		finalize_err = fe
		finalize_ok = fo
		free(entry_ptr.stmt)
	}

	free(entry_ptr)
	if len(cache.entries) == 0 {
		cache.db = nil
	}

	return finalize_err, finalize_ok
}

cache_destroy :: proc(cache: ^Stmt_Cache) -> (Error, bool) {
	if cache == nil {
		return error_none(), true
	}

	err, ok := cache_clear(cache)
	delete(cache.entries)
	cache.db = nil
	return err, ok
}

cache_destroy_cleanup :: proc(cache: ^Stmt_Cache) {
	err, _ := cache_destroy(cache)
	error_destroy(&err)
}

cache_has :: proc(cache: Stmt_Cache, sql: string, flags: int = PERSISTENT_PREPARE_FLAGS) -> bool {
	if len(cache.entries) == 0 || !cache_flags_valid(flags) {
		return false
	}

	_, ok := cache.entries[cache_key(sql, u32(flags))]
	return ok
}

cache_count :: proc(cache: Stmt_Cache) -> int {
	return len(cache.entries)
}

cache_get :: proc(cache: ^Stmt_Cache, sql: string, flags: int = PERSISTENT_PREPARE_FLAGS) -> (^Stmt, bool) {
	if cache == nil || len(cache.entries) == 0 || !cache_flags_valid(flags) {
		return nil, false
	}

	entry_ptr, ok := cache.entries[cache_key(sql, u32(flags))]
	if !ok || entry_ptr == nil || entry_ptr.stmt == nil {
		return nil, false
	}
	if !stmt_is_valid(entry_ptr.stmt^) {
		return nil, false
	}

	entry_ptr.used = true
	return entry_ptr.stmt, true
}

// cache_put consumes the caller's `stmt`: ownership of its handle and bound
// storage transfers to the cache. After this call the caller's Stmt value is
// invalid and must not be used. The cache holds an owned clone of `stmt.sql`
// as the map key and the stored Stmt's `sql`.
cache_put :: proc(cache: ^Stmt_Cache, stmt: ^Stmt) -> (Error, bool) {
	if cache == nil {
		return error_make(int(raw.MISUSE), "sqlite: statement cache pointer must not be nil"), false
	}
	if stmt == nil || !stmt_is_valid(stmt^) {
		return error_make(int(raw.MISUSE), "sqlite: cache_put requires a prepared statement"), false
	}
	if stmt.sql == "" {
		return error_make(int(raw.MISUSE), "sqlite: cache_put requires a non-empty SQL string"), false
	}
	if cache.db != nil && cache.db != stmt.db {
		return error_make(int(raw.MISUSE), "sqlite: one statement cache cannot contain statements from multiple database handles"), false
	}

	key := cache_key(stmt.sql, stmt.prepare_flags)

	if old_ptr, exists := cache.entries[key]; exists && old_ptr != nil {
		finalize_err, finalize_ok := cache_destroy_entry(cache, key, old_ptr)
		if !finalize_ok {
			return finalize_err, false
		}
	}

	if !stmt.owned_sql {
		stmt.sql = strings.clone(stmt.sql)
		stmt.owned_sql = true
	}

	stored_stmt := new(Stmt)
	stored_stmt^ = stmt^

	// Consume caller's stmt so they cannot double-finalize the same handle or
	// alias the bound-storage dynamic arrays.
	stmt^ = Stmt{}

	entry_ptr := new(Cache_Entry)
	entry_ptr^ = Cache_Entry{
		stmt = stored_stmt,
		used = true,
	}

	cache.db = stored_stmt.db
	cache.entries[cache_key(stored_stmt.sql, stored_stmt.prepare_flags)] = entry_ptr
	return error_none(), true
}

cache_clear :: proc(cache: ^Stmt_Cache) -> (Error, bool) {
	if cache == nil {
		return error_none(), true
	}

	keys: [dynamic]Stmt_Cache_Key
	defer delete(keys)
	for key in cache.entries {
		append(&keys, key)
	}

	first_err := error_none()
	all_ok := true
	for key in keys {
		entry_ptr, ok := cache.entries[key]
		if !ok {
			continue
		}

		err, destroy_ok := cache_destroy_entry(cache, key, entry_ptr)
		if !destroy_ok {
			if all_ok {
				first_err = err
				all_ok = false
			} else {
				error_destroy(&err)
			}
		}
	}

	cache.db = nil
	return first_err, all_ok
}

cache_reset_usage :: proc(cache: ^Stmt_Cache) {
	if cache == nil {
		return
	}

	for key in cache.entries {
		entry_ptr, ok := cache.entries[key]
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

	keys_to_remove: [dynamic]Stmt_Cache_Key
	defer delete(keys_to_remove)
	for key, entry_ptr in cache.entries {
		if entry_ptr == nil || !entry_ptr.used {
			append(&keys_to_remove, key)
		}
	}

	removed := 0
	first_err := error_none()
	all_ok := true
	for key in keys_to_remove {
		entry_ptr, ok := cache.entries[key]
		if !ok {
			continue
		}

		err, destroy_ok := cache_destroy_entry(cache, key, entry_ptr)
		if !destroy_ok {
			if all_ok {
				first_err = err
				all_ok = false
			} else {
				error_destroy(&err)
			}
		}

		removed += 1
	}

	return removed, first_err, all_ok
}

// db_prepare_cached returns a pointer to a cached prepared statement, preparing
// and storing one on the first request and reusing it on subsequent requests.
// The returned ^Stmt is owned by the cache: do NOT call stmt_finalize on it
// directly; cache_destroy / cache_clear / cache_prune_unused are responsible
// for finalization. A nil cache is rejected with MISUSE — callers without a
// cache should use stmt_prepare directly and manage the lifetime themselves.
db_prepare_cached :: proc(
	db: DB,
	cache: ^Stmt_Cache,
	sql: string,
	flags: int = PERSISTENT_PREPARE_FLAGS,
) -> (^Stmt, Error, bool) {
	if cache == nil {
		return nil, error_make(int(raw.MISUSE), "sqlite: db_prepare_cached requires a non-nil cache; use stmt_prepare for one-off statements"), false
	}
	if db.handle == nil {
		return nil, error_from_db(db, int(raw.MISUSE), sql), false
	}
	if !cache_flags_valid(flags) {
		err := error_from_db(db, int(raw.RANGE), sql)
		error_with_op(&err, "db_prepare_cached")
		error_with_context(&err, "prepare flags exceed SQLite's u32 range")
		return nil, err, false
	}
	if cache.db != nil && cache.db != db.handle {
		return nil, error_make(int(raw.MISUSE), "sqlite: statement cache is currently bound to another database handle; clear it before reuse"), false
	}

	if stmt_ptr, ok := cache_get(cache, sql, flags); ok {
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

	put_err, put_ok := cache_put(cache, &stmt)
	if !put_ok {
		stmt_finalize_cleanup(&stmt)
		return nil, put_err, false
	}

	stmt_ptr, found := cache_get(cache, sql, flags)
	if !found || stmt_ptr == nil {
		return nil, error_make(int(raw.INTERNAL), "sqlite: cache_put did not retain the prepared statement"), false
	}

	return stmt_ptr, error_none(), true
}
