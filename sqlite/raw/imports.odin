package raw

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