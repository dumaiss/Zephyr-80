#include <rfb/rfb.h>

#include <stdint.h>
#include <stdio.h>

#define WIDTH 256
#define HEIGHT 192
#define BYTES_PER_PIXEL 4
#define CHECKER_SIZE 16
#define PORT 5900

static uint32_t framebuffer[WIDTH * HEIGHT];

static uint32_t rgb(uint8_t red, uint8_t green, uint8_t blue)
{
    return ((uint32_t)red << 16) | ((uint32_t)green << 8) | (uint32_t)blue;
}

static void draw_checkerboard(void)
{
    for (int y = 0; y < HEIGHT; ++y) {
        for (int x = 0; x < WIDTH; ++x) {
            int checker = ((x / CHECKER_SIZE) ^ (y / CHECKER_SIZE)) & 1;
            framebuffer[(y * WIDTH) + x] = checker ? rgb(240, 240, 240) : rgb(32, 48, 64);
        }
    }
}

static enum rfbNewClientAction new_client(rfbClientPtr client)
{
    client->preferredEncoding = rfbEncodingRaw;
    client->useCopyRect = FALSE;
    return RFB_CLIENT_ACCEPT;
}

static void prefer_raw_encoding(rfbScreenInfoPtr screen)
{
    rfbClientIteratorPtr iterator = rfbGetClientIterator(screen);
    rfbClientPtr client = NULL;

    while ((client = rfbClientIteratorNext(iterator)) != NULL) {
        client->preferredEncoding = rfbEncodingRaw;
        client->useCopyRect = FALSE;
    }

    rfbReleaseClientIterator(iterator);
}

int main(int argc, char **argv)
{
    draw_checkerboard();

    rfbScreenInfoPtr screen = rfbGetScreen(&argc, argv, WIDTH, HEIGHT, 8, 3, BYTES_PER_PIXEL);
    if (screen == NULL) {
        fprintf(stderr, "Failed to create VNC screen\n");
        return 1;
    }

    screen->desktopName = "Virtual VDP";
    screen->frameBuffer = (char *)framebuffer;
    screen->port = PORT;
    screen->alwaysShared = TRUE;
    screen->newClientHook = new_client;
    screen->serverFormat.redShift = 16;
    screen->serverFormat.greenShift = 8;
    screen->serverFormat.blueShift = 0;
    screen->serverFormat.redMax = 255;
    screen->serverFormat.greenMax = 255;
    screen->serverFormat.blueMax = 255;

    rfbInitServer(screen);
    rfbMarkRectAsModified(screen, 0, 0, WIDTH, HEIGHT);

    printf("VNC checkerboard listening on port %d (%dx%d, 32-bit framebuffer)\n", PORT, WIDTH, HEIGHT);

    while (rfbIsActive(screen)) {
        prefer_raw_encoding(screen);
        rfbProcessEvents(screen, 100000);
    }

    rfbScreenCleanup(screen);
    return 0;
}
