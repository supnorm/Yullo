#!/usr/bin/env python3
"""Check that compiled Metal libraries hold every kernel a pinned ggml backend can ask for.

Usage: check-metallib-kernels.py GGML_METAL_SOURCE_DIR LIBRARY.metallib [LIBRARY.metallib ...]

ggml builds kernel names at run time from string literals and printf formats in its Metal
backend sources ("kernel_mul_mm_%s_%s", "kernel_flash_attn_ext_tensor_%s_dk%d_dv%d", ...).
A name no library holds becomes a NULL pipeline on the GPUs that take that path, so each
name family must match at least one compiled function. Families of the tensor API must be
in ggml-tensor.metallib, the only library ggml routes them to. This runs on any Mac: it
needs no GPU of the kind that takes the path.
"""

from pathlib import Path
import re
import subprocess
import sys

SPECIFIER = re.compile(r"%[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|z)?[diusx]")


def functions(library: Path) -> set[str]:
    listing = subprocess.run(
        ["xcrun", "-sdk", "macosx", "metal-nm", str(library)], check=True, capture_output=True, text=True
    ).stdout
    return {line.split()[-1] for line in listing.splitlines() if " T " in line}


def families(source: Path) -> set[str]:
    names = set()
    for path in sorted(source.glob("*.cpp")) + sorted(source.glob("*.m")):
        names.update(re.findall(r'"(kernel_[A-Za-z0-9_%.]*)"', path.read_text()))
    return names


def pattern(family: str) -> re.Pattern:
    parts = SPECIFIER.split(family)
    return re.compile("".join(re.escape(part) + ("[A-Za-z0-9_.-]+" if index < len(parts) - 1 else "")
                              for index, part in enumerate(parts)))


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    libraries = {Path(path).name: functions(Path(path)) for path in sys.argv[2:]}
    available = set().union(*libraries.values())
    wanted = families(source)
    if len(wanted) < 10:
        print(f"Found only {len(wanted)} kernel names in {source}.", file=sys.stderr)
        return 1
    missing = sorted(family for family in wanted if not any(pattern(family).match(name) for name in available))
    tensor = libraries.get("ggml-tensor.metallib")
    misplaced = sorted(
        family for family in wanted
        if "_tensor" in family and tensor is not None and not any(pattern(family).match(name) for name in tensor))
    for family in missing:
        print(f"No compiled Metal kernel for {family}", file=sys.stderr)
    for family in misplaced:
        print(f"ggml-tensor.metallib lacks {family}", file=sys.stderr)
    return 1 if missing or misplaced else 0


if __name__ == "__main__":
    sys.exit(main())
