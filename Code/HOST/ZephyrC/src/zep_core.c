/* zep_core.c -- cleanup at exit, CTC ownership, stub installation, callbacks. */
#include <stdlib.h>
#include <string.h>
#include <cpm.h>
#include "zep_internal.h"

uint8_t zep__ctc_owner[4];

static zep__cleanup_fn cleanups[ZEP__MOD_COUNT];
static uint8_t atexit_registered;
static uint8_t stubs_installed;
/* Off by default: the BIOS holds the screen at warm boot for every program,
 * including ones this library never compiled.  zep_exit_pause(1) is for a
 * program that wants the wait on a BIOS without it. */
static uint8_t pause_at_exit;

static void run_cleanups(void);

/* z88dk's startup code ends a program with a warm boot, and warm boot
 * reinitialises the console, which clears the screen.  Anything the program
 * printed on its way out would be gone before it could be read, so hold the
 * screen until a key is pressed.
 *
 * BDOS 6 is used rather than stdio: it pulls nothing in for programs that never
 * print, and polling console input is also what flushes the V9958 console's
 * pending output, so the prompt appears. */
static void pause_for_key(void)
{
    static const char prompt[] = "\r\n[any key]";
    const char *p = prompt;

    while (*p)
        bdos(6, (uint8_t)*p++);
    while ((uint8_t)bdos(6, 0xff) == 0)
        ;
    bdos(6, '\r');
    bdos(6, '\n');
}

/* Off for a program that must not block on its way out, such as one driven from
 * a SUBMIT file.  On for one that has nothing registered but still wants it. */
void zep_exit_pause(uint8_t enable)
{
    pause_at_exit = enable;
    if (!atexit_registered) {
        atexit_registered = 1;
        atexit(run_cleanups);
    }
}

/* Later modules first: a timer may be feeding sound, the VDP is given back last
 * so the console is usable for anything the program prints after main. */
static void run_cleanups(void)
{
    uint8_t i = ZEP__MOD_COUNT;
    while (i--) {
        zep__cleanup_fn fn = cleanups[i];
        if (fn) {
            cleanups[i] = 0;
            fn();
        }
    }
    if (pause_at_exit)
        pause_for_key();
}

void zep__on_exit(uint8_t module, zep__cleanup_fn fn)
{
    cleanups[module] = fn;
    if (!atexit_registered) {
        atexit_registered = 1;
        atexit(run_cleanups);
    }
}

void zep__stubs_install(void)
{
    if (stubs_installed)
        return;
    memcpy((void *)ZEP__STUB_BASE, zep__stub_image, zep__stub_image_len);
    stubs_installed = 1;
}

uint8_t zep__isr_register(uint8_t source, uint16_t entry)
{
    zep__bdoscall_t call;
    call.c = 200;
    call.b = source;
    call.de = entry;
    return (uint8_t)zep__bdos_bcde(&call) == 0 ? ZEP_OK : ZEP_EUNAVAILABLE;
}

uint8_t zep__isr_unregister(uint8_t source)
{
    zep__bdoscall_t call;
    call.c = 201;
    call.b = source;
    call.de = 0;
    return (uint8_t)zep__bdos_bcde(&call) == 0 ? ZEP_OK : ZEP_EINVAL;
}
