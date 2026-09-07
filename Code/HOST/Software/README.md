# Zephyr-80 Software

The programs that **run on** the machine, and the two CP/M volumes that carry
them. Programs that *are* the machine — rescue tools, diagnostics, anything on
the ROM A: volume — live in `../Utilities`.

| Volume | Holds |
|---|---|
| `CPM_1.DRV` | Third-party CP/M software: Turbo Pascal, Modula-2, WordStar, SuperCalc, dBASE, BBC BASIC, MBASIC, ZDE, Barsoom, and the stock DRI tools. User areas are preserved as they were on the machine, so each package stays where its installer put it. |
| `CPM_2.DRV` | Your own work. User 0: the Mandelbrot and smiley demos. User 2: V9958 definition, symbol and library files. |

ColecoGo, the VGM player and their ROMs and media live on `CPM_1.DRV` user 8,
where they were on the machine.

The demo *sources* — `mandelbrot*.asm`, `video_smiley*.asm`, `mandel-mbasic.bas`,
`mandel-bbcbasic.bas`, `mandel.pas` — live in `../HelloWorld/src`, which is where
they are maintained. The copies here are what is on the machine, and the two have
drifted: `mandel.bas`, `mandel.bbc` and `mandel.pas` are all shorter here than
their HelloWorld counterparts. Both are kept deliberately; neither is generated
from the other.

## Building

```sh
make                      # build/CPM_1.DRV and build/CPM_2.DRV
make list                 # show what goes on each volume
make install CARD=/mnt/sd # copy both onto a mounted FAT card (opt-in)
```

Output goes to `build/` and nowhere else. In particular this project never
writes `../CPM2.2/images/zephyr80-vdrip2.cpm`, which is a working volume it was
reconciled *from*, not a build product.

`make install` is deliberately opt-in and requires `CARD=`: it overwrites, and
overwriting a volume the machine has written to loses whatever was written.

## The volume names are not arbitrary

The IO Controller auto-mounts **`/CPM/CPM_1.DRV` as unit 0** and
**`/CPM/CPM_2.DRV` as unit 1**. That convention lives in `default_image[]` in
`../../MCU/IOController/src/volume.c`, and these filenames match it exactly.

Rename either side and they stop agreeing: the controller finds no image, falls
back to raw card addressing, and the volumes are simply not there — with nothing
on the console to say why. `VOLINFO` reports which mode is actually live, so you
never have to infer it.

## How this tree was seeded

`disk1/` and `disk2/` were reconciled from **two sources that had drifted
apart**: the live 8 MiB volume, and the old `CPM2.2/images/A` staging tree.

They disagreed in three ways:

- **Files only on the machine** — `prime.com`, `prime.mcd`, `test.mod`,
  `v9958.lib`, `v9958.sym`, `read.me`, `zde10.doc`, `mandel.com`, `badappl.*`.
  Several are compiler output and work files created *on* Zephyr-80; they
  existed nowhere else.
- **Files only in staging** — `hello.mod`, `parser1.mod`, `wsprint.tst`,
  `song.vgm`, `song.zvg`.
- **Files in both, with different contents** — `turbo.com`, `m2.com`,
  `dbase.com`, `sc2.com`, `wsu.com`, `zde16.com`, and others.

**The machine's copy won every content conflict.** Those programs were
configured by their own installers (TINST, INSTALL) *on the machine*, so the
volume held the working build and staging held the pristine original. Files
present in only one source were kept from wherever they were found.

The result was verified file-by-file: of the 136 distinct names across both
sources, **nothing is unaccounted for**.

### Two things deliberately excluded

**Machine utilities.** `PING`, `SDREC`, `MONITOR` and the rest were checked in
here as stale binaries. They are built from source by `../Utilities` and
`../Monitor` now, so carrying copies would drift — which is exactly what had
already happened to `NOWRAP.com` and `WRAPON.COM`, shipped on the ROM as
binaries whose sources had moved on without them.

**`test.$$$`** — a CP/M scratch file.

### cpmtools cannot read what it writes

The volumes are built by `tools/mkcpmimage.py`, not `mkfs.cpm`/`cpmcp`.

cpmtools writes this format correctly and then **aborts reading its own
output** — `malloc(): invalid size (unsorted)` while scanning the directory.
The first copy into a fresh volume succeeds; every pass after it dies. Dumping
the directory after a "failing" write shows a textbook entry and a byte-exact
payload, so the volume is fine and the reader is not. The trigger is
filename-dependent and deterministic: `MANDEL.BAS` provokes it, `SMILEY.COM`
does not — which is not a distinction the on-disk format makes.

Since a multi-file volume needs more than one pass, that ruled cpmtools out for
writing. `mkcpmimage.py` builds the whole volume in one pass and verifies it by
reading its own output back, so a bad image fails the build. Its output was
cross-checked against a cpmtools-built volume: `cpmls` lists the two
identically, file for file, and extracted payloads match byte for byte.

### One recovery worth knowing about

The volume held two separate files called `MANDELV5.` and `MANDELV5.COM` — the
first with no extension at all. `cpmcp` silently extracted only one of them; the
other had to be pulled out by exact name. If you ever bulk-extract a CP/M volume,
**check the file count**, because that failure is quiet.

## Adding software

Drop files into `disk1/<user>/` or `disk2/<user>/` and run `make`. Filenames are
normalised lower case here; CP/M stores them upper case, and the ROM disk
builder matches case-insensitively.

`../CPM2.2` also reads `disk1/0` and `disk1/1` directly, as the source of the
stock DRI tools (`PIP`, `STAT`, `ZSID`, `DUMP`) it puts on the ROM A: volume.
Moving those four files will break the ROM build, which will tell you so by name.
