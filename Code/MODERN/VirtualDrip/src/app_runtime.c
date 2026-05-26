#define _DEFAULT_SOURCE

#include "app_runtime.h"

#include <signal.h>
#include <unistd.h>

/*
 * Keep signal handling out of transport/display modules. They receive a stop
 * predicate instead of depending on process-global state directly.
 */

static volatile sig_atomic_t running = 1;

static void handle_signal(int signal_number)
{
    (void)signal_number;
    running = 0;
}

void app_runtime_install_signal_handlers(void)
{
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
}

void app_runtime_request_stop(void)
{
    running = 0;
}

bool app_runtime_should_stop(void *userdata)
{
    (void)userdata;
    return running == 0;
}

void app_runtime_run_headless_loop(void)
{
    while (!app_runtime_should_stop(NULL)) {
        usleep(100000);
    }
}
