#!/usr/bin/env python3
"""Build SNTRACK.COM with the FTL Modula-2 tools under RunCPM.

The library is not rebuilt here: Zephyr80Lib publishes native FTL .REL and .SYM
files under its BUILD/FTL, and those are staged alongside SNTRACK.MOD.  Run
`make` in Zephyr80Lib first, or use this project's Makefile, which does.
"""

import argparse
import importlib.machinery
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parent.parent

# The RunCPM driver and the FTL archive helpers live with the library build.
_LIB = PROJECT.parent / "Zephyr80Lib/TOOLS/FTLBUILD.PY"
_loader = importlib.machinery.SourceFileLoader("ftllib", str(_LIB))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
ftllib = importlib.util.module_from_spec(_spec)
_loader.exec_module(ftllib)

# Every native FTL object Zephyr80Lib publishes is staged, discovered rather
# than listed: a hardcoded list silently breaks the link when the library gains
# a module, and ML reports only "<name> not found" in the middle of a map.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ftl-dir", type=Path,
                        default=PROJECT.parent / "Software/disk1/5")
    parser.add_argument("--library", type=Path,
                        default=PROJECT.parent / "Zephyr80Lib/BUILD/FTL")
    parser.add_argument("--runcpm", type=Path,
                        default=PROJECT.parent / "Zephyr80Lib/TOOLS/RUNCPM")
    parser.add_argument("--ccp", type=Path,
                        default=PROJECT.parent / "Zephyr80Lib/TOOLS/CCP-ZCP3.60K")
    parser.add_argument("--output", type=Path, default=PROJECT / "BUILD")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="sntrack-ftl-") as temp:
        work = Path(temp)
        drive = work / "A/0"
        drive.mkdir(parents=True)
        # The distribution searches B: before A: for library modules.
        (work / "B/0").mkdir(parents=True)
        shutil.copyfile(args.ccp, work / "CCP-ZCP3.60K")
        for name in ("ASM.COM", "OPSASM.DAT", "MD.COM", "M2.COM", "M2OVL.OVR",
                     "ML.COM", "ERRMSG.DAT"):
            shutil.copyfile(args.ftl_dir / name, drive / name)
        for name in ("SYMFILES", "MODULA2"):
            ftllib.unpack_lbr(ftllib.unsqueeze(args.ftl_dir / (name + ".LQR")),
                              drive)
        objects = sorted(p for p in args.library.iterdir()
                         if p.suffix.upper() in (".REL", ".SYM"))
        if not objects:
            raise SystemExit("Zephyr80Lib has not been built: no .REL/.SYM in "
                             + str(args.library))
        for source in objects:
            shutil.copyfile(source, drive / source.name.upper())
        print("staged %d library objects" % len(objects), flush=True)
        ftllib.cpm_text(PROJECT / "SRC/SNTRACK.MOD", drive / "SNTRACK.MOD")

        cpm = ftllib.CPM(args.runcpm.resolve(), work)
        log = []
        try:
            cpm.expect(b"A0>")
            for command, success in (("M2 SNTRACK.MOD", "Compilation Complete"),
                                     ("ML SNTRACK", "link complete")):
                print(command, flush=True)
                result = ftllib.display(cpm.cpm(command))
                log.append(result)
                if success not in result or "Error(s)" in result \
                        or "errors in" in result:
                    raise RuntimeError(result)
        finally:
            cpm.close()
            (args.output / "BUILD.LOG").write_text("\n".join(log))
        shutil.copyfile(drive / "SNTRACK.COM", args.output / "SNTRACK.COM")
        print("Native FTL output: " + str(args.output))


if __name__ == "__main__":
    main()
