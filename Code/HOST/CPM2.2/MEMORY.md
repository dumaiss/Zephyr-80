# Memory

- [IL/DL + font move feedback](memory/feedback_il_dl_font_approach.md) — bank-0 TPA for font; use MEM_MODE_ROM for ROM reads (COPY_LATCH0 is obsolete); ROM page 1 now backs drive A:
- [IL/DL project complete](memory/project_il_dl_complete.md) — CSI L/M working in Turbo Pascal; font at 0x8000; 395 bytes headroom remaining
- [DECAWM complete](memory/project_decawm_complete.md) — ESC [ ? 7 h/l implemented; driver slot now 100% full (0xF680)
- [Size optimization pass complete](memory/project_size_optimization.md) — 341 bytes reclaimed; VDRIP_CONSOLE_CODE_END now 0xF52B (was 0xF680)
