# Hosted build tools

`FTLBUILD.PY` drives the FTL Modula-2 toolchain inside an isolated RunCPM
directory-backed CP/M drive. It is not a cross-compiler: the generated code
comes from the same CP/M compiler, assembler and linker used for on-host
development.

This project embeds the inputs the hosted build needs:

- `RUNCPM` is the verified x86-64 Linux RunCPM 6.9 executable;
- `RCPM.LIC` contains its MIT license; and
- `CCP-ZCP3.60K` is the repository's ZCPR3 CCP image.

The FTL distribution itself is not copied here. It is read from
`Code/HOST/Software/disk1/5`, and `SYMFILES.LQR` and `MODULA2.LQR` are unpacked
into the staging drive at build time.

RunCPM is Copyright (c) 2017 Mockba the Borg. Its upstream source is
`https://github.com/MockbaTheBorg/RunCPM`.

The build stages uppercase CRLF copies of project sources, because the CP/M
tools and the Linux directory-backed drive are case-sensitive about those
details, and CRLF is not cosmetic: FTL's compilers are line-oriented and read
an LF-only file as one enormous line. `MD` reports that as `ERROR 81 end of
file reached before program complete`. Repository sources under `SRC` and
`TEST` are therefore stored CRLF and pinned that way by `.gitattributes`.

The build sequence is:

1. compile `CTCLOW.DEF` and assemble the `CTCLOW` callback bridge;
2. compile `PORTIO.DEF` and assemble `PORTIO.ASM`;
3. compile the `Sound` and `ZTR` definition and implementation modules; and
4. compile and link `FTLTEST`.

`PortIO` is built from source rather than imported because it is the one
assembly-backed module Dave Moore ships without a prebuilt object: `CHAIN`,
`CPM`, `CPMBIOS`, `EXCHANGE`, `FASTMOVE` and `INTLOGIC` all have a `.REL` and
`.SYM` in `MODULA2.LQR` and `SYMFILES.LQR`, and `PORTIO` has neither. An FTL
installation whose libraries do carry a compiled `PortIO` can drop
`SRC/PORTIO.*`; the copy of the distribution in this repository does not, so
the build stays self-contained.

On failure, the temporary `zephyr-ftl-*` directory is retained and printed for
inspection.
