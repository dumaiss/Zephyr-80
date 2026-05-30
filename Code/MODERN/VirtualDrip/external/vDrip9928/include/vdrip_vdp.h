/*
 * vDrip9928 VDP Emulator — single-include header
 *
 * Based on vrEmuTms9918 by Troy Schrapel (MIT license)
 * https://github.com/visrealm/vrEmuTms9918
 *
 * Extended with Text 2 mode (80 columns, 480×192).
 */

#ifndef _VDRIP_VDP_H_
#define _VDRIP_VDP_H_

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

/* ------------------------------------------------------------------
 * LINKAGE MACROS
 * ------------------------------------------------------------------ */

#if __EMSCRIPTEN__
#include <emscripten.h>
  #ifdef __cplusplus
  #define VR_EMU_TMS9918_DLLEXPORT EMSCRIPTEN_KEEPALIVE extern "C"
  #define VR_EMU_TMS9918_DLLEXPORT_CONST extern "C"
#else
  #define VR_EMU_TMS9918_DLLEXPORT EMSCRIPTEN_KEEPALIVE extern
  #define VR_EMU_TMS9918_DLLEXPORT_CONST extern
#endif
#elif VR_TMS9918_EMU_COMPILING_DLL
#define VR_EMU_TMS9918_DLLEXPORT __declspec(dllexport)
#elif defined WIN32 && !defined VR_EMU_TMS9918_STATIC
#define VR_EMU_TMS9918_DLLEXPORT __declspec(dllimport)
#else
#ifdef __cplusplus
#define VR_EMU_TMS9918_DLLEXPORT extern "C"
#else
#define VR_EMU_TMS9918_DLLEXPORT extern
#endif
#endif

#ifndef VR_EMU_TMS9918_DLLEXPORT_CONST
#define VR_EMU_TMS9918_DLLEXPORT_CONST VR_EMU_TMS9918_DLLEXPORT
#endif

/* ==================================================================
 * TYPES
 * ================================================================== */

struct vrEmuTMS9918_s;
typedef struct vrEmuTMS9918_s VrEmuTms9918;

typedef enum {
  TMS_MODE_GRAPHICS_I,
  TMS_MODE_GRAPHICS_II,
  TMS_MODE_TEXT,
  TMS_MODE_MULTICOLOR,
  TMS_MODE_TEXT_2,
} vrEmuTms9918Mode;

typedef enum {
  TMS_TRANSPARENT = 0,
  TMS_BLACK,     TMS_MED_GREEN,  TMS_LT_GREEN,
  TMS_DK_BLUE,   TMS_LT_BLUE,    TMS_DK_RED,  TMS_CYAN,
  TMS_MED_RED,   TMS_LT_RED,     TMS_DK_YELLOW, TMS_LT_YELLOW,
  TMS_DK_GREEN,  TMS_MAGENTA,    TMS_GREY,    TMS_WHITE,
} vrEmuTms9918Color;

typedef enum {
  TMS_REG_0 = 0, TMS_REG_1, TMS_REG_2, TMS_REG_3,
  TMS_REG_4, TMS_REG_5, TMS_REG_6, TMS_REG_7,
  TMS_NUM_REGISTERS,
  TMS_REG_NAME_TABLE        = TMS_REG_2,
  TMS_REG_COLOR_TABLE       = TMS_REG_3,
  TMS_REG_PATTERN_TABLE     = TMS_REG_4,
  TMS_REG_SPRITE_ATTR_TABLE = TMS_REG_5,
  TMS_REG_SPRITE_PATT_TABLE = TMS_REG_6,
  TMS_REG_FG_BG_COLOR       = TMS_REG_7,
} vrEmuTms9918Register;

#define TMS9918_PIXELS_X 512
#define TMS9918_PIXELS_Y 192

/* ==================================================================
 * CORE API
 * ================================================================== */

VR_EMU_TMS9918_DLLEXPORT VrEmuTms9918* vrEmuTms9918New(void);
VR_EMU_TMS9918_DLLEXPORT void         vrEmuTms9918Reset(VrEmuTms9918* tms9918);
VR_EMU_TMS9918_DLLEXPORT void         vrEmuTms9918Destroy(VrEmuTms9918* tms9918);

VR_EMU_TMS9918_DLLEXPORT void    vrEmuTms9918WriteAddr(VrEmuTms9918* tms9918, uint8_t data);
VR_EMU_TMS9918_DLLEXPORT void    vrEmuTms9918WriteData(VrEmuTms9918* tms9918, uint8_t data);
VR_EMU_TMS9918_DLLEXPORT uint8_t vrEmuTms9918ReadStatus(VrEmuTms9918* tms9918);
VR_EMU_TMS9918_DLLEXPORT uint8_t vrEmuTms9918ReadData(VrEmuTms9918* tms9918);
VR_EMU_TMS9918_DLLEXPORT uint8_t vrEmuTms9918ReadDataNoInc(VrEmuTms9918* tms9918);

VR_EMU_TMS9918_DLLEXPORT void vrEmuTms9918ScanLine(VrEmuTms9918* tms9918, uint8_t y, uint8_t pixels[TMS9918_PIXELS_X]);

VR_EMU_TMS9918_DLLEXPORT uint8_t vrEmuTms9918RegValue(VrEmuTms9918* tms9918, vrEmuTms9918Register reg);
VR_EMU_TMS9918_DLLEXPORT void    vrEmuTms9918WriteRegValue(VrEmuTms9918* tms9918, vrEmuTms9918Register reg, uint8_t value);

VR_EMU_TMS9918_DLLEXPORT uint8_t vrEmuTms9918VramValue(VrEmuTms9918* tms9918, uint16_t addr);

VR_EMU_TMS9918_DLLEXPORT bool             vrEmuTms9918DisplayEnabled(VrEmuTms9918* tms9918);
VR_EMU_TMS9918_DLLEXPORT vrEmuTms9918Mode vrEmuTms9918DisplayMode(VrEmuTms9918* tms9918);

/* ==================================================================
 * UTILITY: REGISTER BIT CONSTANTS
 * ================================================================== */

#define TMS_R0_MODE_GRAPHICS_I    0x00
#define TMS_R0_MODE_GRAPHICS_II   0x02
#define TMS_R0_MODE_MULTICOLOR    0x00
#define TMS_R0_MODE_TEXT          0x00
#define TMS_R0_EXT_VDP_ENABLE     0x01
#define TMS_R0_EXT_VDP_DISABLE    0x00

#define TMS_R1_RAM_16K            0x80
#define TMS_R1_RAM_4K             0x00
#define TMS_R1_DISP_BLANK         0x00
#define TMS_R1_DISP_ACTIVE        0x40
#define TMS_R1_INT_ENABLE         0x20
#define TMS_R1_INT_DISABLE        0x00
#define TMS_R1_MODE_GRAPHICS_I    0x00
#define TMS_R1_MODE_GRAPHICS_II   0x00
#define TMS_R1_MODE_MULTICOLOR    0x08
#define TMS_R1_MODE_TEXT          0x10
#define TMS_R1_MODE_TEXT_2        0x18
#define TMS_R1_SPRITE_8           0x00
#define TMS_R1_SPRITE_16          0x02
#define TMS_R1_SPRITE_MAG1        0x00
#define TMS_R1_SPRITE_MAG2        0x01

#define TMS_DEFAULT_VRAM_NAME_ADDRESS          0x3800
#define TMS_DEFAULT_VRAM_COLOR_ADDRESS         0x0000
#define TMS_DEFAULT_VRAM_PATT_ADDRESS          0x2000
#define TMS_DEFAULT_VRAM_SPRITE_ATTR_ADDRESS   0x3B00
#define TMS_DEFAULT_VRAM_SPRITE_PATT_ADDRESS   0x1800

/* ==================================================================
 * UTILITY: PALETTE
 * ================================================================== */

VR_EMU_TMS9918_DLLEXPORT_CONST uint32_t vrEmuTms9918Palette[];

/* ==================================================================
 * UTILITY: INLINE HELPERS
 * ================================================================== */

inline static void vrEmuTms9918WriteRegisterValue(VrEmuTms9918* tms9918, vrEmuTms9918Register reg, uint8_t value)
{
  vrEmuTms9918WriteAddr(tms9918, value);
  vrEmuTms9918WriteAddr(tms9918, 0x80 | (uint8_t)reg);
}

inline static void vrEmuTms9918SetAddressRead(VrEmuTms9918* tms9918, uint16_t addr)
{
  vrEmuTms9918WriteAddr(tms9918, addr & 0x00ff);
  vrEmuTms9918WriteAddr(tms9918, ((addr & 0xff00) >> 8));
}

inline static void vrEmuTms9918SetAddressWrite(VrEmuTms9918* tms9918, uint16_t addr)
{
  vrEmuTms9918SetAddressRead(tms9918, addr | 0x4000);
}

inline static void vrEmuTms9918WriteBytes(VrEmuTms9918* tms9918, const uint8_t* bytes, size_t numBytes)
{
  for (size_t i = 0; i < numBytes; ++i)
    vrEmuTms9918WriteData(tms9918, bytes[i]);
}

inline static void vrEmuTms9918WriteByteRpt(VrEmuTms9918* tms9918, uint8_t byte, size_t rpt)
{
  for (size_t i = 0; i < rpt; ++i)
    vrEmuTms9918WriteData(tms9918, byte);
}

inline static void vrEmuTms9918WriteString(VrEmuTms9918* tms9918, const char* str)
{
  size_t len = strlen(str);
  for (size_t i = 0; i < len; ++i)
    vrEmuTms9918WriteData(tms9918, str[i]);
}

inline static void vrEmuTms9918WriteStringOffset(VrEmuTms9918* tms9918, const char* str, uint8_t offset)
{
  size_t len = strlen(str);
  for (size_t i = 0; i < len; ++i)
    vrEmuTms9918WriteData(tms9918, str[i] + offset);
}

inline static uint8_t vrEmuTms9918FgBgColor(vrEmuTms9918Color fg, vrEmuTms9918Color bg)
{
  return (uint8_t)((uint8_t)fg << 4) | (uint8_t)bg;
}

inline static void vrEmuTms9918SetNameTableAddr(VrEmuTms9918* tms9918, uint16_t addr)
{
  vrEmuTms9918WriteRegisterValue(tms9918, TMS_REG_NAME_TABLE, addr >> 10);
}

inline static void vrEmuTms9918SetColorTableAddr(VrEmuTms9918* tms9918, uint16_t addr)
{
  vrEmuTms9918WriteRegisterValue(tms9918, TMS_REG_COLOR_TABLE, (uint8_t)(addr >> 6));
}

inline static void vrEmuTms9918SetPatternTableAddr(VrEmuTms9918* tms9918, uint16_t addr)
{
  vrEmuTms9918WriteRegisterValue(tms9918, TMS_REG_PATTERN_TABLE, addr >> 11);
}

inline static void vrEmuTms9918SetSpriteAttrTableAddr(VrEmuTms9918* tms9918, uint16_t addr)
{
  vrEmuTms9918WriteRegisterValue(tms9918, TMS_REG_SPRITE_ATTR_TABLE, (uint8_t)(addr >> 7));
}

inline static void vrEmuTms9918SetSpritePattTableAddr(VrEmuTms9918* tms9918, uint16_t addr)
{
  vrEmuTms9918WriteRegisterValue(tms9918, TMS_REG_SPRITE_PATT_TABLE, addr >> 11);
}

inline static void vrEmuTms9918SetFgBgColor(VrEmuTms9918* tms9918, vrEmuTms9918Color fg, vrEmuTms9918Color bg)
{
  vrEmuTms9918WriteRegisterValue(tms9918, TMS_REG_FG_BG_COLOR, vrEmuTms9918FgBgColor(fg, bg));
}

/* ==================================================================
 * UTILITY: MODE INITIALIZERS
 * ================================================================== */

VR_EMU_TMS9918_DLLEXPORT void vrEmuTms9918InitialiseGfxI(VrEmuTms9918* tms9918);
VR_EMU_TMS9918_DLLEXPORT void vrEmuTms9918InitialiseGfxII(VrEmuTms9918* tms9918);
VR_EMU_TMS9918_DLLEXPORT void vrEmuTms9918InitialiseText2(VrEmuTms9918* tms9918);

#endif /* _VDRIP_VDP_H_ */
