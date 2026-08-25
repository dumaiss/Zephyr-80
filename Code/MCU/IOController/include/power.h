#ifndef POWER_H
#define POWER_H

#include <stdbool.h>

/* Shutdown handshake with the PMU.
 *
 *   /SHUTDOWN_RQ  RF7  in   PMU -> IOC: "please clean up, we are going down"
 *   /PWR_OFF      RF6  out  IOC -> PMU: "done, cut the rails"
 *
 * The IOC decides when power actually goes away.  The PMU only asks.  That is
 * the right way round for this machine, because the thing that takes time is
 * the SD write-back cache and only the IOC knows whether it is dirty.
 *
 * Both signals are ACTIVE LOW so each end can hold its own input deasserted
 * with a programmed pull-up.  A net whose partner is unpowered or high-Z then
 * reads "nothing requested" instead of floating.  Neither MCU has programmable
 * pull-downs, so this is the only polarity that is fail-safe in firmware.
 *
 * /SHUTDOWN_RQ is a shutdown request and nothing else.  It does not gate
 * whether the system may run -- the PMU powers the machine once PWR_OK is good.
 *
 * The request is latched in hardware because port F has no interrupt-on-change
 * and the main loop can be blind for a couple of hundred milliseconds inside an
 * SD write.  See power.c for why INT2 specifically, and why its interrupt is
 * deliberately never enabled.
 */

void power_init(void);

/* True once the PMU has asked for a shutdown: either the latched edge or the
 * level being asserted right now. */
bool power_shutdown_requested(void);

/* Assert /PWR_OFF and do not return.  Call only after the cache is committed. */
void power_off(void);

#endif /* POWER_H */
