import hashlib
import struct
import unittest

from verify_ipa import verify_macho


def signed_fixture():
    # One code page, one CodeDirectory and a complete signature superblob.
    signature_offset = 120
    signature_size = 96
    header = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 6, 2, 88, 0, 0)
    segment = struct.pack("<II16s4Q4I", 0x19, 72, b"__LINKEDIT", 0, 4096,
                          0, signature_offset + signature_size, 1, 1, 0, 0)
    command = struct.pack("<4I", 0x1D, 16, signature_offset, signature_size)
    code = header + segment + command
    directory = struct.pack(">9I4BI", 0xFADE0C02, 76, 0x20001, 2, 44, 0, 0, 1,
                            len(code), 32, 2, 0, 12, 0) + hashlib.sha256(code).digest()
    signature = struct.pack(">5I", 0xFADE0CC0, signature_size, 1, 0, 20) + directory
    return code + signature


class IntegrityTests(unittest.TestCase):
    def test_valid_signature(self):
        verify_macho(signed_fixture(), require_signature=True)

    def test_one_byte_missing_reproduces_device_crash(self):
        with self.assertRaisesRegex(ValueError, "missing 1 bytes"):
            verify_macho(signed_fixture()[:-1], require_signature=True)

    def test_changed_signed_code_is_rejected(self):
        data = bytearray(signed_fixture())
        data[28] ^= 1
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            verify_macho(data)

    def test_truncated_signature_blob_is_rejected(self):
        data = bytearray(signed_fixture())
        struct.pack_into(">I", data, 124, 97)
        with self.assertRaisesRegex(ValueError, "superblob length"):
            verify_macho(data)

    def test_missing_code_signature(self):
        data = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 6, 0, 0, 0, 0)
        verify_macho(data)
        with self.assertRaisesRegex(ValueError, "Missing embedded"):
            verify_macho(data, require_signature=True)

    def test_truncated_load_commands(self):
        with self.assertRaisesRegex(ValueError, "Truncated load commands"):
            verify_macho(signed_fixture()[:40])

    def test_allocated_padding_is_valid(self):
        data = bytearray(signed_fixture())
        # Padding outside the superblob is legal if it exists in the file.
        struct.pack_into("<Q", data, 80, len(data) + 16)
        struct.pack_into("<I", data, 116, 112)
        data[184:216] = hashlib.sha256(data[:120]).digest()
        verify_macho(data + b"\0" * 16)


if __name__ == "__main__":
    unittest.main()
