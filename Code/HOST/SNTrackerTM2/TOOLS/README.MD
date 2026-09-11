# PC build tool

`TM2BUILD.PY` drives the original Turbo Modula-2, ZMAC and linker inside an
isolated RunCPM directory-backed CP/M drive.  It is not a replacement compiler:
the generated code comes from the same tools used on the Zephyr.

The driver deliberately starts fresh TM2 sessions for definition compilation,
REL conversion, implementation compilation and linker bootstrapping.  The final
programs are linked by `TLINK.COM`, outside the large IDE process.  This avoids
the physical Zephyr's TPA limit.

Only Python 3 is required on the build PC.  `RUNCPM` is the verified x86-64
Linux executable used during the port and is selected by the Makefile by
default.  Set `RUNCPM` when building on another host or with another RunCPM
binary.  The TM2 distribution and CCP are used from their existing locations
elsewhere in this repository.  Run `make help` to see every overridable path.

RunCPM is Copyright (c) 2017 Mockba the Borg and distributed under the MIT
license reproduced in `RCPM.LIC`.  Its upstream source is
`https://github.com/MockbaTheBorg/RunCPM`.

On failure, the temporary `sntrack-tm2-*` directory is retained and printed so
the CP/M files can be inspected.  A successful build removes it after copying
the five COM files to `BUILD`.
