#ifndef VIDEO_DEVICE_VDRIP9928_H
#define VIDEO_DEVICE_VDRIP9928_H

/**
 * @file video_device_vdrip9928.h
 * Concrete vDrip9928 backend factory.
 *
 * The implementation uses the vdrip_vdp library (fork of vrEmuTms9918 with
 * Text 2 80-column mode) and is the only module that should include
 * vdrip_vdp.h. It exposes a generic VideoDevice to the rest of the proxy.
 */

#include "video_device.h"

/**
 * Create a vDrip9928 backend.
 *
 * The returned VideoDevice owns its emulator instance and must be destroyed
 * with video_device_destroy().
 */
VideoDevice *video_device_vdrip9928_create(void);

#endif
