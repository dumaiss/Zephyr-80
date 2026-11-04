/* savework: card reads and writes, the timer, the console and the sound
 * card in one run, so a state saved anywhere in it has open files, bulk
 * transfers, timer ticks, VDP drawing and PSG writes in flight.
 *
 *   1. read /fs/INPUT.BIN in 512-byte reads, summing its bytes;
 *   2. write /fs/OUTPUT.BIN, 16 blocks of 512 bytes derived from the sum,
 *      re-reading the first block through a second handle;
 *   3. twenty 20 ms timer waits, each changing a PSG0 tone and printing a
 *      progress line;
 *   4. print the result line and silence the card. */

#include "kos.h"
#include "kos/timer.h"
#include "kos/sound.h"

static unsigned char buffer[512];

static unsigned char pattern(unsigned int block, unsigned int i, unsigned int seed)
{
	return (unsigned char)(block * 31u + i * 7u + seed);
}

int main(void)
{
	unsigned int sum = 0u, check = 0u, written = 0u;
	unsigned int block, i;
	int in, out, again, timer, sound, n;

	in = open("/fs/INPUT.BIN", KFS_O_READ);
	if (in < 0) {
		printf("SAVEWORK FAIL open input %d\r\n", in);
		return 1;
	}
	while ((n = read((unsigned int)in, buffer, sizeof(buffer))) > 0) {
		for (i = 0u; i < (unsigned int)n; i++) {
			sum += buffer[i];
		}
	}
	close((unsigned int)in);
	printf("SAVEWORK read sum=%u\r\n", sum);

	out = open("/fs/OUTPUT.BIN", KFS_O_WRITE | KFS_O_CREATE | KFS_O_TRUNC);
	if (out < 0) {
		printf("SAVEWORK FAIL open output %d\r\n", out);
		return 1;
	}
	for (block = 0u; block < 16u; block++) {
		for (i = 0u; i < sizeof(buffer); i++) {
			buffer[i] = pattern(block, i, sum);
		}
		n = write((unsigned int)out, buffer, sizeof(buffer));
		if (n > 0) {
			written += (unsigned int)n;
		}
	}
	sync((unsigned int)out);
	again = open("/fs/OUTPUT.BIN", KFS_O_READ);
	if (again >= 0) {
		n = read((unsigned int)again, buffer, sizeof(buffer));
		for (i = 0u; i < (unsigned int)n; i++) {
			check += buffer[i];
		}
		close((unsigned int)again);
	}
	close((unsigned int)out);
	printf("SAVEWORK wrote %u check=%u\r\n", written, check);

	timer = timer_open();
	sound = sound_open(1u);
	for (i = 0u; i < 20u; i++) {
		if (sound >= 0) {
			sound_out(0xe0u, (unsigned char)(0x80u | (i & 0x0fu)));
			sound_out(0xe0u, (unsigned char)(0x04u + i));
			sound_out(0xe0u, 0x90u);
		}
		if (timer >= 0) {
			timer_wait_us(timer, 20000u);
		}
		printf("SAVEWORK tick %u\r\n", i);
	}
	if (sound >= 0) {
		sound_close(sound);
	}
	printf("SAVEWORK done sum=%u wrote=%u check=%u\r\n", sum, written, check);
	return 0;
}
