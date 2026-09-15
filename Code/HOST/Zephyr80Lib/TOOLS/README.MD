# Hosted build tools

`LIBBUILD.PY` drives the original Turbo Modula-2 toolchain inside an isolated
RunCPM directory-backed CP/M drive. It is not a replacement or cross-compiler:
the generated code comes from the same CP/M compiler, assembler, REL converter,
librarian, and linker used for on-host development.

This project embeds all inputs needed by the hosted build:

- `RUNCPM` is the verified x86-64 Linux RunCPM 6.9 executable;
- `RCPM.LIC` contains its MIT license;
- `CCP-ZCP3.60K` is the repository's ZCPR3 CCP image; and
- `TM2` is an unchanged copy of `Code/HOST/Software/disk1/4`, including Turbo
  Modula-2, its system library, and ZMAC.

RunCPM is Copyright (c) 2017 Mockba the Borg. Its upstream source is
`https://github.com/MockbaTheBorg/RunCPM`.

The build stages uppercase CRLF copies of project sources because the CP/M
tools and the Linux directory-backed drive are case-sensitive about those
details. Repository sources remain readable LF files.

The build sequence is:

1. assemble `CTCLOW.Z80` with ZMAC;
2. compile every definition module;
3. convert the Microsoft-format `CTCLOW.REL` bridge in a fresh TM2 session;
4. compile every implementation module;
5. create `ZEPHYR80.LIB` with the original TM2 Librarian;
6. delete the loose library `.SYM` and `.MCD` files, then compile consumers
   through the `SYSLIB ZEPHYR80` archive search path;
7. create `TLINK.COM`, extract the library's `.MCD` members through the
   Librarian, and link outside the large IDE process; and
8. run hardware-independent API, ZTR, and complete-song regressions.

The extraction in step 7 is necessary because a program using the full
`Player` exceeds the integrated linker's available workspace. It does not
bypass the archive: the members are copied out of the newly built library, and
consumer compilation already occurred with every loose library product
removed.

On failure, the temporary `zephyr80lib-*` directory is retained and printed for
inspection. A successful build removes it after publishing the library and test
programs under `BUILD`.
