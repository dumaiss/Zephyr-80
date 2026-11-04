/* bankbp's far segment 1: the first code at 8000h of the segment's bank. */

unsigned int far_step(unsigned int value)
{
	return value + 7u;
}
