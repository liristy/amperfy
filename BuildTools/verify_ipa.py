#!/usr/bin/env python3
"""Read-only arm64 IPA integrity check, usable before and after Windows signing.

Checks Mach-O ranges and embedded code page hashes, not certificate trust,
provisioning eligibility or device compatibility. Never modifies a signed file.
"""

import argparse
import hashlib
import struct
import zipfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_macho(data, require_signature=False):
    require(len(data) >= 32 and data[:4] == b"\xcf\xfa\xed\xfe", "Expected 64-bit little-endian Mach-O")
    count, command_bytes = struct.unpack_from("<II", data, 16)
    command_end = 32 + command_bytes
    require(command_end <= len(data), "Truncated load commands")
    offset = 32
    signatures = []
    for _ in range(count):
        require(offset + 8 <= command_end, "Truncated load command")
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= command_end, "Invalid load command size")
        if command == 0x19:  # LC_SEGMENT_64
            require(size >= 72, "Truncated segment command")
            name = data[offset + 8:offset + 24].rstrip(b"\0").decode("ascii")
            start, length = struct.unpack_from("<QQ", data, offset + 40)
            require(start + length <= len(data),
                    f"{name} ends at 0x{start + length:x}, file ends at 0x{len(data):x} "
                    f"(missing {start + length - len(data)} bytes)")
        elif command == 0x1D:  # LC_CODE_SIGNATURE
            require(size >= 16, "Truncated signature command")
            signatures.append(struct.unpack_from("<II", data, offset + 8))
        offset += size
    require(offset == command_end, "Load command size mismatch")
    require(len(signatures) <= 1, "Duplicate code signature commands")
    require(not require_signature or signatures, "Missing embedded code signature")
    for start, length in signatures:
        require(length >= 12 and start + length <= len(data), "Signature allocation extends beyond file")
        magic, blob_length, count = struct.unpack_from(">III", data, start)
        require(magic == 0xFADE0CC0, "Invalid embedded signature magic")
        require(12 + 8 * count <= blob_length <= length, "Invalid signature superblob length")
        directories = 0
        for index in range(count):
            slot, child = struct.unpack_from(">II", data, start + 12 + 8 * index)
            require(12 + 8 * count <= child and child + 8 <= blob_length, "Invalid signature blob offset")
            child_magic, child_length = struct.unpack_from(">II", data, start + child)
            require(8 <= child_length and child + child_length <= blob_length, "Truncated signature blob")
            if child_magic != 0xFADE0C02:
                continue
            directories += 1
            cd = data[start + child:start + child + child_length]
            require(len(cd) >= 44, "Truncated CodeDirectory")
            version, flags, hash_offset, identifier, special, pages, limit = struct.unpack_from(">7I", cd, 8)
            hash_size, hash_type, platform, page_power = struct.unpack_from("4B", cd, 36)
            require(page_power <= 30, "Invalid code page size")
            if version >= 0x20300 and limit == 0xFFFFFFFF:
                require(len(cd) >= 64, "Truncated 64-bit code limit")
                limit = struct.unpack_from(">Q", cd, 56)[0]
            require(limit <= start, "Code hash range overlaps signature")
            page_size = (1 << page_power) if page_power else max(limit, 1)
            require(pages == (limit + page_size - 1) // page_size, "Code page count mismatch")
            algorithms = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384"}
            require(hash_type in algorithms, "Unsupported code hash type")
            require(hash_size == {1: 20, 2: 32, 3: 20, 4: 48}[hash_type], "Invalid code hash size")
            require(hash_offset >= special * hash_size and hash_offset + pages * hash_size <= len(cd),
                    "Truncated code hash table")
            for page in range(pages):
                content = data[page * page_size:min((page + 1) * page_size, limit)]
                actual = hashlib.new(algorithms[hash_type], content).digest()[:hash_size]
                expected = cd[hash_offset + page * hash_size:hash_offset + (page + 1) * hash_size]
                require(actual == expected, f"Code signature page {page} hash mismatch (slot {slot})")
        require(directories > 0, "Signature has no CodeDirectory")


def verify_ipa(path, require_signature=False):
    checked = 0
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, "IPA ZIP checksum failed")
        for entry in archive.infolist():
            if entry.is_dir() or not entry.filename.startswith("Payload/"):
                continue
            with archive.open(entry) as handle:
                magic = handle.read(4)
                if magic != b"\xcf\xfa\xed\xfe":
                    continue
                data = magic + handle.read()
            try:
                verify_macho(data, require_signature)
            except ValueError as error:
                raise ValueError(f"{entry.filename}: {error}") from error
            checked += 1
            print(f"OK: {entry.filename}")
    require(checked > 0, "No Mach-O executables found")
    print(f"Verified {checked} Mach-O files. Certificate trust and device installation are not checked.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--require-signature", action="store_true")
    args = parser.parse_args()
    try:
        verify_ipa(args.ipa, args.require_signature)
    except (ValueError, OSError, zipfile.BadZipFile, struct.error) as error:
        parser.exit(1, f"FAILED: {error}\n")
