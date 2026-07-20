#!/usr/bin/env python3
"""
Apply deterministic post-generation patches to the generated SQLite raw binding.

This script exists because the current generated output from odin-c-bindgen
still requires a small number of narrowly-scoped corrections before the raw
bindings are acceptable for this project.

It is intentionally conservative:
- it patches only known-bad patterns
- it fails loudly if a required pattern is missing
- it avoids broad rewriting of generated output

Usage:
    python3 packaging/apply_postgen_patches.py

Run this from the project root.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_GENERATED = PROJECT_ROOT / "sqlite" / "raw" / "generated" / "sqlite3.odin"
RAW_IMPORTS = PROJECT_ROOT / "sqlite" / "raw" / "imports.odin"
PINNED_SQLITE_HEADER = PROJECT_ROOT / "input" / "sqlite3.h"


# odin-c-bindgen currently records the first (forward) declaration of these
# public SQLite records and then ignores the later definition.  Keep the
# canonical Odin spellings here so regeneration is deterministic.  Opaque
# handle types such as Sqlite3, Stmt, Value, and Session intentionally remain
# empty; only records whose fields are part of SQLite's public C ABI appear in
# this table.
CONCRETE_STRUCTS: dict[str, str] = {
    "File": """struct {
\tpMethods: ^Io_Methods,
}""",
    "Io_Methods": """struct {
\tiVersion:              i32,
\txClose:                proc "c" (^File) -> i32,
\txRead:                 proc "c" (^File, rawptr, i32, Int64) -> i32,
\txWrite:                proc "c" (^File, rawptr, i32, Int64) -> i32,
\txTruncate:             proc "c" (^File, Int64) -> i32,
\txSync:                 proc "c" (^File, i32) -> i32,
\txFileSize:             proc "c" (^File, ^Int64) -> i32,
\txLock:                 proc "c" (^File, i32) -> i32,
\txUnlock:               proc "c" (^File, i32) -> i32,
\txCheckReservedLock:    proc "c" (^File, ^i32) -> i32,
\txFileControl:          proc "c" (^File, i32, rawptr) -> i32,
\txSectorSize:           proc "c" (^File) -> i32,
\txDeviceCharacteristics: proc "c" (^File) -> i32,
\txShmMap:               proc "c" (^File, i32, i32, i32, ^rawptr) -> i32,
\txShmLock:              proc "c" (^File, i32, i32, i32) -> i32,
\txShmBarrier:           proc "c" (^File),
\txShmUnmap:             proc "c" (^File, i32) -> i32,
\txFetch:                proc "c" (^File, Int64, i32, ^rawptr) -> i32,
\txUnfetch:              proc "c" (^File, Int64, rawptr) -> i32,
}""",
    "Vfs": """struct {
\tiVersion:          i32,
\tszOsFile:          i32,
\tmxPathname:        i32,
\tpNext:             ^Vfs,
\tzName:             cstring,
\tpAppData:          rawptr,
\txOpen:             proc "c" (^Vfs, Filename, ^File, i32, ^i32) -> i32,
\txDelete:           proc "c" (^Vfs, cstring, i32) -> i32,
\txAccess:           proc "c" (^Vfs, cstring, i32, ^i32) -> i32,
\txFullPathname:     proc "c" (^Vfs, cstring, i32, cstring) -> i32,
\txDlOpen:           proc "c" (^Vfs, cstring) -> rawptr,
\txDlError:          proc "c" (^Vfs, i32, cstring),
\txDlSym:            proc "c" (^Vfs, rawptr, cstring) -> proc "c" (),
\txDlClose:          proc "c" (^Vfs, rawptr),
\txRandomness:       proc "c" (^Vfs, i32, cstring) -> i32,
\txSleep:            proc "c" (^Vfs, i32) -> i32,
\txCurrentTime:      proc "c" (^Vfs, ^f64) -> i32,
\txGetLastError:     proc "c" (^Vfs, i32, cstring) -> i32,
\txCurrentTimeInt64: proc "c" (^Vfs, ^Int64) -> i32,
\txSetSystemCall:    proc "c" (^Vfs, cstring, Syscall_Ptr) -> i32,
\txGetSystemCall:    proc "c" (^Vfs, cstring) -> Syscall_Ptr,
\txNextSystemCall:   proc "c" (^Vfs, cstring) -> cstring,
}""",
    "Mem_Methods": """struct {
\txMalloc:   proc "c" (i32) -> rawptr,
\txFree:     proc "c" (rawptr),
\txRealloc:  proc "c" (rawptr, i32) -> rawptr,
\txSize:     proc "c" (rawptr) -> i32,
\txRoundup:  proc "c" (i32) -> i32,
\txInit:     proc "c" (rawptr) -> i32,
\txShutdown: proc "c" (rawptr),
\tpAppData:  rawptr,
}""",
    "Module": """struct {
\tiVersion:      i32,
\txCreate:       proc "c" (^Sqlite3, rawptr, i32, ^cstring, ^^Vtab, ^cstring) -> i32,
\txConnect:      proc "c" (^Sqlite3, rawptr, i32, ^cstring, ^^Vtab, ^cstring) -> i32,
\txBestIndex:    proc "c" (^Vtab, ^Index_Info) -> i32,
\txDisconnect:   proc "c" (^Vtab) -> i32,
\txDestroy:      proc "c" (^Vtab) -> i32,
\txOpen:         proc "c" (^Vtab, ^^Vtab_Cursor) -> i32,
\txClose:        proc "c" (^Vtab_Cursor) -> i32,
\txFilter:       proc "c" (^Vtab_Cursor, i32, cstring, i32, ^^Value) -> i32,
\txNext:         proc "c" (^Vtab_Cursor) -> i32,
\txEof:          proc "c" (^Vtab_Cursor) -> i32,
\txColumn:       proc "c" (^Vtab_Cursor, ^Context, i32) -> i32,
\txRowid:        proc "c" (^Vtab_Cursor, ^Int64) -> i32,
\txUpdate:       proc "c" (^Vtab, i32, ^^Value, ^Int64) -> i32,
\txBegin:        proc "c" (^Vtab) -> i32,
\txSync:         proc "c" (^Vtab) -> i32,
\txCommit:       proc "c" (^Vtab) -> i32,
\txRollback:     proc "c" (^Vtab) -> i32,
\txFindFunction: proc "c" (^Vtab, i32, cstring, ^Module_Function, ^rawptr) -> i32,
\txRename:       proc "c" (^Vtab, cstring) -> i32,
\txSavepoint:    proc "c" (^Vtab, i32) -> i32,
\txRelease:      proc "c" (^Vtab, i32) -> i32,
\txRollbackTo:   proc "c" (^Vtab, i32) -> i32,
\txShadowName:   proc "c" (cstring) -> i32,
\txIntegrity:    proc "c" (^Vtab, cstring, cstring, i32, ^cstring) -> i32,
}""",
    "Index_Info": """struct {
\tnConstraint:      i32,
\taConstraint:      ^Index_Constraint,
\tnOrderBy:         i32,
\taOrderBy:         ^Index_Orderby,
\taConstraintUsage: ^Index_Constraint_Usage,
\tidxNum:           i32,
\tidxStr:           cstring,
\tneedToFreeIdxStr: i32,
\torderByConsumed:  i32,
\testimatedCost:    f64,
\testimatedRows:    Int64,
\tidxFlags:         i32,
\tcolUsed:          Uint64,
}""",
    "Vtab": """struct {
\tpModule: ^Module,
\tnRef:    i32,
\tzErrMsg: cstring,
}""",
    "Vtab_Cursor": """struct {
\tpVtab: ^Vtab,
}""",
    "Mutex_Methods": """struct {
\txMutexInit:    proc "c" () -> i32,
\txMutexEnd:     proc "c" () -> i32,
\txMutexAlloc:   proc "c" (i32) -> ^Mutex,
\txMutexFree:    proc "c" (^Mutex),
\txMutexEnter:   proc "c" (^Mutex),
\txMutexTry:     proc "c" (^Mutex) -> i32,
\txMutexLeave:   proc "c" (^Mutex),
\txMutexHeld:    proc "c" (^Mutex) -> i32,
\txMutexNotheld: proc "c" (^Mutex) -> i32,
}""",
    "Pcache_Page": """struct {
\tpBuf:   rawptr,
\tpExtra: rawptr,
}""",
    "Pcache_Methods2": """struct {
\tiVersion:  i32,
\tpArg:      rawptr,
\txInit:     proc "c" (rawptr) -> i32,
\txShutdown: proc "c" (rawptr),
\txCreate:   proc "c" (i32, i32, i32) -> ^Pcache,
\txCachesize: proc "c" (^Pcache, i32),
\txPagecount: proc "c" (^Pcache) -> i32,
\txFetch:    proc "c" (^Pcache, u32, i32) -> ^Pcache_Page,
\txUnpin:    proc "c" (^Pcache, ^Pcache_Page, i32),
\txRekey:    proc "c" (^Pcache, ^Pcache_Page, u32, u32),
\txTruncate: proc "c" (^Pcache, u32),
\txDestroy:  proc "c" (^Pcache),
\txShrink:   proc "c" (^Pcache),
}""",
    "Pcache_Methods": """struct {
\tpArg:       rawptr,
\txInit:      proc "c" (rawptr) -> i32,
\txShutdown:  proc "c" (rawptr),
\txCreate:    proc "c" (i32, i32) -> ^Pcache,
\txCachesize: proc "c" (^Pcache, i32),
\txPagecount: proc "c" (^Pcache) -> i32,
\txFetch:     proc "c" (^Pcache, u32, i32) -> rawptr,
\txUnpin:     proc "c" (^Pcache, rawptr, i32),
\txRekey:     proc "c" (^Pcache, rawptr, u32, u32),
\txTruncate:  proc "c" (^Pcache, u32),
\txDestroy:   proc "c" (^Pcache),
}""",
    "Rtree_Geometry": """struct {
\tpContext: rawptr,
\tnParam:   i32,
\taParam:   ^Rtree_Dbl,
\tpUser:    rawptr,
\txDelUser: proc "c" (rawptr),
}""",
    "Rtree_Query_Info": """struct {
\tpContext:      rawptr,
\tnParam:        i32,
\taParam:        ^Rtree_Dbl,
\tpUser:         rawptr,
\txDelUser:      proc "c" (rawptr),
\taCoord:        ^Rtree_Dbl,
\tanQueue:       ^u32,
\tnCoord:        i32,
\tiLevel:        i32,
\tmxLevel:       i32,
\tiRowid:        Int64,
\trParentScore:  Rtree_Dbl,
\teParentWithin: i32,
\teWithin:       i32,
\trScore:        Rtree_Dbl,
\tapSqlParam:    ^^Value,
}""",
    "Fts5phrase_Iter": """struct {
\ta: ^u8,
\tb: ^u8,
}""",
    "Fts5extension_Api": """struct {
\tiVersion:           i32,
\txUserData:          proc "c" (^Fts5context) -> rawptr,
\txColumnCount:       proc "c" (^Fts5context) -> i32,
\txRowCount:          proc "c" (^Fts5context, ^Int64) -> i32,
\txColumnTotalSize:   proc "c" (^Fts5context, i32, ^Int64) -> i32,
\txTokenize:          proc "c" (^Fts5context, cstring, i32, rawptr, Fts5_Token_Callback) -> i32,
\txPhraseCount:       proc "c" (^Fts5context) -> i32,
\txPhraseSize:        proc "c" (^Fts5context, i32) -> i32,
\txInstCount:         proc "c" (^Fts5context, ^i32) -> i32,
\txInst:              proc "c" (^Fts5context, i32, ^i32, ^i32, ^i32) -> i32,
\txRowid:             proc "c" (^Fts5context) -> Int64,
\txColumnText:        proc "c" (^Fts5context, i32, ^cstring, ^i32) -> i32,
\txColumnSize:        proc "c" (^Fts5context, i32, ^i32) -> i32,
\txQueryPhrase:       proc "c" (^Fts5context, i32, rawptr, Fts5_Query_Callback) -> i32,
\txSetAuxdata:        proc "c" (^Fts5context, rawptr, proc "c" (rawptr)) -> i32,
\txGetAuxdata:        proc "c" (^Fts5context, i32) -> rawptr,
\txPhraseFirst:       proc "c" (^Fts5context, i32, ^Fts5phrase_Iter, ^i32, ^i32) -> i32,
\txPhraseNext:        proc "c" (^Fts5context, ^Fts5phrase_Iter, ^i32, ^i32),
\txPhraseFirstColumn: proc "c" (^Fts5context, i32, ^Fts5phrase_Iter, ^i32) -> i32,
\txPhraseNextColumn:  proc "c" (^Fts5context, ^Fts5phrase_Iter, ^i32),
\txQueryToken:        proc "c" (^Fts5context, i32, i32, ^cstring, ^i32) -> i32,
\txInstToken:         proc "c" (^Fts5context, i32, i32, ^cstring, ^i32) -> i32,
\txColumnLocale:      proc "c" (^Fts5context, i32, ^cstring, ^i32) -> i32,
\txTokenize_v2:       proc "c" (^Fts5context, cstring, i32, cstring, i32, rawptr, Fts5_Token_Callback) -> i32,
}""",
    "Fts5_Tokenizer_V2": """struct {
\tiVersion:  i32,
\txCreate:   proc "c" (rawptr, ^cstring, i32, ^^Fts5tokenizer) -> i32,
\txDelete:   proc "c" (^Fts5tokenizer),
\txTokenize: proc "c" (^Fts5tokenizer, rawptr, i32, cstring, i32, cstring, i32, Fts5_Token_Callback) -> i32,
}""",
    "Fts5_Tokenizer": """struct {
\txCreate:   proc "c" (rawptr, ^cstring, i32, ^^Fts5tokenizer) -> i32,
\txDelete:   proc "c" (^Fts5tokenizer),
\txTokenize: proc "c" (^Fts5tokenizer, rawptr, i32, cstring, i32, Fts5_Token_Callback) -> i32,
}""",
    "Fts5_Api": """struct {
\tiVersion:           i32,
\txCreateTokenizer:   proc "c" (^Fts5_Api, cstring, rawptr, ^Fts5_Tokenizer, proc "c" (rawptr)) -> i32,
\txFindTokenizer:     proc "c" (^Fts5_Api, cstring, ^rawptr, ^Fts5_Tokenizer) -> i32,
\txCreateFunction:    proc "c" (^Fts5_Api, cstring, rawptr, Fts5_Extension_Function, proc "c" (rawptr)) -> i32,
\txCreateTokenizer_v2: proc "c" (^Fts5_Api, cstring, rawptr, ^Fts5_Tokenizer_V2, proc "c" (rawptr)) -> i32,
\txFindTokenizer_v2:  proc "c" (^Fts5_Api, cstring, ^rawptr, ^^Fts5_Tokenizer_V2) -> i32,
}""",
}


# These helper callback aliases are needed to express pointer-to-callback
# and nested callback fields without weakening the generated types to rawptr.
STRUCT_HELPER_TYPES = """Module_Function :: proc "c" (^Context, i32, ^^Value)
Fts5_Token_Callback :: proc "c" (rawptr, i32, cstring, i32, i32, i32) -> i32
Fts5_Query_Callback :: proc "c" (^Fts5extension_Api, ^Fts5context, rawptr) -> i32
"""


# C spelling, Odin spelling, and every public field in declaration order.
# The nested sqlite3_index_* records do not have typedef names in C.
ABI_STRUCTS: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    ("sqlite3_file", "File", ("pMethods",)),
    (
        "sqlite3_io_methods",
        "Io_Methods",
        (
            "iVersion", "xClose", "xRead", "xWrite", "xTruncate", "xSync",
            "xFileSize", "xLock", "xUnlock", "xCheckReservedLock",
            "xFileControl", "xSectorSize", "xDeviceCharacteristics", "xShmMap",
            "xShmLock", "xShmBarrier", "xShmUnmap", "xFetch", "xUnfetch",
        ),
    ),
    (
        "sqlite3_vfs",
        "Vfs",
        (
            "iVersion", "szOsFile", "mxPathname", "pNext", "zName", "pAppData",
            "xOpen", "xDelete", "xAccess", "xFullPathname", "xDlOpen", "xDlError",
            "xDlSym", "xDlClose", "xRandomness", "xSleep", "xCurrentTime",
            "xGetLastError", "xCurrentTimeInt64", "xSetSystemCall", "xGetSystemCall",
            "xNextSystemCall",
        ),
    ),
    (
        "sqlite3_mem_methods",
        "Mem_Methods",
        ("xMalloc", "xFree", "xRealloc", "xSize", "xRoundup", "xInit", "xShutdown", "pAppData"),
    ),
    (
        "sqlite3_module",
        "Module",
        (
            "iVersion", "xCreate", "xConnect", "xBestIndex", "xDisconnect", "xDestroy",
            "xOpen", "xClose", "xFilter", "xNext", "xEof", "xColumn", "xRowid",
            "xUpdate", "xBegin", "xSync", "xCommit", "xRollback", "xFindFunction",
            "xRename", "xSavepoint", "xRelease", "xRollbackTo", "xShadowName", "xIntegrity",
        ),
    ),
    (
        "sqlite3_index_info",
        "Index_Info",
        (
            "nConstraint", "aConstraint", "nOrderBy", "aOrderBy", "aConstraintUsage",
            "idxNum", "idxStr", "needToFreeIdxStr", "orderByConsumed", "estimatedCost",
            "estimatedRows", "idxFlags", "colUsed",
        ),
    ),
    (
        "struct sqlite3_index_constraint",
        "Index_Constraint",
        ("iColumn", "op", "usable", "iTermOffset"),
    ),
    (
        "struct sqlite3_index_orderby",
        "Index_Orderby",
        ("iColumn", "desc"),
    ),
    (
        "struct sqlite3_index_constraint_usage",
        "Index_Constraint_Usage",
        ("argvIndex", "omit"),
    ),
    ("sqlite3_vtab", "Vtab", ("pModule", "nRef", "zErrMsg")),
    ("sqlite3_vtab_cursor", "Vtab_Cursor", ("pVtab",)),
    (
        "sqlite3_mutex_methods",
        "Mutex_Methods",
        (
            "xMutexInit", "xMutexEnd", "xMutexAlloc", "xMutexFree", "xMutexEnter",
            "xMutexTry", "xMutexLeave", "xMutexHeld", "xMutexNotheld",
        ),
    ),
    ("sqlite3_pcache_page", "Pcache_Page", ("pBuf", "pExtra")),
    (
        "sqlite3_pcache_methods2",
        "Pcache_Methods2",
        (
            "iVersion", "pArg", "xInit", "xShutdown", "xCreate", "xCachesize",
            "xPagecount", "xFetch", "xUnpin", "xRekey", "xTruncate", "xDestroy", "xShrink",
        ),
    ),
    (
        "sqlite3_pcache_methods",
        "Pcache_Methods",
        (
            "pArg", "xInit", "xShutdown", "xCreate", "xCachesize", "xPagecount",
            "xFetch", "xUnpin", "xRekey", "xTruncate", "xDestroy",
        ),
    ),
    ("sqlite3_snapshot", "Snapshot", ("hidden",)),
    (
        "sqlite3_rtree_geometry",
        "Rtree_Geometry",
        ("pContext", "nParam", "aParam", "pUser", "xDelUser"),
    ),
    (
        "sqlite3_rtree_query_info",
        "Rtree_Query_Info",
        (
            "pContext", "nParam", "aParam", "pUser", "xDelUser", "aCoord", "anQueue",
            "nCoord", "iLevel", "mxLevel", "iRowid", "rParentScore", "eParentWithin",
            "eWithin", "rScore", "apSqlParam",
        ),
    ),
    ("Fts5PhraseIter", "Fts5phrase_Iter", ("a", "b")),
    (
        "Fts5ExtensionApi",
        "Fts5extension_Api",
        (
            "iVersion", "xUserData", "xColumnCount", "xRowCount", "xColumnTotalSize",
            "xTokenize", "xPhraseCount", "xPhraseSize", "xInstCount", "xInst", "xRowid",
            "xColumnText", "xColumnSize", "xQueryPhrase", "xSetAuxdata", "xGetAuxdata",
            "xPhraseFirst", "xPhraseNext", "xPhraseFirstColumn", "xPhraseNextColumn",
            "xQueryToken", "xInstToken", "xColumnLocale", "xTokenize_v2",
        ),
    ),
    ("fts5_tokenizer_v2", "Fts5_Tokenizer_V2", ("iVersion", "xCreate", "xDelete", "xTokenize")),
    ("fts5_tokenizer", "Fts5_Tokenizer", ("xCreate", "xDelete", "xTokenize")),
    (
        "fts5_api",
        "Fts5_Api",
        (
            "iVersion", "xCreateTokenizer", "xFindTokenizer", "xCreateFunction",
            "xCreateTokenizer_v2", "xFindTokenizer_v2",
        ),
    ),
)


NORMALIZE_PREUPDATE_SESSION_API_SYMBOLS: tuple[str, ...] = (
    "sqlite3_normalized_sql",
    "sqlite3_preupdate_hook",
    "sqlite3_preupdate_old",
    "sqlite3_preupdate_count",
    "sqlite3_preupdate_depth",
    "sqlite3_preupdate_new",
    "sqlite3_preupdate_blobwrite",
    "sqlite3session_create",
    "sqlite3session_delete",
    "sqlite3session_object_config",
    "sqlite3session_enable",
    "sqlite3session_indirect",
    "sqlite3session_attach",
    "sqlite3session_table_filter",
    "sqlite3session_changeset",
    "sqlite3session_changeset_size",
    "sqlite3session_diff",
    "sqlite3session_patchset",
    "sqlite3session_isempty",
    "sqlite3session_memory_used",
    "sqlite3changeset_start",
    "sqlite3changeset_start_v2",
    "sqlite3changeset_next",
    "sqlite3changeset_op",
    "sqlite3changeset_pk",
    "sqlite3changeset_old",
    "sqlite3changeset_new",
    "sqlite3changeset_conflict",
    "sqlite3changeset_fk_conflicts",
    "sqlite3changeset_finalize",
    "sqlite3changeset_invert",
    "sqlite3changeset_concat",
    "sqlite3changegroup_new",
    "sqlite3changegroup_schema",
    "sqlite3changegroup_add",
    "sqlite3changegroup_add_change",
    "sqlite3changegroup_output",
    "sqlite3changegroup_delete",
    "sqlite3changeset_apply",
    "sqlite3changeset_apply_v2",
    "sqlite3changeset_apply_v3",
    "sqlite3rebaser_create",
    "sqlite3rebaser_configure",
    "sqlite3rebaser_rebase",
    "sqlite3rebaser_delete",
    "sqlite3changeset_apply_strm",
    "sqlite3changeset_apply_v2_strm",
    "sqlite3changeset_apply_v3_strm",
    "sqlite3changeset_concat_strm",
    "sqlite3changeset_invert_strm",
    "sqlite3changeset_start_strm",
    "sqlite3changeset_start_v2_strm",
    "sqlite3session_changeset_strm",
    "sqlite3session_patchset_strm",
    "sqlite3changegroup_add_strm",
    "sqlite3changegroup_output_strm",
    "sqlite3rebaser_rebase_strm",
    "sqlite3session_config",
    "sqlite3changegroup_config",
    "sqlite3changegroup_change_begin",
    "sqlite3changegroup_change_int64",
    "sqlite3changegroup_change_null",
    "sqlite3changegroup_change_double",
    "sqlite3changegroup_change_text",
    "sqlite3changegroup_change_blob",
    "sqlite3changegroup_change_finish",
)

COLUMN_METADATA_API_SYMBOLS: tuple[str, ...] = (
    "sqlite3_column_database_name",
    "sqlite3_column_database_name16",
    "sqlite3_column_table_name",
    "sqlite3_column_table_name16",
    "sqlite3_column_origin_name",
    "sqlite3_column_origin_name16",
)

UNLOCK_NOTIFY_API_SYMBOLS: tuple[str, ...] = (
    "sqlite3_unlock_notify",
)

STMT_SCANSTATUS_API_SYMBOLS: tuple[str, ...] = (
    "sqlite3_stmt_scanstatus",
    "sqlite3_stmt_scanstatus_v2",
    "sqlite3_stmt_scanstatus_reset",
)

SNAPSHOT_API_SYMBOLS: tuple[str, ...] = (
    "sqlite3_snapshot_get",
    "sqlite3_snapshot_open",
    "sqlite3_snapshot_free",
    "sqlite3_snapshot_cmp",
    "sqlite3_snapshot_recover",
)

OPTIONAL_API_SYMBOLS: tuple[str, ...] = (
    NORMALIZE_PREUPDATE_SESSION_API_SYMBOLS
    + COLUMN_METADATA_API_SYMBOLS
    + UNLOCK_NOTIFY_API_SYMBOLS
    + STMT_SCANSTATUS_API_SYMBOLS
    + SNAPSHOT_API_SYMBOLS
)

FEATURE_GATED_API_SYMBOLS: dict[str, tuple[str, ...]] = {
    "HAS_NORMALIZE_API": NORMALIZE_PREUPDATE_SESSION_API_SYMBOLS[:1],
    "HAS_PREUPDATE_API": NORMALIZE_PREUPDATE_SESSION_API_SYMBOLS[1:7],
    "HAS_SESSION_API": NORMALIZE_PREUPDATE_SESSION_API_SYMBOLS[7:],
    "HAS_COLUMN_METADATA_API": COLUMN_METADATA_API_SYMBOLS,
    "HAS_UNLOCK_NOTIFY_API": UNLOCK_NOTIFY_API_SYMBOLS,
    "HAS_STMT_SCANSTATUS_API": STMT_SCANSTATUS_API_SYMBOLS,
    "HAS_SNAPSHOT_API": SNAPSHOT_API_SYMBOLS,
}

HOST_MISSING_OPTIONAL_SYMBOLS: set[str] = {
    "sqlite3_normalized_sql",
    *STMT_SCANSTATUS_API_SYMBOLS,
    *SNAPSHOT_API_SYMBOLS,
}

HOST_ENABLED_FEATURE_GATES: tuple[str, ...] = (
    "HAS_PREUPDATE_API",
    "HAS_SESSION_API",
    "HAS_COLUMN_METADATA_API",
    "HAS_UNLOCK_NOTIFY_API",
)

UNSUPPORTED_CEROD_SYMBOL = "sqlite3_activate_cerod"
EXPECTED_BASELINE_API_COUNT = 283
EXPECTED_OPTIONAL_API_COUNT = 81
EXPECTED_HOST_OPTIONAL_API_COUNT = 72

OPTIONAL_API_TYPES: tuple[str, ...] = (
    "Session",
    "Changeset_Iter",
    "Changegroup",
    "Rebaser",
)

OPTIONAL_API_CONSTANTS: tuple[str, ...] = (
    "SESSION_OBJCONFIG_SIZE",
    "SESSION_OBJCONFIG_ROWID",
    "CHANGESETSTART_INVERT",
    "CHANGESETAPPLY_NOSAVEPOINT",
    "CHANGESETAPPLY_INVERT",
    "CHANGESETAPPLY_IGNORENOOP",
    "CHANGESETAPPLY_FKNOACTION",
    "CHANGESET_DATA",
    "CHANGESET_NOTFOUND",
    "CHANGESET_CONFLICT",
    "CHANGESET_CONSTRAINT",
    "CHANGESET_FOREIGN_KEY",
    "CHANGESET_OMIT",
    "CHANGESET_REPLACE",
    "CHANGESET_ABORT",
    "SESSION_CONFIG_STRMSIZE",
    "CHANGEGROUP_CONFIG_PATCHSET",
)


@dataclass
class PatchResult:
    changed: bool
    applied_count: int


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def published_header_api_symbols(header_text: str) -> set[str]:
    """Extract the public sqlite3* function names from the pinned header.

    The pinned 3.53.1 header contains exactly 283 baseline APIs, 81 APIs in
    the optional feature families inventoried above, and the unsupported
    proprietary CEROD declaration. Keeping the expected totals explicit makes
    an upstream header change fail closed until the binding contract is
    reviewed.
    """
    return set(
        re.findall(
            r"SQLITE_API[\s\S]{0,300}?\b(sqlite3[A-Za-z0-9_]+)\s*\(",
            header_text,
        )
    )


def ensure_file(path: Path) -> None:
    if not path.exists():
        fail(f"required file not found: {path}")


def replace_all_required(text: str, old: str, new: str, description: str) -> tuple[str, int]:
    count = text.count(old)
    if count == 0:
        fail(f"required pattern not found for patch: {description}")
    return text.replace(old, new), count


def replace_one_required(text: str, old: str, new: str, description: str) -> tuple[str, int]:
    count = text.count(old)
    if count == 0:
        fail(f"required pattern not found for patch: {description}")
    if count > 1:
        fail(f"expected exactly one match for patch '{description}', found {count}")
    return text.replace(old, new, 1), 1


def ensure_once(text: str, needle: str, description: str) -> None:
    count = text.count(needle)
    if count != 1:
        fail(f"expected exactly one occurrence of {description}, found {count}")


def patch_imports_file() -> PatchResult:
    ensure_file(RAW_IMPORTS)
    text = RAW_IMPORTS.read_text(encoding="utf-8")
    original = text
    applied = 0

    if not text.startswith("package raw\n"):
        if text.startswith("\n"):
            text = "package raw\n" + text
        elif text.lstrip().startswith("package raw"):
            fail("imports file contains misplaced package declaration")
        else:
            text = "package raw\n\n" + text
        applied += 1

    if text != original:
        RAW_IMPORTS.write_text(text, encoding="utf-8")

    ensure_once(text, "package raw\n", "package raw declaration in imports file")
    ensure_once(
        text,
        'SQLITE_LIB :: #config(SQLITE_LIB, DEFAULT_SQLITE_LIB)',
        "configurable SQLite library declaration in imports file",
    )
    ensure_once(
        text,
        '"system:sqlite3.lib" when ODIN_OS == .Windows else\n\t"system:sqlite3"',
        "platform-default SQLite library selection in imports file",
    )
    ensure_once(
        text,
        "foreign import sqlite { SQLITE_LIB }",
        "configurable SQLite foreign import in imports file",
    )
    for gate in FEATURE_GATED_API_SYMBOLS:
        ensure_once(
            text,
            f"{gate} :: #config(SQLITE_{gate}, false)",
            f"SQLite {gate.lower()} availability config in imports file",
        )
    return PatchResult(changed=text != original, applied_count=applied)


def patch_generated_file() -> PatchResult:
    ensure_file(RAW_GENERATED)
    text = RAW_GENERATED.read_text(encoding="utf-8")
    original = text
    applied = 0

    # Keep an already-generated file compatible when the imports template gains
    # a new availability gate. A fresh bindgen run embeds these declarations
    # directly, so this is normally an idempotent no-op.
    old_feature_comment = (
        "//   -define:SQLITE_HAS_NORMALIZE_API=true\n"
        "//\n"
        "// Homebrew SQLite 3.53.1 exports the preupdate and session families (65\n"
        "// symbols total), but not sqlite3_normalized_sql()."
    )
    new_feature_comment = (
        "//   -define:SQLITE_HAS_NORMALIZE_API=true\n"
        "//   -define:SQLITE_HAS_COLUMN_METADATA_API=true\n"
        "//   -define:SQLITE_HAS_UNLOCK_NOTIFY_API=true\n"
        "//   -define:SQLITE_HAS_STMT_SCANSTATUS_API=true\n"
        "//   -define:SQLITE_HAS_SNAPSHOT_API=true\n"
        "//\n"
        "// Homebrew SQLite 3.53.1 exports preupdate, session, column-metadata, and\n"
        "// unlock-notify (72 symbols total), but not normalize, statement scan-status,\n"
        "// or snapshot APIs."
    )
    if old_feature_comment in text:
        text, count = replace_one_required(
            text,
            old_feature_comment,
            new_feature_comment,
            "generated optional-feature documentation",
        )
        applied += count

    config_anchor = "HAS_SESSION_API :: #config(SQLITE_HAS_SESSION_API, false)"
    for gate in (
        "HAS_COLUMN_METADATA_API",
        "HAS_UNLOCK_NOTIFY_API",
        "HAS_STMT_SCANSTATUS_API",
        "HAS_SNAPSHOT_API",
    ):
        declaration = f"{gate} :: #config(SQLITE_{gate}, false)"
        if declaration not in text:
            text, count = replace_one_required(
                text,
                config_anchor,
                config_anchor + "\n" + declaration,
                f"{gate} generated availability config",
            )
            applied += count
        config_anchor = declaration

    # 1. Remove duplicate package insertion that can happen when imports_file
    # content is injected after the file's own package declaration.
    duplicate_package_block = 'import "core:c"\n\npackage raw\n\n'
    if duplicate_package_block in text:
        text, count = replace_one_required(
            text,
            duplicate_package_block,
            'import "core:c"\n\n',
            "duplicate package raw block after core:c import",
        )
        applied += count

    # 2. Foreign blocks must target the named sqlite import group.
    if "foreign lib {" in text:
        text, count = replace_all_required(
            text,
            "foreign lib {",
            "foreign sqlite {",
            "foreign lib to foreign sqlite replacement",
        )
        applied += count

    # 3. SQLite destructor sentinels need Odin-compatible definitions.
    # Odin's `::` constants cannot hold a transmuted proc pointer constructed
    # from a uintptr literal, and `@(rodata)` requires a compile-time constant
    # initializer which transmute is not. So these end up as package-scope
    # runtime variables. Treat as read-only at call sites — never reassign.
    if "STATIC      :: ((destructor_type)0)" in text:
        text, count = replace_one_required(
            text,
            "STATIC      :: ((destructor_type)0)",
            "// SQLITE_STATIC sentinel: pass to bind_*/result_* when the\n"
            "// caller-supplied buffer remains valid for SQLite's needs. Do\n"
            "// NOT reassign — wrapper APIs depend on the original value.\n"
            "STATIC: Destructor_Type = nil",
            "SQLITE_STATIC sentinel patch",
        )
        applied += count

    if "TRANSIENT   :: ((destructor_type)-1)" in text:
        text, count = replace_one_required(
            text,
            "TRANSIENT   :: ((destructor_type)-1)",
            "// SQLITE_TRANSIENT sentinel: tells SQLite to make its own copy of\n"
            "// the caller-supplied buffer. Do NOT reassign.\n"
            "TRANSIENT: Destructor_Type = transmute(Destructor_Type)(~uintptr(0))",
            "SQLITE_TRANSIENT sentinel patch",
        )
        applied += count

    # 4. Make ownership explicit for sqlite3_expanded_sql.
    if "expanded_sql   :: proc(pStmt: ^Stmt) -> cstring ---" in text:
        text, count = replace_one_required(
            text,
            "expanded_sql   :: proc(pStmt: ^Stmt) -> cstring ---",
            "expanded_sql   :: proc(pStmt: ^Stmt) -> rawptr ---",
            "expanded_sql return type patch",
        )
        applied += count

    # 5. Normalize sqlite3_column_text to cstring for UTF-8 text handling.
    if "column_text    :: proc(_: ^Stmt, iCol: i32) -> ^u8 ---" in text:
        text, count = replace_one_required(
            text,
            "column_text    :: proc(_: ^Stmt, iCol: i32) -> ^u8 ---",
            "column_text    :: proc(_: ^Stmt, iCol: i32) -> cstring ---",
            "column_text return type patch",
        )
        applied += count

    # 6. Ensure column_blob remains rawptr if generation changes later.
    if "column_blob    :: proc(_: ^Stmt, iCol: i32) -> rawptr ---" not in text:
        fail("column_blob rawptr declaration missing or changed unexpectedly")

    # 7. Deduplicate legacy CARRAY constants by renaming the second block.
    carray_legacy_block = (
        "/*\n"
        "** Versions of the above #defines that omit the initial SQLITE_, for\n"
        "** legacy compatibility.\n"
        "*/\n"
        "CARRAY_INT32     :: 0    /* Data is 32-bit signed integers */\n"
        "CARRAY_INT64     :: 1    /* Data is 64-bit signed integers */\n"
        "CARRAY_DOUBLE    :: 2    /* Data is doubles */\n"
        "CARRAY_TEXT      :: 3    /* Data is char* */\n"
        "CARRAY_BLOB      :: 4    /* Data is struct iovec */"
    )
    carray_legacy_replacement = (
        "/*\n"
        "** Versions of the above #defines that omit the initial SQLITE_, for\n"
        "** legacy compatibility.\n"
        "*/\n"
        "CARRAY_INT32_LEGACY     :: 0    /* Data is 32-bit signed integers */\n"
        "CARRAY_INT64_LEGACY     :: 1    /* Data is 64-bit signed integers */\n"
        "CARRAY_DOUBLE_LEGACY    :: 2    /* Data is doubles */\n"
        "CARRAY_TEXT_LEGACY      :: 3    /* Data is char* */\n"
        "CARRAY_BLOB_LEGACY      :: 4    /* Data is struct iovec */"
    )
    if carray_legacy_block in text:
        text, count = replace_one_required(
            text,
            carray_legacy_block,
            carray_legacy_replacement,
            "legacy CARRAY duplicate rename patch",
        )
        applied += count

    # 8. Restore all public, concrete record layouts that bindgen reduced to
    # forward-declaration placeholders. Helper callback aliases are inserted
    # once before the first record declaration.
    helper_block = STRUCT_HELPER_TYPES.strip()
    if helper_block not in text:
        file_decl = re.search(r"(?m)^File\s+:: struct", text)
        if file_decl is None:
            fail("File declaration missing; cannot insert struct helper types")
        text = text[: file_decl.start()] + helper_block + "\n\n" + text[file_decl.start() :]
        applied += 1

    for name, definition in CONCRETE_STRUCTS.items():
        empty_pattern = rf"(?m)^{re.escape(name)}\s+:: struct \{{\}}$"
        matches = list(re.finditer(empty_pattern, text))
        if len(matches) > 1:
            fail(f"expected at most one empty declaration for {name}, found {len(matches)}")
        if matches:
            replacement = f"{name} :: {definition}"
            text = re.sub(empty_pattern, lambda _: replacement, text, count=1)
            applied += 1

    # 9. Gate declarations whose symbols only exist in feature-enabled SQLite
    # builds. The header defines control source visibility during bindgen;
    # these Odin #config gates control consumer visibility/link availability.
    normalized_decl = "\tnormalized_sql :: proc(pStmt: ^Stmt) -> cstring ---"
    normalized_gated = (
        "\twhen HAS_NORMALIZE_API {\n"
        f"{normalized_decl}\n"
        "\t}"
    )
    if normalized_gated not in text:
        text, count = replace_one_required(
            text,
            normalized_decl,
            normalized_gated,
            "sqlite3_normalized_sql availability gate",
        )
        applied += count

    preupdate_decls = (
        "\tpreupdate_hook      :: proc(db: ^Sqlite3, xPreUpdate: proc \"c\" (pCtx: rawptr, db: ^Sqlite3, op: i32, zDb: cstring, zName: cstring, iKey1: Int64, iKey2: Int64 /* New rowid value (for a rowid UPDATE) */), _: rawptr) -> rawptr ---\n"
        "\tpreupdate_old       :: proc(^Sqlite3, i32, ^^Value) -> i32 ---\n"
        "\tpreupdate_count     :: proc(^Sqlite3) -> i32 ---\n"
        "\tpreupdate_depth     :: proc(^Sqlite3) -> i32 ---\n"
        "\tpreupdate_new       :: proc(^Sqlite3, i32, ^^Value) -> i32 ---\n"
        "\tpreupdate_blobwrite :: proc(^Sqlite3) -> i32 ---"
    )
    preupdate_gated = (
        "\twhen HAS_PREUPDATE_API {\n"
        f"{preupdate_decls}\n"
        "\t}"
    )
    if preupdate_gated not in text:
        text, count = replace_one_required(
            text,
            preupdate_decls,
            preupdate_gated,
            "sqlite3_preupdate_* availability gate",
        )
        applied += count

    column_metadata_decls = (
        "\tcolumn_database_name   :: proc(^Stmt, i32) -> cstring ---\n"
        "\tcolumn_database_name16 :: proc(^Stmt, i32) -> rawptr ---\n"
        "\tcolumn_table_name      :: proc(^Stmt, i32) -> cstring ---\n"
        "\tcolumn_table_name16    :: proc(^Stmt, i32) -> rawptr ---\n"
        "\tcolumn_origin_name     :: proc(^Stmt, i32) -> cstring ---\n"
        "\tcolumn_origin_name16   :: proc(^Stmt, i32) -> rawptr ---"
    )
    column_metadata_gated = (
        "\twhen HAS_COLUMN_METADATA_API {\n"
        f"{column_metadata_decls}\n"
        "\t}"
    )
    if column_metadata_gated not in text:
        text, count = replace_one_required(
            text,
            column_metadata_decls,
            column_metadata_gated,
            "sqlite3_column_* metadata availability gate",
        )
        applied += count

    unlock_notify_decl = (
        "\tunlock_notify :: proc(pBlocked: ^Sqlite3, xNotify: proc \"c\" "
        "(apArg: ^rawptr, nArg: i32), pNotifyArg: rawptr /* Argument to pass "
        "to xNotify */) -> i32 ---"
    )
    unlock_notify_gated = (
        "\twhen HAS_UNLOCK_NOTIFY_API {\n"
        f"{unlock_notify_decl}\n"
        "\t}"
    )
    if unlock_notify_gated not in text:
        text, count = replace_one_required(
            text,
            unlock_notify_decl,
            unlock_notify_gated,
            "sqlite3_unlock_notify availability gate",
        )
        applied += count

    stmt_scanstatus_decls = (
        "\tstmt_scanstatus    :: proc(pStmt: ^Stmt, idx: i32, iScanStatusOp: "
        "i32, pOut: rawptr /* Result written here */) -> i32 ---\n"
        "\tstmt_scanstatus_v2 :: proc(pStmt: ^Stmt, idx: i32, iScanStatusOp: "
        "i32, flags: i32, pOut: rawptr /* Result written here */) -> i32 ---"
    )
    stmt_scanstatus_gated = (
        "\twhen HAS_STMT_SCANSTATUS_API {\n"
        f"{stmt_scanstatus_decls}\n"
        "\t}"
    )
    if stmt_scanstatus_gated not in text:
        text, count = replace_one_required(
            text,
            stmt_scanstatus_decls,
            stmt_scanstatus_gated,
            "sqlite3_stmt_scanstatus availability gate",
        )
        applied += count

    stmt_scanstatus_reset_decl = "\tstmt_scanstatus_reset :: proc(^Stmt) ---"
    stmt_scanstatus_reset_gated = (
        "\twhen HAS_STMT_SCANSTATUS_API {\n"
        f"{stmt_scanstatus_reset_decl}\n"
        "\t}"
    )
    if stmt_scanstatus_reset_gated not in text:
        text, count = replace_one_required(
            text,
            stmt_scanstatus_reset_decl,
            stmt_scanstatus_reset_gated,
            "sqlite3_stmt_scanstatus_reset availability gate",
        )
        applied += count

    snapshot_type = "Snapshot :: struct {\n\thidden: [48]u8,\n}"
    snapshot_type_gated = (
        "when HAS_SNAPSHOT_API {\n"
        f"{snapshot_type}\n"
        "}"
    )
    if snapshot_type_gated not in text:
        text, count = replace_one_required(
            text,
            snapshot_type,
            snapshot_type_gated,
            "sqlite3_snapshot type availability gate",
        )
        applied += count

    snapshot_first_decl = (
        "\tsnapshot_get :: proc(db: ^Sqlite3, zSchema: cstring, "
        "ppSnapshot: ^^Snapshot) -> i32 ---"
    )
    snapshot_first_gated = "\twhen HAS_SNAPSHOT_API {\n" + snapshot_first_decl
    if snapshot_first_gated not in text:
        text, count = replace_one_required(
            text,
            snapshot_first_decl,
            snapshot_first_gated,
            "sqlite3_snapshot function availability gate start",
        )
        applied += count

    snapshot_last_decl = (
        "\tsnapshot_recover :: proc(db: ^Sqlite3, zDb: cstring) -> i32 ---"
    )
    snapshot_last_gated = snapshot_last_decl + "\n\t}"
    if snapshot_last_gated not in text:
        text, count = replace_one_required(
            text,
            snapshot_last_decl,
            snapshot_last_gated,
            "sqlite3_snapshot function availability gate end",
        )
        applied += count

    # Header guards are implementation details, not public SQLite constants.
    header_guard = "__SQLITESESSION_H_ :: 1\n"
    if header_guard in text:
        text = text.replace(header_guard, "", 1)
        applied += 1

    session_start = "Session        :: struct {}\nChangeset_Iter :: struct {}"
    session_end = "\nFts5context             :: struct {}"
    if "when HAS_SESSION_API {\n" not in text:
        start = text.find(session_start)
        end = text.find(session_end, start)
        if start < 0 or end < 0:
            fail("could not locate complete SQLite session declaration region")
        session_region = text[start:end]
        prefixed_annotation = '@(default_calling_convention="c", link_prefix="sqlite3_")'
        annotation_count = session_region.count(prefixed_annotation)
        if annotation_count == 0:
            fail("session declaration region contains no foreign annotations")
        # Session symbols are spelled sqlite3session_*, sqlite3changeset_*,
        # sqlite3changegroup_*, and sqlite3rebaser_* (no underscore after
        # sqlite3), so the normal sqlite3_ link prefix must not be applied.
        session_region = session_region.replace(
            prefixed_annotation,
            '@(default_calling_convention="c")',
        )
        text = (
            text[:start]
            + "when HAS_SESSION_API {\n"
            + session_region
            + "\n}\n"
            + text[end:]
        )
        applied += annotation_count + 1

    if text != original:
        RAW_GENERATED.write_text(text, encoding="utf-8")

    # Sanity checks after patching.
    if "foreign lib {" in text:
        fail("post-patch verification failed: foreign lib blocks still remain")

    if "STATIC      :: ((destructor_type)0)" in text or "TRANSIENT   :: ((destructor_type)-1)" in text:
        fail("post-patch verification failed: destructor sentinels still in invalid form")

    if "STATIC: Destructor_Type = nil" not in text:
        fail("post-patch verification failed: STATIC patch missing")
    if "TRANSIENT: Destructor_Type = transmute(Destructor_Type)(~uintptr(0))" not in text:
        fail("post-patch verification failed: TRANSIENT patch missing")

    if "expanded_sql   :: proc(pStmt: ^Stmt) -> rawptr ---" not in text:
        fail("post-patch verification failed: expanded_sql is not patched to rawptr")

    if "column_text    :: proc(_: ^Stmt, iCol: i32) -> cstring ---" not in text:
        fail("post-patch verification failed: column_text is not patched to cstring")

    if text.count("CARRAY_INT32     :: 0    /* Data is 32-bit signed integers */") != 1:
        fail("post-patch verification failed: canonical CARRAY_INT32 definition count is not exactly 1")

    if "CARRAY_INT32_LEGACY" not in text:
        fail("post-patch verification failed: legacy CARRAY block was not renamed")

    concrete_names = set(CONCRETE_STRUCTS) | {
        "Index_Constraint",
        "Index_Orderby",
        "Index_Constraint_Usage",
        "Snapshot",
    }
    if len(concrete_names) != 23:
        fail(f"internal concrete struct inventory is not 23 (found {len(concrete_names)})")
    for name in sorted(concrete_names):
        if re.search(rf"(?m)^{re.escape(name)}\s+:: struct \{{\}}$", text):
            fail(f"post-patch verification failed: concrete struct {name} is still empty")
        if not re.search(rf"(?m)^{re.escape(name)}\s+:: struct \{{", text):
            fail(f"post-patch verification failed: concrete struct {name} is missing")

    for gate in FEATURE_GATED_API_SYMBOLS:
        if f"when {gate} {{" not in text:
            fail(f"post-patch verification failed: {gate} declaration gate is missing")

    for gated_snippet, description in (
        (column_metadata_gated, "column metadata"),
        (unlock_notify_gated, "unlock-notify"),
        (stmt_scanstatus_gated, "statement scan-status"),
        (stmt_scanstatus_reset_gated, "statement scan-status reset"),
        (snapshot_type_gated, "snapshot type"),
        (snapshot_first_gated, "snapshot functions start"),
        (snapshot_last_gated, "snapshot functions end"),
    ):
        if gated_snippet not in text:
            fail(f"post-patch verification failed: {description} gate is incomplete")

    if "sqlite3_activate_cerod" in text or "activate_cerod ::" in text:
        fail("post-patch verification failed: unsupported sqlite3_activate_cerod is exposed")

    if (
        len(OPTIONAL_API_SYMBOLS) != EXPECTED_OPTIONAL_API_COUNT
        or len(set(OPTIONAL_API_SYMBOLS)) != EXPECTED_OPTIONAL_API_COUNT
    ):
        fail(
            f"internal optional API inventory must contain "
            f"{EXPECTED_OPTIONAL_API_COUNT} unique symbols"
        )
    for symbol in OPTIONAL_API_SYMBOLS:
        local_name = symbol.removeprefix("sqlite3_")
        declaration_count = len(
            re.findall(rf"(?m)^\s*{re.escape(local_name)}\s+:: proc", text)
        )
        if declaration_count != 1:
            fail(
                f"post-patch verification failed: optional API {symbol} has "
                f"{declaration_count} declarations"
            )

    ensure_file(PINNED_SQLITE_HEADER)
    published_symbols = published_header_api_symbols(
        PINNED_SQLITE_HEADER.read_text(encoding="utf-8")
    )
    optional_symbols = set(OPTIONAL_API_SYMBOLS)
    expected_published_count = (
        EXPECTED_BASELINE_API_COUNT + EXPECTED_OPTIONAL_API_COUNT + 1
    )
    if len(published_symbols) != expected_published_count:
        fail(
            "pinned header public API inventory changed: "
            f"found {len(published_symbols)}, expected {expected_published_count} "
            "(283 baseline + 81 optional + CEROD)"
        )
    if not optional_symbols.issubset(published_symbols):
        fail(
            "optional API inventory contains symbols absent from the pinned header: "
            f"{sorted(optional_symbols - published_symbols)}"
        )
    if UNSUPPORTED_CEROD_SYMBOL not in published_symbols:
        fail("pinned header no longer contains the explicitly excluded CEROD declaration")

    baseline_symbols = published_symbols - optional_symbols - {UNSUPPORTED_CEROD_SYMBOL}
    if len(baseline_symbols) != EXPECTED_BASELINE_API_COUNT:
        fail(
            f"baseline API inventory must contain {EXPECTED_BASELINE_API_COUNT} symbols; "
            f"found {len(baseline_symbols)}"
        )
    for symbol in sorted(baseline_symbols):
        local_name = symbol.removeprefix("sqlite3_")
        declaration_count = len(
            re.findall(rf"(?m)^\s*{re.escape(local_name)}\s+:: proc", text)
        )
        if declaration_count != 1:
            fail(
                f"post-patch verification failed: baseline API {symbol} has "
                f"{declaration_count} declarations"
            )

    for type_name in OPTIONAL_API_TYPES:
        if not re.search(rf"(?m)^\s*{re.escape(type_name)}\s+:: struct \{{\}}$", text):
            fail(f"post-patch verification failed: optional type {type_name} is missing")
    if snapshot_type_gated not in text:
        fail("post-patch verification failed: optional concrete type Snapshot is not gated")
    for constant_name in OPTIONAL_API_CONSTANTS:
        if not re.search(rf"(?m)^\s*{re.escape(constant_name)}\s+::", text):
            fail(f"post-patch verification failed: optional constant {constant_name} is missing")

    gated_session_start = text.find("when HAS_SESSION_API {\n")
    gated_session_end = text.find(session_end, gated_session_start)
    if gated_session_start < 0 or gated_session_end < 0:
        fail("post-patch verification failed: gated session region is incomplete")
    gated_session_region = text[gated_session_start:gated_session_end]
    if 'link_prefix="sqlite3_"' in gated_session_region:
        fail("post-patch verification failed: session declarations have an invalid sqlite3_ link prefix")

    ensure_once(
        text,
        'SQLITE_LIB :: #config(SQLITE_LIB, DEFAULT_SQLITE_LIB)',
        "configurable SQLite library declaration in generated file",
    )
    ensure_once(
        text,
        '"system:sqlite3.lib" when ODIN_OS == .Windows else\n\t"system:sqlite3"',
        "platform-default SQLite library selection in generated file",
    )
    ensure_once(
        text,
        "foreign import sqlite { SQLITE_LIB }",
        "configurable SQLite foreign import in generated file",
    )
    for gate in FEATURE_GATED_API_SYMBOLS:
        ensure_once(
            text,
            f"{gate} :: #config(SQLITE_{gate}, false)",
            f"SQLite {gate.lower()} availability config in generated file",
        )

    return PatchResult(changed=text != original, applied_count=applied)


def run_checked(command: list[str], *, cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            check=False,
            text=True,
            capture_output=True,
        )
    except OSError as exc:
        fail(f"could not execute {command[0]}: {exc}")

    if result.returncode != 0:
        details = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
        fail(
            f"command failed ({result.returncode}): {' '.join(command)}"
            + (f"\n{details}" if details else "")
        )
    return result.stdout


def parse_layout_output(output: str, source: str) -> dict[tuple[str, ...], tuple[int, ...]]:
    parsed: dict[tuple[str, ...], tuple[int, ...]] = {}
    for line in output.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split("|")
        if parts[0] == "S" and len(parts) == 4:
            key = ("S", parts[1])
            value = (int(parts[2]), int(parts[3]))
        elif parts[0] == "F" and len(parts) == 4:
            key = ("F", parts[1], parts[2])
            value = (int(parts[3]),)
        else:
            fail(f"unexpected ABI probe output from {source}: {line!r}")
        if key in parsed:
            fail(f"duplicate ABI probe key from {source}: {key}")
        parsed[key] = value
    return parsed


def c_abi_probe_source(header: Path) -> str:
    escaped_header = str(header.resolve()).replace("\\", "\\\\").replace('"', '\\"')
    lines = [
        "#include <stddef.h>",
        "#include <stdio.h>",
        f'#include "{escaped_header}"',
        "int main(void) {",
    ]
    for c_name, odin_name, fields in ABI_STRUCTS:
        lines.append(
            f'  printf("S|{odin_name}|%zu|%zu\\n", sizeof({c_name}), _Alignof({c_name}));'
        )
        for field in fields:
            lines.append(
                f'  printf("F|{odin_name}|{field}|%zu\\n", offsetof({c_name}, {field}));'
            )
    lines.extend(("  return 0;", "}", ""))
    return "\n".join(lines)


def odin_abi_probe_source() -> str:
    lines = [
        "package main",
        "",
        'import "core:fmt"',
        'import raw "project:sqlite/raw/generated"',
        "",
        "main :: proc() {",
    ]
    for _, odin_name, fields in ABI_STRUCTS:
        lines.append(
            f'\tfmt.printf("S|{odin_name}|%d|%d\\n", size_of(raw.{odin_name}), align_of(raw.{odin_name}))'
        )
        for field in fields:
            lines.append(
                f'\tfmt.printf("F|{odin_name}|{field}|%d\\n", offset_of(raw.{odin_name}, {field}))'
            )
    lines.extend(("}", ""))
    return "\n".join(lines)


def odin_optional_link_probe_source() -> str:
    linked_symbols = [
        symbol for symbol in OPTIONAL_API_SYMBOLS
        if symbol not in HOST_MISSING_OPTIONAL_SYMBOLS
    ]
    lines = [
        "package main",
        "",
        'import "core:fmt"',
        'import raw "project:sqlite/raw/generated"',
        "",
        "main :: proc() {",
        f"\treferences := [{len(linked_symbols)}]rawptr {{",
    ]
    for symbol in linked_symbols:
        local_name = symbol.removeprefix("sqlite3_")
        lines.append(f"\t\ttransmute(rawptr)(raw.{local_name}),")
    lines.extend(
        (
            "\t}",
            '\tfmt.printf("linked optional symbols: %d\\n", len(references))',
            "}",
            "",
        )
    )
    return "\n".join(lines)


def verify_abi() -> None:
    if len(ABI_STRUCTS) != 23:
        fail(f"ABI inventory must contain 23 structs, found {len(ABI_STRUCTS)}")
    field_count = sum(len(fields) for _, _, fields in ABI_STRUCTS)
    expected_entry_count = len(ABI_STRUCTS) + field_count

    clang = shutil.which("clang")
    odin = shutil.which("odin")
    if clang is None:
        fail("clang is required for --verify-abi")
    if odin is None:
        fail("odin is required for --verify-abi")

    headers = (
        PROJECT_ROOT / "input" / "sqlite3.h",
        PROJECT_ROOT / "input" / "sqlite3.h.macos26",
    )
    for header in headers:
        ensure_file(header)

    with tempfile.TemporaryDirectory(prefix="odin-sqlite3-abi-") as temp_name:
        temp_dir = Path(temp_name)
        odin_source = temp_dir / "abi_probe.odin"
        odin_source.write_text(odin_abi_probe_source(), encoding="utf-8")
        odin_output = run_checked(
            [
                odin,
                "run",
                str(temp_dir),
                f"-collection:project={PROJECT_ROOT}",
                "-define:SQLITE_HAS_SNAPSHOT_API=true",
            ],
            cwd=PROJECT_ROOT,
        )
        odin_layout = parse_layout_output(odin_output, "Odin")
        if len(odin_layout) != expected_entry_count:
            fail(
                f"Odin ABI probe returned {len(odin_layout)} entries; "
                f"expected {expected_entry_count}"
            )

        for index, header in enumerate(headers):
            c_source = temp_dir / f"abi_probe_{index}.c"
            c_binary = temp_dir / f"abi_probe_{index}"
            c_source.write_text(c_abi_probe_source(header), encoding="utf-8")
            run_checked(
                [clang, "-std=c11", "-Wall", "-Wextra", "-Werror", str(c_source), "-o", str(c_binary)],
                cwd=PROJECT_ROOT,
            )
            c_layout = parse_layout_output(
                run_checked([str(c_binary)], cwd=PROJECT_ROOT),
                str(header.relative_to(PROJECT_ROOT)),
            )
            if c_layout.keys() != odin_layout.keys():
                missing = sorted(odin_layout.keys() - c_layout.keys())
                extra = sorted(c_layout.keys() - odin_layout.keys())
                fail(
                    f"ABI probe key mismatch for {header.name}: "
                    f"missing={missing}, extra={extra}"
                )
            mismatches = [
                (key, c_layout[key], odin_layout[key])
                for key in c_layout
                if c_layout[key] != odin_layout[key]
            ]
            if mismatches:
                details = "\n".join(
                    f"  {key}: C={c_value}, Odin={odin_value}"
                    for key, c_value, odin_value in mismatches
                )
                fail(f"ABI mismatch against {header.name}:\n{details}")

    print(
        f"ABI verified: {len(ABI_STRUCTS)} structs, {field_count} field offsets, "
        f"size/alignment against {len(headers)} C headers."
    )


def verify_host_symbols(library: Path) -> None:
    ensure_file(library)
    nm = shutil.which("nm")
    if nm is None:
        fail("nm is required for --verify-host-symbols")

    if sys.platform == "darwin":
        output = run_checked([nm, "-gU", str(library)])
    else:
        output = run_checked([nm, "-D", "--defined-only", str(library)])

    exported: set[str] = set()
    for token in re.findall(r"\b_?sqlite3[A-Za-z0-9_]+\b", output):
        exported.add(token[1:] if token.startswith("_sqlite3") else token)

    optional = set(OPTIONAL_API_SYMBOLS)
    present = optional & exported
    missing = optional - exported
    if (
        len(present) != EXPECTED_HOST_OPTIONAL_API_COUNT
        or missing != HOST_MISSING_OPTIONAL_SYMBOLS
    ):
        fail(
            f"host optional symbol profile mismatch for {library}: "
            f"present={len(present)}/{EXPECTED_OPTIONAL_API_COUNT}, "
            f"missing={sorted(missing)}"
        )
    if UNSUPPORTED_CEROD_SYMBOL in exported:
        fail(f"unsupported {UNSUPPORTED_CEROD_SYMBOL} is unexpectedly exported by {library}")

    odin = shutil.which("odin")
    if odin is None:
        fail("odin is required for --verify-host-symbols")
    with tempfile.TemporaryDirectory(prefix="odin-sqlite3-link-") as temp_name:
        temp_dir = Path(temp_name)
        (temp_dir / "link_probe.odin").write_text(
            odin_optional_link_probe_source(),
            encoding="utf-8",
        )
        command = [
            odin,
            "build",
            str(temp_dir),
            f"-collection:project={PROJECT_ROOT}",
            *(f"-define:SQLITE_{gate}=true" for gate in HOST_ENABLED_FEATURE_GATES),
            f"-define:SQLITE_LIB=system:{library.resolve()}",
            f"-out:{temp_dir / 'link_probe'}",
        ]
        run_checked(
            command,
            cwd=PROJECT_ROOT,
        )

    print(
        f"Host symbols verified: {EXPECTED_HOST_OPTIONAL_API_COUNT}/"
        f"{EXPECTED_OPTIONAL_API_COUNT} optional APIs exported by {library}; "
        f"all {EXPECTED_HOST_OPTIONAL_API_COUNT} linked through Odin; "
        "normalize, statement scan-status, snapshot, and sqlite3_activate_cerod "
        "are absent."
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verify-abi",
        action="store_true",
        help="compile C and Odin probes and compare all public struct layouts",
    )
    parser.add_argument(
        "--verify-host-symbols",
        type=Path,
        metavar="SQLITE_LIBRARY",
        help="verify the known 72/81 optional-symbol profile of a SQLite library",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    print("Applying post-generation SQLite binding patches...")
    imports_result = patch_imports_file()
    generated_result = patch_generated_file()

    print(
        f"Patched imports: {'yes' if imports_result.changed else 'no'} "
        f"(operations={imports_result.applied_count})"
    )
    print(
        f"Patched generated raw file: {'yes' if generated_result.changed else 'no'} "
        f"(operations={generated_result.applied_count})"
    )
    print(
        f"API coverage verified: {EXPECTED_BASELINE_API_COUNT}/"
        f"{EXPECTED_BASELINE_API_COUNT} baseline and "
        f"{EXPECTED_OPTIONAL_API_COUNT}/{EXPECTED_OPTIONAL_API_COUNT} optional; "
        "sqlite3_activate_cerod excluded."
    )
    print("Post-generation patching complete.")
    if args.verify_abi:
        verify_abi()
    if args.verify_host_symbols is not None:
        verify_host_symbols(args.verify_host_symbols)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
