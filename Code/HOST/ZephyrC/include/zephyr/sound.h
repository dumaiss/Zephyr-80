/* sound.h -- Afternoon Blend: four SN76489 PSGs and an AD7801 PCM DAC.
 * See DOC/API.md section 7.
 */
#ifndef ZEPHYR_SOUND_H
#define ZEPHYR_SOUND_H

#include <zephyr/zephyr.h>

#define ZEP_SOUND_CHANNELS  16   /* chip = channel >> 2, voice = channel & 3 */

void     zep_sound_init(void);                        /* mutes; mutes again at exit */
void     zep_sound_mute_all(void);
uint8_t  zep_sound_tone(uint8_t channel, uint16_t period);   /* voices 0-2; period 1-1023 */
void     zep_sound_volume(uint8_t channel, uint8_t attenuation); /* 0 loudest, 15 off */
uint8_t  zep_sound_noise(uint8_t channel, uint8_t white, uint8_t rate); /* voice 3; rate 0-3 */
uint8_t  zep_sound_restart_noise(uint8_t channel);
uint16_t zep_sound_period_for_hz(uint16_t hz);        /* 111861 / hz, 0 if out of range */

void     zep_psg_write(uint8_t chip, uint8_t byte);
void     zep_psg_write_block(uint8_t chip, const uint8_t *bytes, uint8_t n);
void     zep_pcm_write(uint8_t sample);
void     zep_pcm_write_block(const uint8_t *samples, uint16_t n);

#endif
