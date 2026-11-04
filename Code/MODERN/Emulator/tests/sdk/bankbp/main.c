/* bankbp: resident code that calls the home zone and far segment 1 in
 * turn.  home_step (home.c) and far_step (far.c) are each the first code of
 * their zone, linked at 8000h; the placer's veneers reach them, far_step with
 * the mode-10 aperture open onto its own bank. */

#include "kos.h"

unsigned int home_step(unsigned int value);
unsigned int far_step(unsigned int value);

#define ROUNDS 3u

int main(void)
{
	unsigned int value = 1u;
	unsigned int i;

	for (i = 0u; i < ROUNDS; i++) {
		value = home_step(value);
		value = far_step(value);
	}
	printf("BANKBP rounds=%u value=%u\r\n", ROUNDS, value);
	return 0;
}
