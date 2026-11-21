#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Extract pinned 610.43.03 GA10x firmware and generate GA102/AD102 V67 images."""

from __future__ import annotations

import argparse
import contextlib
import json
import hashlib
import re
import subprocess
import tarfile
import sys
from pathlib import Path


PACKAGE_SHA256 = "c3367ff68632ac7daf6ca50ef7cbdd1cb5d09f7fe0b26125b312c73e52a34cf4"
GSP_SHA256 = "572373620a37418f24dc16b5031c39338778c3257e48e8408de9a57291b24f3a"
PAYLOAD_SHA256 = "2a0aa1f86d0b6afff5214d641d87d46dc98ef06ed908ff05d0ddbad5ffb7e197"
AD102_PAYLOAD_SHA256 = "44c36b2d6b3424e53e18f3e55db85c833655de071ce66ce42749588a4a7dc8cb"
AD102_PAYLOAD_NAME = "v67-ad102-610.43.03-four-plm.bin"
PACKAGE_VERSION = "610.43.03-1"
FIRMWARE_PREFIX = "usr/lib/firmware/nvidia/610.43.03/"
MANIFEST = Path(__file__).with_name("artifacts-610.43.03.json")

PAYLOAD_SIZE = 0xFA00
FILL_DWORD = 0x0000019C
PATCHED_WORDS = {
    0x1100: 0x00000007,
    0xF948: 0xFFFFFFFF,
    0xF950: 0x00000D44,
    0xF960: 0x00823804,
    0xF968: 0x00001FCE,
    0xF974: 0x00000000,
    0xF97C: 0x00001101,
    0xF980: 0x000084C8,
    0xF984: 0x00008E18,
    0xF98C: 0x000084C8,
    0xF990: 0x00000000,
    0xF998: 0x00001FCE,
    0xF9A4: 0x0000FFBC,
    0xF9AC: 0x00005789,
    0xF9BC: 0x00000D44,
    0xF9CC: 0x00000003,
    0xF9D4: 0x00001FCE,
    0xF9E8: 0x00000D52,
    0xF9EC: 0x000081EE,
}

# Adapted from TOTORONG/AD103_win_unlocker, source/firmware-tools/ad102_payload.py,
# revision 51df9c17ec89eb8486df52cc9079dde4bd1f9974 (GPL-2.0-only).
# Modified 2026-10-23: keep only the deterministic payload construction here;
# the upstream interpreter and firmware disassembly are not needed to build it.
# This reproduces an experimental debug-derived chain, not proof of execution
# by the production booter. See NOTICE.md and the manifest for provenance.
AD102_PATCHED_WORDS = {
    0x1100: 0x00000007,
    0xF948: 0xFFFFF0FF,
    0xF950: 0x000021B2,
    0xF960: 0x001FA7CC,
    0xF968: 0x000033FC,
    0xF974: 0xFFFFFFFF,
    0xF97C: 0x0000256F,
    0xF980: 0x00007A02,
    0xF984: 0x009A0148,
    0xF98C: 0x000033FC,
    0xF998: 0xFFFFFFFF,
    0xF9A0: 0x0000256F,
    0xF9A4: 0x00007A02,
    0xF9A8: 0x001FA7C4,
    0xF9B0: 0x000033FC,
    0xF9BC: 0xFFFFFFFF,
    0xF9C4: 0x0000256F,
    0xF9C8: 0x00007A02,
    0xF9CC: 0x00823804,
    0xF9D4: 0x000033FC,
    0xF9E0: 0x67B00001,
    0xF9E8: 0x0000256F,
    0xF9EC: 0x00007A02,
    0xF9F8: 0x000031B5,
    0xF9FC: 0x0000771E,
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extract_member(package: Path, name: str) -> bytes:
    if package.name.endswith(".zst"):
        if sys.version_info >= (3, 14):
            # Python 3.14 provides zstd on Windows as well as Linux.
            with tarfile.open(package, mode="r:zst") as archive:
                return read_member(archive, name)
        process = subprocess.Popen(["zstd", "-dc", str(package)], stdout=subprocess.PIPE)
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
                result = read_member(archive, name)
            if process.wait() != 0:
                raise ValueError("zstd could not read the pinned package")
            return result
        finally:
            if process.stdout:
                process.stdout.close()
            if process.poll() is None:
                process.kill()
                process.wait()
    with tarfile.open(package, mode="r:*") as archive:
        return read_member(archive, name)


def read_member(archive: tarfile.TarFile, name: str) -> bytes:
    result = None
    for member in archive:
        if member.name != name:
            continue
        if result is not None:
            raise ValueError(f"duplicate package member: {name}")
        if not member.isfile() or member.size > 128 * 1024 * 1024:
            raise ValueError(f"not a regular file in package: {name}")
        stream = archive.extractfile(member)
        if stream is None:
            raise ValueError(f"could not read package member: {name}")
        result = stream.read()
    if result is None:
        raise ValueError(f"missing package member: {name}")
    return result


def read_members(archive: tarfile.TarFile, names: list[str]) -> dict[str, bytes]:
    """Like read_member, for several members in one pass over a streamed archive."""
    found: dict[str, bytes] = {}
    for member in archive:
        if member.name not in names:
            continue
        if member.name in found:
            raise ValueError(f"duplicate package member: {member.name}")
        if not member.isfile() or member.size > 128 * 1024 * 1024:
            raise ValueError(f"not a regular file in package: {member.name}")
        stream = archive.extractfile(member)
        if stream is None:
            raise ValueError(f"could not read package member: {member.name}")
        found[member.name] = stream.read()
    missing = [name for name in names if name not in found]
    if missing:
        raise ValueError(f"missing package member: {', '.join(missing)}")
    return found


def run_payload_offset(run: Path) -> int:
    """Byte offset of the payload in a makeself .run: its own `skip=N` line says the
    payload starts at line N. The .run's shell code is read as text, never executed."""
    with run.open("rb") as stream:
        head = stream.read(64 * 1024)
    if re.match(rb"#! ?/bin/sh\n", head) is None:  # NVIDIA writes "#! /bin/sh"
        raise ValueError("not a makeself .run file")
    match = re.search(rb"^skip=(\d+)$", head, re.MULTILINE)
    if match is None or not 1 <= int(match.group(1)) <= 100000:
        raise ValueError("no usable skip= line in the .run header")
    lines, offset = int(match.group(1)) - 1, 0
    with run.open("rb") as stream:
        while lines:
            block = stream.read(1024 * 1024)
            if not block:
                raise ValueError("truncated .run header")
            count = block.count(b"\n")
            if count < lines:
                lines -= count
                offset += len(block)
                continue
            position = -1
            for _ in range(lines):
                position = block.index(b"\n", position + 1)
            return offset + position + 1
    return offset


@contextlib.contextmanager
def open_zstd_at(path: Path, offset: int):
    """A readable, decompressed view of the zstd data that starts at `offset` in `path`."""
    with path.open("rb") as raw:
        raw.seek(offset)
        if raw.read(4) != b"\x28\xb5\x2f\xfd":
            raise ValueError("the .run payload is not zstd data")
        raw.seek(offset)
        try:
            from compression import zstd  # Python 3.14 and later, as embedded by the installer
        except ImportError:
            zstd = None
        if zstd is not None:
            with zstd.ZstdFile(raw) as stream:
                yield stream
            return
        try:
            import zstandard
        except ImportError:
            zstandard = None
        if zstandard is not None:
            with zstandard.ZstdDecompressor().stream_reader(raw, read_across_frames=True) as stream:
                yield stream
            return
        process = subprocess.Popen(["zstd", "-dc"], stdin=raw, stdout=subprocess.PIPE)
        try:
            yield process.stdout
            while process.stdout.read(1024 * 1024):  # drain the rest so zstd can exit
                pass
            if process.wait() != 0:
                raise ValueError("zstd could not read the .run payload")
        finally:
            if process.stdout:
                process.stdout.close()
            if process.poll() is None:
                process.kill()
                process.wait()


def extract_run_members(run: Path, names: list[str]) -> dict[str, bytes]:
    with open_zstd_at(run, run_payload_offset(run)) as stream:
        with tarfile.open(fileobj=stream, mode="r|") as archive:
            return read_members(archive, names)


def build_payload() -> bytes:
    """Build the original GA102 rejoin15 payload (public API retained)."""
    return _build_payload(PATCHED_WORDS)


def build_ad102_payload() -> bytes:
    """Build the pinned AD102 four-write chain and explicit mailbox marker."""
    return _build_payload(AD102_PATCHED_WORDS)


def _build_payload(patched_words: dict[int, int]) -> bytes:
    word = FILL_DWORD.to_bytes(4, "little")
    payload = bytearray(word * (PAYLOAD_SIZE // len(word)))
    for offset, value in patched_words.items():
        payload[offset : offset + 4] = value.to_bytes(4, "little")
    return bytes(payload)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path,
                        help="pinned nvidia-utils-610.43.03 package, or its pinned alternative NVIDIA-Linux-x86_64-610.43.03.run")
    parser.add_argument("output", type=Path, help="directory for extracted firmware and payload")
    args = parser.parse_args()

    package_bytes_hash = hashlib.sha256()
    with args.package.open("rb") as package_file:
        for block in iter(lambda: package_file.read(1024 * 1024), b""):
            package_bytes_hash.update(block)
    manifest = json.loads(MANIFEST.read_text())
    nvidia_utils = manifest["source_artifacts"][2]
    alternative = nvidia_utils.get("alternative")

    if package_bytes_hash.hexdigest() == PACKAGE_SHA256:
        pkginfo = extract_member(args.package, ".PKGINFO").decode("utf-8", errors="replace")
        if f"pkgver = {PACKAGE_VERSION}" not in pkginfo.splitlines():
            raise SystemExit("package metadata version does not match 610.43.03-1")
        gsp = extract_member(args.package, FIRMWARE_PREFIX + "gsp_ga10x.bin")
        notice = nvidia_utils["notice"]
        license_text = extract_member(args.package, notice["path"])
    elif alternative is not None and package_bytes_hash.hexdigest() == alternative["sha256"]:
        # NVIDIA's own installer holds the same firmware and license files (checked below).
        with args.package.open("rb") as run_file:
            header = run_file.read(64 * 1024)
        label = f'label="NVIDIA Accelerated Graphics Driver for Linux-x86_64 {alternative["version"]}"'
        if label.encode() not in header.splitlines():
            raise SystemExit("the .run header does not name driver " + alternative["version"])
        notice = alternative["notice"]
        gsp_path = alternative["firmware"][0]["path"]
        members = extract_run_members(args.package, [gsp_path, notice["path"]])
        gsp, license_text = members[gsp_path], members[notice["path"]]
    else:
        raise SystemExit("package SHA-256 matches neither the pinned nvidia-utils artifact nor its pinned alternative")

    if sha256(gsp) != GSP_SHA256:
        raise SystemExit("GA10x GSP firmware SHA-256 does not match the pinned artifact")

    payload = build_payload()
    if sha256(payload) != PAYLOAD_SHA256:
        raise SystemExit("generated GA102 V67 image differs from its pinned SHA-256")
    ad102_payload = build_ad102_payload()
    if sha256(ad102_payload) != AD102_PAYLOAD_SHA256:
        raise SystemExit("generated AD102 V67 image differs from its pinned SHA-256")
    if sha256(license_text) != notice["sha256"]:
        raise SystemExit("NVIDIA license notice differs from pinned package")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "gsp_ga10x.bin").write_bytes(gsp)
    (args.output / "v67-ga102-610.43.03.bin").write_bytes(payload)
    (args.output / AD102_PAYLOAD_NAME).write_bytes(ad102_payload)
    (args.output / "NVIDIA-LICENSE").write_bytes(license_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
