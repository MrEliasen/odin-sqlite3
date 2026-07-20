#!/usr/bin/env python3
"""Download, verify, and build the SQLite library used by qualification CI."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


SQLITE_VERSION = "3530100"
SQLITE_RELEASE_YEAR = "2026"
SQLITE_ARCHIVE_NAME = f"sqlite-autoconf-{SQLITE_VERSION}.tar.gz"
SQLITE_ARCHIVE_URL = (
    f"https://sqlite.org/{SQLITE_RELEASE_YEAR}/{SQLITE_ARCHIVE_NAME}"
)
SQLITE_ARCHIVE_SHA256 = (
    "83e6b2020a034e9a7ad4a72feea59e1ad52f162e09cbd26735a3ffb98359fc4f"
)
SQLITE_C_SHA3_256 = (
    "414432ae5719f6cdc485f3927e12c7ad107e2b8c6b434e5df2eadb5312bfabb5"
)

SQLITE_FEATURE_DEFINES = (
    "SQLITE_ENABLE_NORMALIZE=1",
    "SQLITE_ENABLE_PREUPDATE_HOOK=1",
    "SQLITE_ENABLE_SESSION=1",
    "SQLITE_ENABLE_COLUMN_METADATA=1",
    "SQLITE_ENABLE_UNLOCK_NOTIFY=1",
    "SQLITE_ENABLE_STMT_SCANSTATUS=1",
    "SQLITE_ENABLE_SNAPSHOT=1",
    "SQLITE_THREADSAFE=1",
)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def run_checked(command: list[str]) -> None:
    print("+ " + " ".join(command), flush=True)
    try:
        subprocess.run(command, check=True)
    except FileNotFoundError:
        fail(f"required command was not found: {command[0]}")
    except subprocess.CalledProcessError as error:
        fail(f"command failed with exit code {error.returncode}: {command[0]}")


def file_digest(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_archive(destination: Path) -> None:
    request = urllib.request.Request(
        SQLITE_ARCHIVE_URL,
        headers={"User-Agent": "odin-sqlite-qualification/1"},
    )
    print(f"Downloading {SQLITE_ARCHIVE_URL}", flush=True)
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            with destination.open("wb") as output:
                shutil.copyfileobj(response, output)
    except OSError as error:
        fail(f"could not download pinned SQLite source: {error}")


def verified_archive(source: Path | None, temp_dir: Path) -> Path:
    archive = source.resolve() if source is not None else temp_dir / SQLITE_ARCHIVE_NAME
    if source is None:
        download_archive(archive)
    if not archive.is_file():
        fail(f"SQLite archive does not exist: {archive}")

    actual = file_digest(archive, "sha256")
    if actual != SQLITE_ARCHIVE_SHA256:
        fail(
            f"SQLite archive SHA-256 mismatch: expected {SQLITE_ARCHIVE_SHA256}, "
            f"found {actual}"
        )
    print(f"Verified {archive.name} SHA-256: {actual}", flush=True)
    return archive


def read_archive_member(archive: Path, basename: str) -> bytes:
    expected = f"sqlite-autoconf-{SQLITE_VERSION}/{basename}"
    try:
        with tarfile.open(archive, mode="r:gz") as bundle:
            member = bundle.getmember(expected)
            if not member.isfile():
                fail(f"SQLite archive member is not a regular file: {expected}")
            extracted = bundle.extractfile(member)
            if extracted is None:
                fail(f"could not read SQLite archive member: {expected}")
            return extracted.read()
    except (KeyError, tarfile.TarError) as error:
        fail(f"invalid SQLite archive: {error}")


def materialize_sources(archive: Path, source_dir: Path) -> tuple[Path, Path]:
    source_dir.mkdir(parents=True, exist_ok=True)
    sqlite_c = source_dir / "sqlite3.c"
    sqlite_h = source_dir / "sqlite3.h"
    sqlite_c.write_bytes(read_archive_member(archive, "sqlite3.c"))
    sqlite_h.write_bytes(read_archive_member(archive, "sqlite3.h"))

    actual_c_hash = hashlib.sha3_256(sqlite_c.read_bytes()).hexdigest()
    if actual_c_hash != SQLITE_C_SHA3_256:
        fail(
            f"sqlite3.c SHA3-256 mismatch: expected {SQLITE_C_SHA3_256}, "
            f"found {actual_c_hash}"
        )
    print(f"Verified sqlite3.c SHA3-256: {actual_c_hash}", flush=True)
    return sqlite_c, sqlite_h


def build_posix(sqlite_c: Path, output_dir: Path) -> Path:
    compiler = os.environ.get("CC", "cc")
    archiver = os.environ.get("AR", "ar")
    object_path = output_dir / "sqlite3.o"
    library_path = output_dir / "libsqlite3.a"
    compile_command = [
        compiler,
        "-std=c11",
        "-O2",
        "-fPIC",
        *(f"-D{define}" for define in SQLITE_FEATURE_DEFINES),
        "-c",
        str(sqlite_c),
        "-o",
        str(object_path),
    ]
    run_checked(compile_command)
    run_checked([archiver, "rcs", str(library_path), str(object_path)])
    return library_path


def build_windows(sqlite_c: Path, output_dir: Path) -> Path:
    compiler = os.environ.get("CC", "cl")
    archiver = os.environ.get("SQLITE_ARCHIVER", "lib")
    object_path = output_dir / "sqlite3.obj"
    library_path = output_dir / "sqlite3.lib"
    compile_command = [
        compiler,
        "/nologo",
        "/O2",
        "/utf-8",
        *(f"/D{define}" for define in SQLITE_FEATURE_DEFINES),
        "/c",
        str(sqlite_c),
        f"/Fo{object_path}",
    ]
    run_checked(compile_command)
    run_checked([archiver, "/nologo", f"/OUT:{library_path}", str(object_path)])
    return library_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("out/ci-sqlite"),
        help="directory for verified sources and the static library",
    )
    parser.add_argument(
        "--archive",
        type=Path,
        help="use an existing archive instead of downloading it",
    )
    parser.add_argument(
        "--header-output",
        type=Path,
        help="also copy the verified sqlite3.h to this path",
    )
    parser.add_argument(
        "--header-only",
        action="store_true",
        help="verify/materialize sources without compiling the library",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_dir = args.output.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="odin-sqlite-source-") as temp_name:
        archive = verified_archive(args.archive, Path(temp_name))
        sqlite_c, sqlite_h = materialize_sources(archive, output_dir)

    if args.header_output is not None:
        header_output = args.header_output.resolve()
        header_output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(sqlite_h, header_output)
        print(f"Wrote verified header: {header_output}", flush=True)

    if args.header_only:
        print("SQLite source verification complete (header-only mode).", flush=True)
        return 0

    library = (
        build_windows(sqlite_c, output_dir)
        if os.name == "nt"
        else build_posix(sqlite_c, output_dir)
    )
    if not library.is_file() or library.stat().st_size == 0:
        fail(f"SQLite static library was not created: {library}")
    print(f"SQLite qualification library: {library.resolve()}", flush=True)
    print(
        "Enabled SQLite feature profile: normalize, preupdate, session, "
        "column metadata, unlock-notify, statement scan-status, snapshot",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
