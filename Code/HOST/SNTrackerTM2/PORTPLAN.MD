# Port status and remaining gates

The port is implemented end-to-end as native Turbo Modula-2 modules.  Building
on the Zephyr is the primary development workflow; RunCPM is an optional
iteration aid, not a required hosted toolchain.

Completed implementation stages:

1. The assembly SNTracker remains unchanged as the playback oracle.
2. The ZMAC-to-TM2 REL bridge is proven.  The private foreign entry names obey
   Microsoft REL's six-character limit.
3. Timer and Sound abstractions and their standalone tests are implemented.
4. The ZTR v1 reader validates packed bytes explicitly and has loaded the full
   20,234-byte Night Market file under RunCPM.
5. The typed Player implements the current event, macro, effect and notation
   model and traverses both regression songs to completion.
6. Timer, Player, Sound, low-rate UI and command-line loading are integrated in
   `SNTRACK.COM`.

Remaining acceptance work requires the physical Zephyr:

1. Verify the TM2 foreign-call parameter convention under live timer use.
2. Verify private IM2 SIO mirroring and restoration with the configured BIOS.
3. Measure timer queue high-water behavior during dense 16-channel playback.
4. Compare Night Market and Runaway Circuit audibly with the assembly player.
5. Promote stable Timer and Sound interfaces into a shared TM2 platform tree.

No BIOS jump-table entry, memory allocation, console driver, disk geometry, or
existing assembly tracker source is changed by this port.
