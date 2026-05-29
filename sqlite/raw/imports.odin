package raw

// Bindgen reads this file as the foreign-import template and embeds its body
// into sqlite/raw/generated/sqlite3.odin during `make generate`. Edit here, not
// in the generated file — regeneration will overwrite the generated copy.
//
// This file itself is NOT compiled into the wrapper. The wrapper imports
// `raw "raw/generated"` which already contains the embedded foreign-import
// block. Keeping the template here keeps regeneration reproducible.

// These defaults assume SQLite is already installed on the target system
// and should be loaded from the system library path.
@(private)
USE_DYNAMIC_LIB :: #config(SQLITE_DYNAMIC_LIB, true)
@(private)
USE_SYSTEM_LIB :: #config(SQLITE_SYSTEM_LIB, true)

when ODIN_OS == .Windows {
	when USE_SYSTEM_LIB {
		when USE_DYNAMIC_LIB {
			foreign import sqlite "system:sqlite3.dll"
		} else {
			foreign import sqlite "system:sqlite3.lib"
		}
	} else {
		when USE_DYNAMIC_LIB {
			foreign import sqlite "sqlite3.dll"
		} else {
			foreign import sqlite "sqlite3.lib"
		}
	}
} else when ODIN_OS == .Darwin {
	when USE_SYSTEM_LIB {
		when USE_DYNAMIC_LIB {
			foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"
		} else {
			foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.a"
		}
	} else {
		when USE_DYNAMIC_LIB {
			foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"
		} else {
			foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.a"
		}
	}
} else when ODIN_OS == .Linux {
	when USE_SYSTEM_LIB {
		when USE_DYNAMIC_LIB {
			foreign import sqlite "system:libsqlite3.so"
		} else {
			foreign import sqlite "system:/opt/homebrew/opt/sqlite/lib/libsqlite3.a"
		}
	} else {
		when USE_DYNAMIC_LIB {
			foreign import sqlite "libsqlite3.so"
		} else {
			foreign import sqlite "libsqlite3.a"
		}
	}
}
