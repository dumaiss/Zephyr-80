/* TONETEST.COM -- the sound card on its own.
 *
 * No timer, no video: if MANDEL dies at its chime but this plays, the fault is
 * not in the sound path.  Delays are counted loops, so nothing depends on
 * interrupts either.
 *
 *   TONETEST [chip]     chip 0-3, default 0
 */
#include <stdio.h>
#include <stdlib.h>
#include <zephyr/sound.h>
#include <zephyr/input.h>

/* volatile, or SDCC deletes the loop: the first version of this test played the
 * chord, the fade and the noise within microseconds of each other and sounded
 * like three quick notes and nothing else. */
static void hold(uint16_t units)
{
    volatile uint16_t i;

    while (units--)
        for (i = 0; i < 1000; i++)
            ;
}

int main(int argc, char **argv)
{
    static const uint16_t notes[3] = { 523, 659, 784 };
    uint8_t chip = 0, base, n, level;

    printf("TONETEST - ZephyrC sound\n");
    if (argc > 1)
        chip = (uint8_t)atoi(argv[1]) & 3;
    base = (uint8_t)(chip * 4);

    printf("init\n");
    zep_sound_init();

    printf("chord on PSG%u\n", chip);
    for (n = 0; n < 3; n++) {
        printf("  voice %u: period %u\n", n, zep_sound_period_for_hz(notes[n]));
        (void)zep_sound_tone((uint8_t)(base + n), zep_sound_period_for_hz(notes[n]));
        zep_sound_volume((uint8_t)(base + n), 2);
    }
    hold(200);

    printf("fade\n");
    for (level = 3; level <= 15; level++) {
        for (n = 0; n < 3; n++)
            zep_sound_volume((uint8_t)(base + n), level);
        hold(40);
    }

    printf("noise\n");
    (void)zep_sound_noise((uint8_t)(base + 3), 1, 1);
    zep_sound_volume((uint8_t)(base + 3), 4);
    hold(150);

    zep_sound_mute_all();
    printf("TONETEST done\n");
    return 0;
}
