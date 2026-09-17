/* zephyr.h -- ZephyrC common definitions.
 *
 * Every public ZephyrC header includes this one.  See DOC/API.md.
 */
#ifndef ZEPHYR_ZEPHYR_H
#define ZEPHYR_ZEPHYR_H

#include <stdint.h>

/* Results.  Functions returning uint8_t status use these. */
#define ZEP_OK            0
#define ZEP_EINVAL        1   /* an argument is out of range */
#define ZEP_EBUSY         2   /* the resource is already owned */
#define ZEP_ETIMEOUT      3
#define ZEP_EUNAVAILABLE  4   /* the BIOS, firmware or hardware cannot do it */
#define ZEP_ENOTOPEN      5   /* the resource was not opened by this program */
#define ZEP_EIO           6   /* a device or disk operation failed */

/* A program ends in a warm boot, which reinitialises the console and clears the
 * screen.  ZephyrC holds the screen with "[any key]" first, so the last thing
 * printed can be read.  Pass 0 to end without waiting (a SUBMIT file, say);
 * pass 1 from a program that registers nothing else but still wants the pause. */
void zep_exit_pause(uint8_t enable);

/* Common memory, mapped in every bank and memory mode.
 * E000h-E2FFh is handed out by zep_common_alloc().
 * E300h-E3FFh belongs to the library's own interrupt and trampoline stubs. */
#define ZEP_COMMON_BASE   0xE000
#define ZEP_COMMON_END    0xE300

#endif
