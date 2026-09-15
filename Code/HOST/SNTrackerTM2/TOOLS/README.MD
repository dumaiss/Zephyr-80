# PC build tool

`TM2BUILD.PY` builds the thin standalone tracker against the sibling
`Zephyr80Lib` archive inside an isolated RunCPM directory-backed CP/M drive. It
is not a replacement compiler: generated code comes from the same Turbo
Modula-2 tools used on the Zephyr.

The driver selects `SYSLIB ZEPHYR80` as the TM2 search path, compiles only
`SNTRACK`, then extracts the needed `.MCD` members from
`ZEPHYR80.LIB`. The final program is linked by `TLINK.COM` outside the large IDE
process to avoid the physical Zephyr's TPA limit.

By default the Makefile rebuilds `../Zephyr80Lib` and reuses its verified
RunCPM executable, embedded TM2 distribution, CCP image and resulting
`ZEPHYR80.LIB`. Set the Make variables shown by `make help` to override them.

RunCPM is Copyright (c) 2017 Mockba the Borg and distributed under the MIT
license reproduced in `RCPM.LIC`.  Its upstream source is
`https://github.com/MockbaTheBorg/RunCPM`.

On failure, the temporary `sntrack-tm2-*` directory is retained and printed so
the CP/M files can be inspected. A successful build removes it after copying
`SNTRACK.COM` to `BUILD`.
