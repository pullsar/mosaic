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


def audit(root: Path) -> None:
    for relative in TEMPORARY_PATHS:
        path = root / relative
        if path.exists():
            path.unlink()

    package_root = root / "packages/local_state"
    pubspec = (package_root / "pubspec.yaml").read_text(encoding="utf-8")
    if not re.search(r"(?m)^\s{2}sqlite3:\s*\^?3\.5\.2\s*$", pubspec):
        raise SystemExit("local_state must pin the deliberately small sqlite3 3.5.2 layer")
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

    required_source_concepts = (
        "PRAGMA",
        "event",
        "outbox",
        "draft",
        "upload",
        "interest",
        "actor",
    )
    lowered_source = combined_source.lower()
    for concept in required_source_concepts:
        if concept.lower() not in lowered_source:
            raise SystemExit(f"Missing durable-store concept in source: {concept}")

    required_test_concepts = (
        "reopen",
        "dedup",
        "backoff",
        "corrupt",
        "pressure",
    )
    lowered_tests = combined_tests.lower()
    for concept in required_test_concepts:
        if concept not in lowered_tests:
            raise SystemExit(f"Missing restart/recovery test concept: {concept}")

    # SQL values must remain bound. Catch interpolation close to a SQL verb while
    # allowing interpolation in diagnostics and non-SQL strings.
    for path in sources:
        text = path.read_text(encoding="utf-8")
        upper = text.upper()
        for verb in SQL_VERBS:
            start = 0
            while True:
                index = upper.find(verb, start)
                if index < 0:
                    break
                window = text[index : index + 500]
                if "${" in window:
                    line = text.count("\n", 0, index) + 1
                    raise SystemExit(
                        f"Possible interpolated SQL in {path.relative_to(root)}:{line}"
                    )
                start = index + len(verb)

    docs = root / "docs/local-persistence-and-recovery.md"
    if not docs.exists() or docs.stat().st_size < 500:
        raise SystemExit("The local persistence/recovery contract is missing or too small")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: audit_local_recovery.py <repository-root>")
    audit(Path(sys.argv[1]).resolve())
