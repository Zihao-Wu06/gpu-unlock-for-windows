#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Generate hash-pinned AD102 assets locally; install no display drivers."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "firmware"))
import fetch_artifacts
import extract_boot_assets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="unlock build's GPU-UNLOCK/ASSETS directory")
    parser.add_argument("--cache", type=Path, default=ROOT / "build/windows/inputs")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    entries = fetch_artifacts.inputs(json.loads(fetch_artifacts.MANIFEST.read_text()))
    # The package may be the nvidia-utils archive or its pinned alternative, NVIDIA's .run installer.
    source, package = [fetch_artifacts.fetch_any(entry, args.cache, args.offline) for entry in entries]
    args.output.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / "firmware/generate_v67.py"),
                    str(package), str(args.output)], check=True)
    prefix = "NVIDIA-kernel-module-source-610.43.03/src/nvidia/generated/"
    # Extract only the two pinned source files needed by the existing generator.
    # Do not materialize archive paths, links, or execute NVIDIA's installer.
    with tempfile.TemporaryDirectory() as d, tarfile.open(source, "r:xz") as archive:
        generated = Path(d) / "src/nvidia/generated"
        generated.mkdir(parents=True)
        for name, digest in extract_boot_assets.ADA_PINNED.items():
            members = [m for m in archive.getmembers() if m.name == prefix + name]
            if len(members) != 1 or not members[0].isfile() or members[0].size > 32 * 1024 * 1024:
                raise ValueError("invalid or missing generated source: " + name)
            stream = archive.extractfile(members[0])
            if stream is None:
                raise ValueError("cannot read generated source: " + name)
            data = stream.read()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError("generated source SHA-256 mismatch: " + name)
            (generated / name).write_bytes(data)
        extract_boot_assets.extract_assets(Path(d), args.output, "ad102")
    (args.output / "v67-ga102-610.43.03.bin").unlink(missing_ok=True)
    print(f"Pinned AD102 assets generated in {args.output}; keep firmware and ROMs local.")


if __name__ == "__main__":
    main()
