/* bankbp's home zone: the first code at 8000h of the program's own bank. */

unsigned int home_step(unsigned int value)
{
	return value * 3u + 1u;
}
