#!/usr/bin/env python3
"""Fail-fast native, cross-target, and sanitizer qualification for odin-sqlite."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
from typing import Callable, Sequence


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_PACKAGE = PROJECT_ROOT / "sqlite" / "raw" / "generated"
WRAPPER_PACKAGE = PROJECT_ROOT / "sqlite"
TEST_PACKAGE = PROJECT_ROOT / "tests"
EXAMPLES_ROOT = PROJECT_ROOT / "packaging" / "examples"

CROSS_TARGETS = (
    "darwin_amd64",
    "darwin_arm64",
    "linux_amd64",
    "linux_arm64",
    "windows_amd64",
)

ALL_FEATURE_DEFINES = (
    "SQLITE_HAS_NORMALIZE_API",
    "SQLITE_HAS_PREUPDATE_API",
    "SQLITE_HAS_SESSION_API",
    "SQLITE_HAS_COLUMN_METADATA_API",
    "SQLITE_HAS_UNLOCK_NOTIFY_API",
    "SQLITE_HAS_STMT_SCANSTATUS_API",
    "SQLITE_HAS_SNAPSHOT_API",
)

Runner = Callable[..., subprocess.CompletedProcess[bytes] | subprocess.CompletedProcess[str]]


class QualificationError(RuntimeError):
    pass


def display_command(command: Sequence[str]) -> str:
    return shlex.join(str(part) for part in command)


def run_commands(
    commands: Sequence[Sequence[str]],
    *,
    environment: dict[str, str] | None = None,
    runner: Runner = subprocess.run,
) -> None:
    """Run commands in order and stop immediately after the first failure."""
    for command in commands:
        rendered = [str(part) for part in command]
        print(f"+ {display_command(rendered)}", flush=True)
        try:
            runner(rendered, cwd=PROJECT_ROOT, env=environment, check=True)
        except FileNotFoundError as error:
            raise QualificationError(
                f"required command was not found: {rendered[0]}"
            ) from error
        except subprocess.CalledProcessError as error:
            raise QualificationError(
                f"command failed with exit code {error.returncode}: "
                f"{display_command(rendered)}"
            ) from error


def require_generated_bindings() -> None:
    generated = RAW_PACKAGE / "sqlite3.odin"
    if not generated.is_file():
        raise QualificationError(
            "generated raw bindings are missing; run `make regenerate` first"
        )


def find_examples() -> list[Path]:
    examples = sorted(path.parent for path in EXAMPLES_ROOT.rglob("main.odin"))
    if not examples:
        raise QualificationError(f"no examples found below {EXAMPLES_ROOT}")
    return examples


def feature_arguments(profile: str) -> list[str]:
    if profile == "default":
        return []
    if profile == "all":
        return [f"-define:{name}=true" for name in ALL_FEATURE_DEFINES]
    raise QualificationError(f"unknown SQLite feature profile: {profile}")


def sqlite_library_argument(library: Path | None) -> list[str]:
    if library is None:
        return []
    resolved = library.resolve()
    if not resolved.is_file():
        raise QualificationError(f"SQLite library does not exist: {resolved}")
    # Forward slashes are accepted by Odin on every host and avoid a quoted
    # backslash becoming part of the Windows #config string.
    return [f"-define:SQLITE_LIB=system:{resolved.as_posix()}"]


def native_commands(
    odin: str,
    library: Path | None,
    feature_profile: str,
    output_dir: Path,
    sanitizer: str | None = None,
) -> list[list[str]]:
    feature_args = feature_arguments(feature_profile)
    library_args = sqlite_library_argument(library)
    build_args = [*feature_args, *library_args, "-debug"]
    if sanitizer is not None:
        build_args.append(f"-sanitize:{sanitizer}")

    commands: list[list[str]] = [
        [odin, "check", str(WRAPPER_PACKAGE), "-no-entry-point", *feature_args, *library_args],
        [odin, "check", str(TEST_PACKAGE), *feature_args, *library_args],
    ]
    commands.extend(
        [odin, "check", str(example), *feature_args, *library_args]
        for example in find_examples()
    )
    commands.append(
        [odin, "run", str(TEST_PACKAGE), *build_args, f"-out:{output_dir / 'tests'}"]
    )
    commands.extend(
        [
            odin,
            "run",
            str(example),
            *build_args,
            f"-out:{output_dir / f'example-{index}'}",
        ]
        for index, example in enumerate(find_examples())
    )
    return commands


def cross_check_commands(odin: str, targets: Sequence[str]) -> list[list[str]]:
    if not targets:
        raise QualificationError("at least one cross target is required")
    commands: list[list[str]] = []
    for target in targets:
        for profile in ("default", "all"):
            feature_args = feature_arguments(profile)
            for package_path in (RAW_PACKAGE, WRAPPER_PACKAGE):
                commands.append(
                    [
                        odin,
                        "check",
                        str(package_path),
                        "-no-entry-point",
                        f"-target:{target}",
                        *feature_args,
                    ]
                )
    return commands


def sanitizer_environment(odin: str) -> dict[str, str]:
    environment = os.environ.copy()
    try:
        help_result = subprocess.run(
            [odin, "help", "build"],
            cwd=PROJECT_ROOT,
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as error:
        raise QualificationError("could not query Odin sanitizer support") from error
    if "-sanitize:address" not in help_result.stdout:
        raise QualificationError("this Odin compiler does not advertise address sanitizer support")

    if sys.platform == "darwin":
        llvm_bin = os.environ.get("ODIN_SANITIZER_LLVM_BIN")
        if llvm_bin is None:
            brew = shutil.which("brew")
            if brew is not None:
                try:
                    prefix = subprocess.check_output(
                        [brew, "--prefix", "llvm"],
                        cwd=PROJECT_ROOT,
                        env=environment,
                        text=True,
                    ).strip()
                except subprocess.CalledProcessError as error:
                    raise QualificationError(
                        "Homebrew LLVM is required for reliable macOS ASan linking; "
                        "install it or set ODIN_SANITIZER_LLVM_BIN"
                    ) from error
                llvm_bin = str(Path(prefix) / "bin")
        if llvm_bin is None:
            raise QualificationError(
                "Homebrew LLVM is required for reliable macOS ASan linking; "
                "install it or set ODIN_SANITIZER_LLVM_BIN"
            )
        if llvm_bin is not None:
            clang = Path(llvm_bin) / "clang"
            if not clang.is_file():
                raise QualificationError(f"sanitizer clang was not found: {clang}")
            environment["PATH"] = llvm_bin + os.pathsep + environment.get("PATH", "")
            print(f"macOS ASan linker toolchain: {clang}", flush=True)

    if os.name == "nt":
        environment.setdefault(
            "ASAN_OPTIONS",
            "halt_on_error=1:abort_on_error=1:detect_leaks=0",
        )
    else:
        environment.setdefault(
            "ASAN_OPTIONS",
            "halt_on_error=1:abort_on_error=1:detect_leaks=1",
        )
    print(f"ASAN_OPTIONS={environment['ASAN_OPTIONS']}", flush=True)
    return environment


def run_self_test() -> None:
    calls: list[list[str]] = []

    def fail_first(
        command: Sequence[str],
        *,
        cwd: Path,
        env: dict[str, str] | None,
        check: bool,
    ) -> subprocess.CompletedProcess[str]:
        del cwd, env, check
        calls.append(list(command))
        raise subprocess.CalledProcessError(23, command)

    try:
        run_commands(
            (("qualification-first",), ("must-not-run",)),
            runner=fail_first,
        )
    except QualificationError:
        pass
    else:
        raise QualificationError("fail-fast self-test did not propagate the simulated failure")
    if calls != [["qualification-first"]]:
        raise QualificationError(
            f"fail-fast self-test ran commands after failure: {calls}"
        )

    expected_cross_commands = len(CROSS_TARGETS) * 2 * 2
    actual_cross_commands = len(cross_check_commands("odin", CROSS_TARGETS))
    if actual_cross_commands != expected_cross_commands:
        raise QualificationError(
            f"cross-check matrix is incomplete: expected {expected_cross_commands}, "
            f"found {actual_cross_commands}"
        )
    print(
        "Fail-fast self-test passed: a simulated first-step failure prevented "
        f"later execution; cross-check matrix contains {actual_cross_commands} commands.",
        flush=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--odin", default="odin", help="Odin compiler executable")
    subparsers = parser.add_subparsers(dest="command", required=True)

    native = subparsers.add_parser("native", help="run the complete native suite and examples")
    native.add_argument("--sqlite-library", type=Path)
    native.add_argument(
        "--feature-profile",
        choices=("default", "all"),
        default="default",
    )

    cross = subparsers.add_parser(
        "cross-check",
        help="type-check raw and wrapper packages for non-native targets; never executes them",
    )
    cross.add_argument("--target", action="append", dest="targets")

    sanitize = subparsers.add_parser(
        "sanitize",
        help="run the complete native suite and examples with address sanitizer",
    )
    sanitize.add_argument("--sqlite-library", type=Path)
    sanitize.add_argument(
        "--feature-profile",
        choices=("default", "all"),
        default="default",
    )

    subparsers.add_parser("self-test", help="negative test for fail-fast orchestration")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "self-test":
            run_self_test()
            return 0

        require_generated_bindings()
        if args.command == "cross-check":
            targets = tuple(args.targets) if args.targets else CROSS_TARGETS
            run_commands(cross_check_commands(args.odin, targets))
            print(
                "Compile-only cross-target qualification passed. No target binary "
                "was linked or executed.",
                flush=True,
            )
            return 0

        if args.command == "native":
            with tempfile.TemporaryDirectory(prefix="odin-sqlite-native-") as temp_name:
                run_commands(
                    native_commands(
                        args.odin,
                        args.sqlite_library,
                        args.feature_profile,
                        Path(temp_name),
                    )
                )
            print(
                f"Native runtime qualification passed on {platform.system()} "
                f"{platform.machine()} (profile={args.feature_profile}).",
                flush=True,
            )
            return 0

        if args.command == "sanitize":
            environment = sanitizer_environment(args.odin)
            with tempfile.TemporaryDirectory(prefix="odin-sqlite-asan-") as temp_name:
                run_commands(
                    native_commands(
                        args.odin,
                        args.sqlite_library,
                        args.feature_profile,
                        Path(temp_name),
                        sanitizer="address",
                    ),
                    environment=environment,
                )
            print(
                f"Native ASan qualification passed on {platform.system()} "
                f"{platform.machine()} (profile={args.feature_profile}).",
                flush=True,
            )
            return 0
    except QualificationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"error: unhandled command: {args.command}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
