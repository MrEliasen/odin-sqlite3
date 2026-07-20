package raw

// Bindgen reads this file as the foreign-import template and embeds its body
// into sqlite/raw/generated/sqlite3.odin during `make generate`. Edit here, not
// in the generated file — regeneration will overwrite the generated copy.
//
// This file itself is NOT compiled into the wrapper. The wrapper imports
// `raw "raw/generated"` which already contains the embedded foreign-import
// block. Keeping the template here keeps regeneration reproducible.

// By default, ask the platform linker for the installed SQLite library. This
// avoids embedding package-manager- or architecture-specific paths in the
// binding. Consumers that vendor SQLite or require a particular static/shared
// build can override the complete foreign-import value, for example:
//
//   odin build . -define:SQLITE_LIB=system:/absolute/path/to/libsqlite3.a
//
// The `system:` prefix also prevents Odin from resolving a path relative to
// this block's location in sqlite/raw/generated/sqlite3.odin. Use a non-system
// value only for a library intentionally stored relative to that file.
@(private)
DEFAULT_SQLITE_LIB :: (
	"system:sqlite3.lib" when ODIN_OS == .Windows else
	"system:sqlite3"
)
@(private)
SQLITE_LIB :: #config(SQLITE_LIB, DEFAULT_SQLITE_LIB)

// SQLite omits these declarations and symbols unless its library was built
// with the corresponding compile-time feature. Keep conservative defaults so
// selecting a different system library cannot create accidental unresolved
// links. Enable only the features exported by the chosen SQLITE_LIB, e.g.:
//
//   -define:SQLITE_HAS_PREUPDATE_API=true
//   -define:SQLITE_HAS_SESSION_API=true
//   -define:SQLITE_HAS_NORMALIZE_API=true
//   -define:SQLITE_HAS_COLUMN_METADATA_API=true
//   -define:SQLITE_HAS_UNLOCK_NOTIFY_API=true
//   -define:SQLITE_HAS_STMT_SCANSTATUS_API=true
//   -define:SQLITE_HAS_SNAPSHOT_API=true
//
// Homebrew SQLite 3.53.1 exports preupdate, session, column-metadata, and
// unlock-notify (72 symbols total), but not normalize, statement scan-status,
// or snapshot APIs.
HAS_NORMALIZE_API :: #config(SQLITE_HAS_NORMALIZE_API, false)
HAS_PREUPDATE_API :: #config(SQLITE_HAS_PREUPDATE_API, false)
HAS_SESSION_API :: #config(SQLITE_HAS_SESSION_API, false)
HAS_COLUMN_METADATA_API :: #config(SQLITE_HAS_COLUMN_METADATA_API, false)
HAS_UNLOCK_NOTIFY_API :: #config(SQLITE_HAS_UNLOCK_NOTIFY_API, false)
HAS_STMT_SCANSTATUS_API :: #config(SQLITE_HAS_STMT_SCANSTATUS_API, false)
HAS_SNAPSHOT_API :: #config(SQLITE_HAS_SNAPSHOT_API, false)

when SQLITE_LIB == "" {
	#panic("SQLITE_LIB must name a SQLite library")
}

foreign import sqlite { SQLITE_LIB }
