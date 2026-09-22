#!/usr/bin/env python3
"""Check that every FS2 v1 command is admitted and dispatched consistently."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
header = (root / "include/ioc_frame.h").read_text()
dispatch = (root / "src/dispatch.c").read_text()
sync = (root / "src/external_sync.c").read_text()
fs2 = (root / "src/fs2.c").read_text()
share = (root / "src/fs_share.c").read_text()

commands = re.findall(r"#define (CMD_FS2_[A-Z0-9_]+)\s+0x[0-9A-Fa-f]+", header)
assert commands == ["CMD_FS2_CAPS", "CMD_FS2_GENERATION", "CMD_FS2_RESET",
                    "CMD_FS2_ROOT", "CMD_FS2_PUSH", "CMD_FS2_OPEN_RO",
                    "CMD_FS2_READ", "CMD_FS2_CLOSE", "CMD_FS2_OPENDIR",
                    "CMD_FS2_READDIR", "CMD_FS2_CLOSEDIR", "CMD_FS2_STAT",
                    "CMD_FS2_SPACE", "CMD_FS2_OPEN_RW", "CMD_FS2_WRITE",
                    "CMD_FS2_SYNC", "CMD_FS2_TRUNCATE"]
for command in commands:
    assert f"case {command}:" in dispatch, f"{command} is not dispatched"
assert "value >= CMD_FS2_CAPS && value <= CMD_FS2_TRUNCATE" in sync
assert "static uint8_t chunk[IOC_FS2_CHUNK_MAX]" not in fs2
assert "#define chunk fs_bulk_chunk" in fs2
assert "reply->bytes[IOC_OFF_FS2_OPEN_ATTR] = 0u;" in fs2
assert "reply->bytes[IOC_OFF_FS2_DIRENT_ATTR] = info.fattrib & AM_DIR;" in fs2
assert "reply->bytes[IOC_OFF_FS2_STAT_ATTR] = info.fattrib & AM_DIR;" in fs2
assert "uint8_t fs_bulk_chunk[IOC_FS_CHUNK_MAX]" in share
assert "IOC_FS2_FILE_SLOTS               2u" in header
assert "IOC_FS2_DIR_SLOTS                1u" in header
assert "IOC_FS2_STATUS_STALE" not in header  # status spelling is FS2_STALE
assert "IOC_STATUS_FS2_STALE" in header
print("PASS: FS2 v1 commands admitted/dispatched, 2 FIL + 1 DIR, shared bulk staging")
