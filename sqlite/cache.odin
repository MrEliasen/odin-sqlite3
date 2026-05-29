package sqlite

import "core:strings"
import raw "raw/generated"

cache_init :: proc() -> Stmt_Cache {
	return Stmt_Cache{
		entries = make(map[string]^Cache_Entry),
	}
}

// cache_destroy_entry removes the entry from the cache and releases its heap
// allocations regardless of stmt_finalize's result. If finalize returns an
// Error, that Error is propagated to the caller — the entry/stmt have still
// been freed by the time the proc returns.
cache_destroy_entry :: proc(cache: ^Stmt_Cache, sql: string, entry_ptr: ^Cache_Entry) -> (Error, bool) {
	if cache == nil {
		return error_none(), true
	}

	lookup_sql := sql
	if entry_ptr != nil && entry_ptr.stmt != nil && entry_ptr.stmt.owned_sql {
		lookup_sql = entry_ptr.stmt.sql
	}

	delete_key(&cache.entries, lookup_sql)

	if entry_ptr == nil {
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

	return finalize_err, finalize_ok
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

	owned_sql := strings.clone(stmt.sql)

	if old_ptr, exists := cache.entries[stmt.sql]; exists && old_ptr != nil {
		finalize_err, finalize_ok := cache_destroy_entry(cache, stmt.sql, old_ptr)
		if !finalize_ok {
			delete(owned_sql)
			return finalize_err, false
		}
	}

	stored_stmt := new(Stmt)
	stored_stmt^ = stmt^
	stored_stmt.sql = owned_sql
	stored_stmt.owned_sql = true

	// Consume caller's stmt so they cannot double-finalize the same handle or
	// alias the bound-storage dynamic arrays.
	stmt^ = Stmt{}

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

	put_err, put_ok := cache_put(cache, &stmt)
	if !put_ok {
		_, _ = stmt_finalize(&stmt)
		return nil, put_err, false
	}

	stmt_ptr, found := cache_get(cache, sql)
	if !found || stmt_ptr == nil {
		return nil, error_make(int(raw.INTERNAL), "sqlite: cache_put did not retain the prepared statement"), false
	}

	return stmt_ptr, error_none(), true
}
