/**
 * @file main.c
 * @brief NOT THE FIRMWARE ENTRY POINT — generated MPLAB scaffolding.
 *
 * The IOController firmware starts in src/main.c.  This file is the stub MPLAB
 * creates at the project root; it is kept only because MPLAB regenerates its
 * reference under the per-configuration .generated directories in cmake, and in
 * .vscode/IOController.mplab.json, so deleting it does not make it stay gone.
 *
 * Both supported builds exclude it:
 *   - the hand Makefile compiles the main.c under src and never names this one;
 *   - the MPLAB/CMake builds drop it in the persistent user hook, via
 *     list(REMOVE_ITEM _ioc_sources "${_ioc_root_stub_main}").
 *
 * It previously held a plausible-looking main() with an empty forever loop,
 * which is a maintenance trap: two apparent entry points, one of which silently
 * does nothing.  The body is gone so that anyone who does manage to build it
 * gets a link error naming this file, rather than a firmware image that starts
 * and then spins.
 *
 * If you are looking for the main loop -- command dispatch, the SD cache flush,
 * USB host service, the CTRL-ALT-ESC reset -- it is in the main.c under src.
 */

/* Deliberately empty.  See above: this translation unit defines nothing, so it
 * cannot be mistaken for the entry point and cannot silently become one. */
