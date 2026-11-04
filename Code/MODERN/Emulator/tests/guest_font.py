"""The console font a guest draws its GRAPHIC6 text with, read from its flash image.

The screen observer (harness.lua `harness.vdp.console`) matches each 6x8 cell
against these glyphs, so text is decoded with the font the guest actually
ships, never a copy kept here.  Both consoles use a CP850 6x8 font whose row
byte holds the six pixels in bits 7..2 (left pixel in bit 7).

- KonaOS: the V9958 driver's mapped segment.  The ROMFS (KonaOS
  tools/romfspack.py: "KRFS" header at flash page 2, 36-byte entries,
  logical offsets across the 0000h-BFFFh window of pages 2-7) holds
  `v9958.mod`; its KMOD container (tools/modpack.py: 16-byte header, 12-byte
  segment table, payload at the header's offset) has one `mapped` segment
  (role 5): `_v9958_font_pages`, eight 256-byte pages, page s holding row s
  of every character (drivers/v9958/v9958_font.asm).
- ZSDOS: CONSOLE_FONT_ROM_BASE (8000h, "font, bank 7",
  Code/HOST/CPM2.2/src/layout/memory.inc), i.e. flash 78000h: 256 glyphs of
  8 bytes, glyph-sequential (drivers/console/v9958.asm's atlas upload reads
  8000h + glyph * 8 + scanline).

`write(guest, image, path)` stores the font glyph-major (256 x 8 bytes) for
the harness and returns its provenance."""
import hashlib
import struct

ROMFS_PAGE = 2
ROMFS_WINDOW = 0xC000
PAGE = 0x10000
KMOD_ROLE_MAPPED = 5
FONT_BYTES = 2048
ZSDOS_FONT_FLASH = 7 * PAGE + 0x8000


class FontError(Exception):
    pass


def _romfs_read(image, logical, length):
    out = bytearray()
    while length:
        page, offset = ROMFS_PAGE + logical // ROMFS_WINDOW, logical % ROMFS_WINDOW
        take = min(length, ROMFS_WINDOW - offset)
        start = page * PAGE + offset
        out += image[start:start + take]
        logical += take
        length -= take
    return bytes(out)


def konaos_font(image):
    header = _romfs_read(image, 0, 16)
    if header[:4] != b"KRFS":
        raise FontError("no ROMFS header (KRFS) at flash page 2")
    entry_size, count = header[5], struct.unpack_from("<H", header, 6)[0]
    directory = _romfs_read(image, 16, entry_size * count)
    for i in range(count):
        entry = directory[i * entry_size:(i + 1) * entry_size]
        name = entry[:24].split(b"\0", 1)[0].decode()
        if name != "v9958.mod":
            continue
        offset, size = struct.unpack_from("<II", entry, 24)
        mod = _romfs_read(image, offset, size)
        if mod[:4] != b"KMOD":
            raise FontError("v9958.mod is not a KMOD container")
        segments, payload = mod[4], struct.unpack_from("<H", mod, 0x0A)[0]
        for s in range(segments):
            role, _, base, img_size, _, _, seg_off = struct.unpack_from("<BBHHHHH", mod, 16 + 12 * s)
            if role == KMOD_ROLE_MAPPED:
                if img_size != FONT_BYTES:
                    raise FontError(f"mapped segment holds {img_size} bytes, not the {FONT_BYTES}-byte font")
                pages = mod[payload + seg_off:payload + seg_off + FONT_BYTES]
                glyphs = bytes(pages[row * 256 + code] for code in range(256) for row in range(8))
                return glyphs, {"source": "ROMFS v9958.mod, KMOD mapped segment (_v9958_font_pages, paged)",
                                "romfs_offset": offset, "mod_bytes": size, "segment_payload_offset": seg_off,
                                "segment_base": base}
        raise FontError("v9958.mod has no mapped segment")
    raise FontError("ROMFS holds no v9958.mod")


def zsdos_font(image):
    glyphs = bytes(image[ZSDOS_FONT_FLASH:ZSDOS_FONT_FLASH + FONT_BYTES])
    return glyphs, {"source": "CONSOLE_FONT_ROM_BASE 8000h in bank 7 (glyph-sequential)",
                    "flash_offset": ZSDOS_FONT_FLASH}


def write(guest, image_path, path):
    image = image_path.read_bytes()
    glyphs, info = (konaos_font if guest == "konaos" else zsdos_font)(image)
    # A console font has a blank space and an inked 'A'; anything else is not a font.
    if glyphs[0x20 * 8:0x21 * 8] != bytes(8) or not any(glyphs[0x41 * 8:0x42 * 8]):
        raise FontError(f"{guest}: the bytes at {info} are not a console font (space or 'A' wrong)")
    path.write_bytes(glyphs)
    info.update(guest=guest, image=str(image_path), path=str(path), bytes=len(glyphs),
                sha256=hashlib.sha256(glyphs).hexdigest())
    return info
