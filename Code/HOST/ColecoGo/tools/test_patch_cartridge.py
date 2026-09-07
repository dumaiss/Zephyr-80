#!/usr/bin/env python3
"""Tests for the guarded cartridge patcher."""

from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path

from patch_cartridge import PatchError, parse_patches, validate_rom_identity, verify_and_patch


class PatchCartridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.rom = bytes(range(32))
        self.manifest = {
            "format": "colecogo-patch-v1",
            "load_address": "0x8000",
            "rom": {
                "size": len(self.rom),
                "sha256": hashlib.sha256(self.rom).hexdigest(),
            },
            "patches": [
                {
                    "name": "test replacement",
                    "address": "0x8004",
                    "expect": "04 05 06",
                    "replace": "AA BB CC",
                }
            ],
        }

    def test_valid_patch(self) -> None:
        validate_rom_identity(self.manifest, self.rom)
        patches = parse_patches(self.manifest, len(self.rom))
        patched = verify_and_patch(self.rom, patches)
        self.assertEqual(patched[4:7], bytes.fromhex("AA BB CC"))
        self.assertEqual(len(patched), len(self.rom))
        self.assertEqual(self.rom[4:7], bytes.fromhex("04 05 06"))

    def test_wrong_original_bytes_are_rejected(self) -> None:
        self.manifest["patches"][0]["expect"] = "00 00 00"
        patches = parse_patches(self.manifest, len(self.rom))
        with self.assertRaisesRegex(PatchError, "expected"):
            verify_and_patch(self.rom, patches)

    def test_wrong_rom_hash_is_rejected(self) -> None:
        self.manifest["rom"]["sha256"] = "00" * 32
        with self.assertRaisesRegex(PatchError, "SHA-256 mismatch"):
            validate_rom_identity(self.manifest, self.rom)

    def test_overlapping_patches_are_rejected(self) -> None:
        self.manifest["patches"].append(
            {
                "name": "overlap",
                "offset": 5,
                "expect": "05 06",
                "replace": "10 11",
            }
        )
        with self.assertRaisesRegex(PatchError, "overlaps"):
            parse_patches(self.manifest, len(self.rom))

    def test_output_creation_is_exclusive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output.rom"
            with output.open("xb") as stream:
                stream.write(self.rom)
            with self.assertRaises(FileExistsError):
                output.open("xb")


if __name__ == "__main__":
    unittest.main()

