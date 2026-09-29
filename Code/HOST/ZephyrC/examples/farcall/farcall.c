/* FARCALL.COM -- the smallest useful call into another SRAM bank.
 *
 * far_code.asm is position-independent.  This program copies those few bytes
 * from its normal bank-0 image to 8000h in bank 1, then asks ZephyrC's common-
 * memory trampoline to call them with HL = ARGUMENT.  The trampoline restores
 * bank 0 and returns the callee's HL.
 *
 * The far routine cannot use this program's globals, libc or BDOS: bank 0 is
 * not mapped while it runs.  The future banked startup described in DOC/API.md
 * will provide the shared root needed for ordinary C __banked functions.
 */
#include <stdio.h>
#include <zephyr/bank.h>

#define FAR_BANK       1
#define FAR_ADDRESS    0x8000
#define ARGUMENT       0x1234
#define FAR_INCREMENT  0x0100

extern const uint8_t far_code_start[];
extern const uint8_t far_code_end[];

int main(void)
{
    uint16_t size = (uint16_t)(far_code_end - far_code_start);
    uint16_t result;
    uint8_t status;

    printf("FARCALL - ZephyrC bank-call example\n");
    printf("Copying %u bytes to bank %u at %04Xh\n",
           size, FAR_BANK, FAR_ADDRESS);

    status = zep_bank_write(FAR_BANK, FAR_ADDRESS, far_code_start, size);
    if (status != ZEP_OK) {
        printf("Bank copy failed: status %u\n", status);
        return 1;
    }

    result = zep_bank_call(FAR_BANK, FAR_ADDRESS, ARGUMENT);
    printf("far_add(%04Xh) returned %04Xh\n", ARGUMENT, result);

    if (result != ARGUMENT + FAR_INCREMENT) {
        printf("FARCALL: FAILED (expected %04Xh)\n",
               ARGUMENT + FAR_INCREMENT);
        return 1;
    }

    printf("FARCALL: passed\n");
    return 0;
}
