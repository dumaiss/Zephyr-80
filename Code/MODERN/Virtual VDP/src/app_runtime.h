#ifndef APP_RUNTIME_H
#define APP_RUNTIME_H

/**
 * @file app_runtime.h
 * Small process lifetime helpers shared by main loops and worker threads.
 */

#include <stdbool.h>

/** Install SIGINT/SIGTERM handlers that request a clean shutdown. */
void app_runtime_install_signal_handlers(void);

/** Request shutdown from application code. */
void app_runtime_request_stop(void);

/** Stop predicate compatible with display and serial reader callbacks. */
bool app_runtime_should_stop(void *userdata);

/** Idle loop for headless/no-input modes until shutdown is requested. */
void app_runtime_run_headless_loop(void);

#endif
