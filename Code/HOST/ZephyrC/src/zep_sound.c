/* zep_sound.c -- Afternoon Blend PSGs and PCM DAC.
 *
 * Write-only ports: E0h-E3h PSG0-3, E4h PCM.  The card holds /WAIT until each
 * chip is ready, so writes need no delays.  The chips have no reset input.
 */
#include <zephyr/sound.h>
#include "zep_internal.h"

#define PSG_PORT(chip)  (0xe0 + (chip))
#define PCM_PORT        0xe4

static uint8_t noise_shadow[4] = { 0xe0, 0xe0, 0xe0, 0xe0 };

static void sound_cleanup(void)
{
    zep_sound_mute_all();
}

void zep_sound_mute_all(void)
{
    uint8_t chip;
    for (chip = 0; chip < 4; chip++) {
        zep__out(PSG_PORT(chip), 0x9f);
        zep__out(PSG_PORT(chip), 0xbf);
        zep__out(PSG_PORT(chip), 0xdf);
        zep__out(PSG_PORT(chip), 0xff);
    }
}

void zep_sound_init(void)
{
    zep_sound_mute_all();
    zep__on_exit(ZEP__MOD_SOUND, sound_cleanup);
}

uint8_t zep_sound_tone(uint8_t channel, uint16_t period)
{
    uint8_t voice = channel & 3;

    if (channel >= ZEP_SOUND_CHANNELS || voice == 3 || period == 0 || period > 1023)
        return ZEP_EINVAL;
    zep__out(PSG_PORT(channel >> 2), 0x80 | (voice << 5) | (period & 0x0f));
    zep__out(PSG_PORT(channel >> 2), (uint8_t)(period >> 4) & 0x3f);
    return ZEP_OK;
}

void zep_sound_volume(uint8_t channel, uint8_t attenuation)
{
    if (channel >= ZEP_SOUND_CHANNELS)
        return;
    if (attenuation > 15)
        attenuation = 15;
    zep__out(PSG_PORT(channel >> 2), 0x90 | ((channel & 3) << 5) | attenuation);
}

uint8_t zep_sound_noise(uint8_t channel, uint8_t white, uint8_t rate)
{
    uint8_t chip = channel >> 2;

    if (channel >= ZEP_SOUND_CHANNELS || (channel & 3) != 3 || rate > 3)
        return ZEP_EINVAL;
    noise_shadow[chip] = 0xe0 | (white ? 0x04 : 0x00) | rate;
    zep__out(PSG_PORT(chip), noise_shadow[chip]);
    return ZEP_OK;
}

/* Writing the noise control register restarts the shift register. */
uint8_t zep_sound_restart_noise(uint8_t channel)
{
    if (channel >= ZEP_SOUND_CHANNELS || (channel & 3) != 3)
        return ZEP_EINVAL;
    zep__out(PSG_PORT(channel >> 2), noise_shadow[channel >> 2]);
    return ZEP_OK;
}

uint16_t zep_sound_period_for_hz(uint16_t hz)
{
    uint32_t n;

    if (hz == 0)
        return 0;
    n = (111861UL + hz / 2) / hz;       /* 3.579545 MHz / 32 / hz */
    return (n == 0 || n > 1023) ? 0 : (uint16_t)n;
}

void zep_psg_write(uint8_t chip, uint8_t byte)
{
    if (chip < 4)
        zep__out(PSG_PORT(chip), byte);
}

void zep_psg_write_block(uint8_t chip, const uint8_t *bytes, uint8_t n)
{
    if (chip < 4)
        zep__otir(PSG_PORT(chip), bytes, n);
}

void zep_pcm_write(uint8_t sample)
{
    zep__out(PCM_PORT, sample);
}

void zep_pcm_write_block(const uint8_t *samples, uint16_t n)
{
    zep__otir(PCM_PORT, samples, n);
}
