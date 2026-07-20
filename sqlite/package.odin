package sqlite

// Handwritten wrapper package.
//
// Generated raw bindings live under:
//   sqlite/raw/generated
//
// The default import setup assumes SQLite is installed on the target system
// and asks the platform linker for `sqlite3.lib` on Windows or `sqlite3`
// elsewhere. Override the complete foreign import value for vendored or static
// builds, for example:
//
//   odin build . -define:SQLITE_LIB=system:/absolute/path/to/libsqlite3.a
//
// Connections request SQLite's FULLMUTEX (serialized) mode by default. If an
// application explicitly opens with OPEN_NOMUTEX, it must externally serialize
// every use of that DB and all statements/blobs/backups derived from it. Wrapper
// trace configuration and statement caches are mutable and are not synchronized.
//
// A release package for consumer projects is produced with:
//   make package
// or:
//   make package-zip
