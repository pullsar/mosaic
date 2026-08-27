from __future__ import annotations

import re
import sys
from pathlib import Path


TEMPORARY_PATHS = (
    ".github/workflows/bootstrap-local-recovery-once.yml",
    ".github/workflows/lock-local-state-once.yml",
    ".github/workflows/release-local-recovery-once.yml",
    ".github/workflows/repair-local-recovery-release-once.yml",
    ".github/workflows/release-local-recovery-v2-once.yml",
    ".release-gates/local-recovery-ready",
    "packages/local_state/.local-recovery-release-gate",
)

BANNED_PACKAGES = (
    "build_runner:",
    "drift:",
    "floor:",
    "freezed:",
    "hive:",
    "isar:",
    "objectbox:",
    "sqflite:",
)

SQL_VERBS = ("SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP")
TRIPLE_QUOTED = re.compile(
    r"(?s)(?P<raw>r)?(?P<quote>'''|\"\"\")(?P<body>.*?)(?P=quote)"
)
SINGLE_QUOTED = re.compile(
    r"(?m)(?P<raw>r)?(?P<quote>'|\")(?P<body>(?:\\.|(?!\2).)*?)(?P=quote)"
)


def _assert_bound_sql(path: Path, text: str, root: Path) -> None:
    occupied: list[tuple[int, int]] = []
    for match in TRIPLE_QUOTED.finditer(text):
        occupied.append(match.span())
        if match.group("raw"):
            continue
        body = match.group("body")
        if "${" in body and any(verb in body.upper() for verb in SQL_VERBS):
            line = text.count("\n", 0, match.start()) + 1
            raise SystemExit(
                f"Interpolated SQL string in {path.relative_to(root)}:{line}"
            )

    def inside_triple(index: int) -> bool:
        return any(start <= index < end for start, end in occupied)

    for match in SINGLE_QUOTED.finditer(text):
        if inside_triple(match.start()) or match.group("raw"):
            continue
        body = match.group("body")
        if "${" in body and any(verb in body.upper() for verb in SQL_VERBS):
            line = text.count("\n", 0, match.start()) + 1
            raise SystemExit(
                f"Interpolated SQL string in {path.relative_to(root)}:{line}"
            )


def audit(root: Path) -> None:
    for relative in TEMPORARY_PATHS:
        path = root / relative
        if path.exists():
            path.unlink()

    package_root = root / "packages/local_state"
    pubspec = (package_root / "pubspec.yaml").read_text(encoding="utf-8")
    if not re.search(r"(?m)^\s{2}sqlite3:\s*\^?3\.5\.2\s*$", pubspec):
        raise SystemExit("local_state must use the deliberately small sqlite3 3.5.2 layer")
    for package in BANNED_PACKAGES:
        if re.search(rf"(?m)^\s+{re.escape(package)}", pubspec):
            raise SystemExit(f"Unexpected ORM/code-generation dependency: {package[:-1]}")

    lock = (root / "pubspec.lock").read_text(encoding="utf-8")
    sqlite_lock = re.search(
        r"(?ms)^  sqlite3:\n(?:    .*\n)*?    version: \"([^\"]+)\"$",
        lock,
    )
    if sqlite_lock is None or sqlite_lock.group(1) != "3.5.2":
        found = None if sqlite_lock is None else sqlite_lock.group(1)
        raise SystemExit(f"pubspec.lock must resolve sqlite3 3.5.2, found {found!r}")

    sources = sorted((package_root / "lib").rglob("*.dart"))
    tests = sorted((package_root / "test").rglob("*_test.dart"))
    if not sources:
        raise SystemExit("local_state has no Dart implementation")
    if not tests:
        raise SystemExit("local_state has no recovery tests")

    combined_source = "\n".join(path.read_text(encoding="utf-8") for path in sources)
    combined_tests = "\n".join(path.read_text(encoding="utf-8") for path in tests)
    lowered_source = combined_source.lower()
    lowered_tests = combined_tests.lower()

    for concept in ("pragma", "event", "outbox", "draft", "upload", "interest", "actor"):
        if concept not in lowered_source:
            raise SystemExit(f"Missing durable-store concept in source: {concept}")
    for concept in ("reopen", "dedup", "backoff", "corrupt", "pressure"):
        if concept not in lowered_tests:
            raise SystemExit(f"Missing restart/recovery test concept: {concept}")

    for path in sources:
        _assert_bound_sql(path, path.read_text(encoding="utf-8"), root)

    docs = root / "docs/local-persistence-and-recovery.md"
    if not docs.exists() or docs.stat().st_size < 500:
        raise SystemExit("The local persistence/recovery contract is missing or too small")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: audit_local_recovery_v2.py <repository-root>")
    audit(Path(sys.argv[1]).resolve())
