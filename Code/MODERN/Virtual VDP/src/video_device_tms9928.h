#ifndef VIDEO_DEVICE_TMS9928_H
#define VIDEO_DEVICE_TMS9928_H

/**
 * @file video_device_tms9928.h
 * Concrete TMS9928A/TMS9918-style backend factory.
 *
 * The implementation uses vrEmuTms9918 and is the only module that should
 * include vrEmuTms9918.h. It exposes a generic VideoDevice to the rest of the
 * proxy.
 */

#include "video_device.h"

/**
 * Create a TMS9928A-compatible backend.
 *
 * The returned VideoDevice owns its emulator instance and must be destroyed
 * with video_device_destroy().
 */
VideoDevice *video_device_tms9928_create(void);

#endif
