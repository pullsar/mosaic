from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path


def load_patch_module(path: Path):
    spec = importlib.util.spec_from_file_location("renderer_prefetch_patch_v2", path)
    if spec is None or spec.loader is None:
        raise SystemExit("Unable to load the renderer prefetch patch")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def finalize(root: Path, orchestration_root: Path) -> None:
    source_path = root / "packages/play_flutter/lib/src/play_visual_renderer.dart"
    text = source_path.read_text(encoding="utf-8")

    # Remove any interrupted predecessor version before applying the final,
    # globally bounded implementation. The following typedef is the stable
    # boundary shared by every renderer tranche.
    if "typedef PlayVisualWarmCallback" in text:
        pattern = re.compile(
            r"typedef PlayVisualWarmCallback =.*?(?=typedef PlayVisualStateBuilder =)",
            re.DOTALL,
        )
        text, count = pattern.subn("", text, count=1)
        if count != 1:
            raise SystemExit("Unable to replace the existing prefetch implementation")
        source_path.write_text(text, encoding="utf-8")

    module = load_patch_module(
        orchestration_root / "renderer_prefetch_patch_v2.py"
    )
    module.patch(root)

    text = source_path.read_text(encoding="utf-8")
    old = """          if (!isCurrent()) return;
          warmed += 1;"""
    new = """          if (!isCurrent()) return;
          if (!context.mounted) {
            cancel();
            return;
          }
          warmed += 1;"""
    if new not in text:
        if text.count(old) != 1:
            raise SystemExit("Unable to add the post-decode mounted check")
        text = text.replace(old, new, 1)
    source_path.write_text(text, encoding="utf-8")

    required = (
        "int? cacheWidth",
        "ImageProvider<Object> createImageProvider()",
        "final class PlayVisualPrefetchController",
        "final Queue<Completer<void>> _permitWaiters",
        "int get activeOperations",
        "_acquireOperationPermit",
        "if (!context.mounted)",
        "this.repaintBoundaryKey",
    )
    final_text = source_path.read_text(encoding="utf-8")
    for marker in required:
        if marker not in final_text:
            raise SystemExit(f"Missing finalized renderer marker: {marker}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: renderer_prefetch_finalize.py <repository-root> "
            "<orchestration-root>"
        )
    finalize(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
