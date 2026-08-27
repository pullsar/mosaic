from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path


TEMPORARY_PATHS = (
    ".github/workflows/bootstrap-flutter-hosts.yml",
    ".github/workflows/cleanup-platform-bootstrap.yml",
    ".github/workflows/release-platform-lifecycle-once.yml",
    ".github/workflows/repair-platform-release-once.yml",
    ".github/workflows/release-platform-lifecycle-v2-once.yml",
    "apps/mosaic_app/.platform-release-gate",
    "apps/mosaic_app/.platform-release-gate-v2",
)

CATALOG = {
    "sourceLanguage": "en",
    "strings": {
        "NSCameraUsageDescription": {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": "Create a Play with your camera.",
                    }
                },
                "fr": {
                    "stringUnit": {
                        "state": "translated",
                        "value": "Créez un Play avec votre appareil photo.",
                    }
                },
            }
        },
        "NSMicrophoneUsageDescription": {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": "Record audio for a Play.",
                    }
                },
                "fr": {
                    "stringUnit": {
                        "state": "translated",
                        "value": "Enregistrez de l’audio pour un Play.",
                    }
                },
            }
        },
        "NSPhotoLibraryUsageDescription": {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": "Choose media for a Play.",
                    }
                },
                "fr": {
                    "stringUnit": {
                        "state": "translated",
                        "value": "Choisissez un média pour un Play.",
                    }
                },
            }
        },
    },
    "version": "1.0",
}

BUILD_FILE = (
    "\t\tAA1000030000000000000003 /* InfoPlist.xcstrings in Resources */ = "
    "{isa = PBXBuildFile; fileRef = AA1000040000000000000004 /* "
    "InfoPlist.xcstrings */; };"
)
FILE_REFERENCE = (
    "\t\tAA1000040000000000000004 /* InfoPlist.xcstrings */ = "
    "{isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; "
    'path = InfoPlist.xcstrings; sourceTree = "<group>"; };'
)
GROUP_CHILD = "\t\t\t\tAA1000040000000000000004 /* InfoPlist.xcstrings */,"
RESOURCE_ENTRY = (
    "\t\t\t\tAA1000030000000000000003 /* "
    "InfoPlist.xcstrings in Resources */,"
)


def _insert_once(text: str, marker: str, addition: str, label: str) -> str:
    count = text.count(marker)
    if count != 1:
        raise SystemExit(f"Expected exactly one {label} marker, found {count}")
    return text.replace(marker, f"{marker}\n{addition}", 1)


def reconcile(root: Path) -> None:
    for relative in TEMPORARY_PATHS:
        path = root / relative
        if path.exists():
            path.unlink()

    catalog_path = root / "apps/mosaic_app/ios/Runner/InfoPlist.xcstrings"
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    catalog_path.write_text(
        json.dumps(CATALOG, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    project_path = root / "apps/mosaic_app/ios/Runner.xcodeproj/project.pbxproj"
    text = project_path.read_text(encoding="utf-8")
    text = "\n".join(
        line
        for line in text.splitlines()
        if "InfoPlist.xcstrings" not in line
        and line.strip() != "fr,"
    ) + "\n"

    text = _insert_once(
        text,
        "\t\tAA1000020000000000000002 /* PrivacyInfo.xcprivacy in Resources */ = "
        "{isa = PBXBuildFile; fileRef = AA1000010000000000000001 /* "
        "PrivacyInfo.xcprivacy */; };",
        BUILD_FILE,
        "privacy build-file",
    )
    text = _insert_once(
        text,
        "\t\tAA1000010000000000000001 /* PrivacyInfo.xcprivacy */ = "
        "{isa = PBXFileReference; lastKnownFileType = text.plist.xml; "
        'path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };',
        FILE_REFERENCE,
        "privacy file-reference",
    )
    text = _insert_once(
        text,
        "\t\t\t\tAA1000010000000000000001 /* PrivacyInfo.xcprivacy */,",
        GROUP_CHILD,
        "privacy group-child",
    )
    text = _insert_once(
        text,
        "\t\t\t\tAA1000020000000000000002 /* "
        "PrivacyInfo.xcprivacy in Resources */,",
        RESOURCE_ENTRY,
        "privacy resource",
    )
    text = _insert_once(
        text,
        "\t\t\t\ten,",
        "\t\t\t\tfr,",
        "English known-region",
    )
    project_path.write_text(text, encoding="utf-8")

    if text.count("InfoPlist.xcstrings in Resources") != 2:
        raise SystemExit("Localized Info.plist catalog is not linked exactly once")
    if text.count("AA1000040000000000000004 /* InfoPlist.xcstrings */") != 2:
        raise SystemExit("Localized Info.plist catalog file reference is malformed")

    info_path = root / "apps/mosaic_app/ios/Runner/Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    for key, value in CATALOG["strings"].items():
        info[key] = value["localizations"]["en"]["stringUnit"]["value"]
    with info_path.open("wb") as handle:
        plistlib.dump(info, handle, sort_keys=False)

    privacy_path = root / "apps/mosaic_app/ios/Runner/PrivacyInfo.xcprivacy"
    with privacy_path.open("rb") as handle:
        privacy = plistlib.load(handle)
    if privacy.get("NSPrivacyTracking") is not False:
        raise SystemExit("NSPrivacyTracking must be explicitly false")

    required_markers = {
        "packages/platform_contracts/lib/platform_contracts.dart": (
            "Future<void> _tail = Future<void>.value();",
            "Future<T> _serialize<T>",
            "Error.throwWithStackTrace",
        ),
        "packages/platform_flutter/lib/src/lifecycle.dart": (
            "typedef LifecycleErrorCallback",
            "Future<void> _tail = Future<void>.value();",
            "Future<void> handleState(AppRuntimeState state) => _serialize",
        ),
        "apps/mosaic_app/lib/main.dart": (
            "unawaited(_releaseMedia());",
            "FlutterError.reportError",
        ),
    }
    for relative, markers in required_markers.items():
        source = (root / relative).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in source:
                raise SystemExit(f"Missing platform hardening marker {marker!r} in {relative}")

    manifest = (
        root / "apps/mosaic_app/android/app/src/main/AndroidManifest.xml"
    ).read_text(encoding="utf-8")
    required_permissions = (
        "android.permission.CAMERA",
        "android.permission.RECORD_AUDIO",
        "android.permission.POST_NOTIFICATIONS",
    )
    forbidden_permissions = (
        "READ_MEDIA_IMAGES",
        "READ_MEDIA_VIDEO",
        "READ_EXTERNAL_STORAGE",
        "ACCESS_FINE_LOCATION",
        "ACCESS_COARSE_LOCATION",
    )
    for permission in required_permissions:
        if permission not in manifest:
            raise SystemExit(f"Missing Android permission {permission}")
    for permission in forbidden_permissions:
        if permission in manifest:
            raise SystemExit(f"Unexpected broad Android permission {permission}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: reconcile_platform.py <repository-root>")
    reconcile(Path(sys.argv[1]).resolve())
