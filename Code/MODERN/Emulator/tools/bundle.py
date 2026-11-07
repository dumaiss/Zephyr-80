#!/usr/bin/env python3
"""Pack the Zephyr-80 emulator bundle: one archive that runs KonaOS on the
`zephyr80` machine with no MAME source tree and no build.

    python3 tools/bundle.py --mame mame/mamepbitz --konaos-root /path/to/ZephyrOS

The archive holds the release `mamepbitz` (stripped) with the shared libraries
it loads, the glibc loader among them, so that it starts on a host whose glibc
is older than the build host's; the `konaos` and `json` plugins; the KonaOS
flash image and its map; a starter card folder; a launch script; the user
documentation; and `MANIFEST.json` with the source revision, size and SHA-256
of every file.  The result is deterministic for the same inputs: member order,
owners and times are fixed (the time is the KonaOS checkout's HEAD commit).

Layout of the archive's one top directory:

    start.sh        boots KonaOS with the starter card
    mamepbitz       runs libexec/mamepbitz on the bundled libraries
    konaos.bin  konaos.map  card/  ini/  plugins/  docs/  qt-plugins/
    lib/  libexec/  MANIFEST.json  README.txt  COPYING  LICENSES.txt

Host requirements are in docs/bundle.md.  This builds nothing: the MAME binary,
the image and the card programs are existing build outputs, named on the
command line or found in the checkouts.
"""

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
EMULATOR = HERE.parent
ZEPHYR_ROOT = EMULATOR.parents[2]
NAME = "zephyr80-mame"
ARCHIVE = NAME + "-linux-x86_64.tar.xz"

# Bundle docs: the guide and the documents it links to.
DOCS = ("bundle.md", "zephyr80-debugging.md", "zephyr80-card.md", "zephyr80-input.md",
        "zephyr80-keyboard.md", "zephyr80-sound.md", "zephyr80-video.md",
        "zephyr80-sio1-ioc.md", "zephyr80-device-model.md")

# The Qt platform plugins the debugger window needs: the X11 one, and the
# offscreen one for runs without a display.
QT_PLUGINS = ("platforms/libqxcb.so", "platforms/libqoffscreen.so")

# MAME plugins the bundle runs: the library `json` and `konaos` itself, with
# the loader files MAME reads from the plugins directory.
MAME_PLUGINS = ("boot.lua", "plugin.schema", "json", "konaos")

# The starter card: (checkout, path, 8.3 name).
CARD_PROGRAMS = (
    ("konaos", "build/user/hello.exe", "HELLO.EXE"),
    ("konaos", "build/user/joy.exe", "JOY.EXE"),
    ("konaos", "build/user/mouse.exe", "MOUSE.EXE"),
    ("konaos", "build/user/sound.exe", "SOUND.EXE"),
    ("konaos", "build/user/gfx_mouse.exe", "GFXMOUSE.EXE"),
    ("konaos", "build/user/hwtest.exe", "HWTEST.EXE"),
    ("konaos", "UserSoftware/KonaEdit/build/user/kedit.exe", "KEDIT.EXE"),
    ("konaos", "UserSoftware/KonaCommander/build/user/kc.exe", "KC.EXE"),
    ("konaos", "UserSoftware/GfxDemo/build/user/gfxdemo.exe", "GFXDEMO.EXE"),
)
CARD_README = b"""This is the starter card. KonaOS mounts it as /fs.\r
\r
  /fs/HELLO.EXE     the smallest program\r
  /fs/KEDIT.EXE     KonaEdit, the text editor\r
  /fs/KC.EXE        KonaCommander, the file manager\r
  /fs/JOY.EXE       reads the two gamepads\r
  /fs/MOUSE.EXE     reads the mouse\r
  /fs/SOUND.EXE     plays a tone on the sound card\r
  /fs/GFXMOUSE.EXE  the mouse pointer on the V9958 screen\r
  /fs/GFXDEMO.EXE   graphics demo\r
  /fs/HWTEST.EXE    the hardware self-test (writes this card)\r
\r
Run one at the prompt, for example: /fs/KEDIT.EXE README.TXT\r
Anything you copy into this folder with an 8.3 name is on the card.\r
"""

WRAPPER = """#!/bin/sh
# MAME for the Zephyr-80 machine, on the libraries in this bundle.
self=$(readlink -f -- "$0") || exit 1
here=${self%/*}
ZEPHYR80_BUNDLE=$here
ZEPHYR80_STATE=${ZEPHYR80_STATE:-${XDG_STATE_HOME:-${HOME:-$here}/.local/state}/zephyr80-mame}
QT_PLUGIN_PATH=$here/qt-plugins
QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
export ZEPHYR80_BUNDLE ZEPHYR80_STATE QT_PLUGIN_PATH QT_QPA_PLATFORM
exec "$here/lib/ld-linux-x86-64.so.2" --library-path "$here/lib" --argv0 "$self" \\
    "$here/libexec/mamepbitz" -inipath "$here/ini" "$@"
"""

START = """#!/bin/sh
here=$(dirname -- "$(readlink -f -- "$0")")
exec "$here/mamepbitz" zephyr80 -flash "$here/konaos.bin" -carddir "$here/card" "$@"
"""

MAME_INI = """# Settings of the Zephyr-80 emulator bundle. The wrapper sets the two variables.
pluginspath               $ZEPHYR80_BUNDLE/plugins
cfg_directory             $ZEPHYR80_STATE/cfg
nvram_directory           $ZEPHYR80_STATE/nvram
state_directory           $ZEPHYR80_STATE/sta
snapshot_directory        $ZEPHYR80_STATE/snap
diff_directory            $ZEPHYR80_STATE/diff
comment_directory         $ZEPHYR80_STATE/comments
input_directory           $ZEPHYR80_STATE/inp
skip_gameinfo             1
"""

README = """Zephyr-80 emulator bundle (KonaOS on MAME)

  ./start.sh                         boots KonaOS with the card in card/
  ./mamepbitz zephyr80 -flash F ...  MAME with your own options

Needs a 64-bit Linux on x86-64 with a desktop (X11 or XWayland), a kernel from
3.2 on, and the graphics and sound stack of the host (OpenGL drivers, ALSA or
PulseAudio). Everything else is in this folder; it can be moved anywhere,
including a path with spaces. docs/bundle.md describes the keyboard, the
Scroll Lock key, cards, gamepads, the debugger and the KonaOS SDK's make run.
MANIFEST.json lists every file with its source revision and SHA-256.
"""

LICENSES = """The emulator is MAME (GPL-2.0-or-later, with BSD-3-Clause and other permissive
files; the text of the GPL is in COPYING). The machine, the konaos plugin and
the launch files are the Zephyr-80 project's. The source of the binary is the
mame checkout named in MANIFEST.json (revision under revisions.mame).

lib/ holds unmodified shared libraries of the build host's distribution (the
package and version of each are in MANIFEST.json), under their own licenses:
the GNU C Library and libstdc++ (LGPL-2.1+ and GPL-3.0 with the runtime
exception), Qt 6 (LGPL-3.0), SDL2 and SDL2_ttf (zlib), and the X11, ALSA,
PulseAudio, FreeType, ICU and other libraries named there. Their sources are
the distribution's source packages of those versions.
"""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def revision(path):
    """The checkout's HEAD and its changed files, or None outside a checkout."""
    try:
        head = run("git", "-C", str(path), "rev-parse", "HEAD").strip()
        status = run("git", "-C", str(path), "status", "--porcelain").splitlines()
        stamp = int(run("git", "-C", str(path), "log", "-1", "--format=%ct").strip())
    except (OSError, subprocess.CalledProcessError):
        return None
    return {"head": head, "changed": status, "commit_time": stamp}


def changed(repo, path):
    """Whether a file differs from its checkout's HEAD (tracked and modified, or untracked)."""
    try:
        return bool(run("git", "-C", str(repo), "status", "--porcelain", "--", str(path)).strip())
    except (OSError, subprocess.CalledProcessError):
        return None


class Stage:
    """The files of the bundle, in memory with their metadata, written in order."""

    def __init__(self):
        self.files = {}   # archive path -> dict(data, mode, source)

    def add(self, path, data, mode=0o644, source=None):
        if path in self.files:
            raise SystemExit("bundle.py: %s is added twice" % path)
        self.files[path] = {"data": data, "mode": mode, "source": source or {}}

    def add_file(self, path, src, mode=None, source=None):
        src = Path(src)
        if mode is None:
            mode = 0o755 if os.access(src, os.X_OK) else 0o644
        self.add(path, src.read_bytes(), mode, source)

    def add_tree(self, prefix, src, source=None, skip=()):
        src = Path(src)
        for item in sorted(src.rglob("*")):
            if item.is_file() and not any(part in skip for part in item.relative_to(src).parts):
                self.add("%s/%s" % (prefix, item.relative_to(src).as_posix()), item.read_bytes(),
                         0o644, dict(source or {}, path=str(item)))


def ldd(path, env=None):
    """{soname: path} of what the host loader resolves for `path`, and the interpreter."""
    out = run("ldd", str(path), env=env)
    libs, interpreter = {}, None
    for line in out.splitlines():
        line = line.strip()
        m = re.match(r"(\S+) => (/\S+) \(", line)
        if m:
            libs[m.group(1)] = m.group(2)
            continue
        m = re.match(r"(/\S+) \(", line)
        if m:
            interpreter = m.group(1)
        elif "=> not found" in line:
            raise SystemExit("bundle.py: %s needs %s" % (path, line.split()[0]))
    return libs, interpreter


def package_of(path):
    """(package, version) of the distribution package owning a file, or (None, None)."""
    try:
        real = os.path.realpath(path)
        owner = run("dpkg-query", "-S", real).split(": ", 1)[0].strip()   # "package:arch"
        version = run("dpkg-query", "-W", "-f=${Version}", owner).strip()
        return owner, version
    except (OSError, subprocess.CalledProcessError):
        return None, None


def glibc_requirements(binary):
    """The highest GLIBC_x.y and GLIBCXX_x.y.z versions the binary's symbols name."""
    out = run("objdump", "-T", str(binary))
    def newest(prefix):
        found = set(re.findall(prefix + r"_([0-9.]+)", out))
        return max(found, key=lambda v: tuple(int(p) for p in v.split("."))) if found else None
    return {"glibc": newest("GLIBC"), "glibcxx": newest("GLIBCXX")}


def qt_plugin_dir(libs):
    core = libs.get("libQt6Core.so.6")
    if not core:
        raise SystemExit("bundle.py: the MAME binary is not linked to Qt; the bundle's debugger needs it")
    base = Path(os.path.realpath(core)).parent
    for candidate in (base / "qt6/plugins", base.parent / "qt6/plugins"):
        if candidate.is_dir():
            return candidate
    raise SystemExit("bundle.py: Qt's plugin directory is not under %s" % base)


def add_libraries(stage, binary):
    """lib/: the closure of the binary and the Qt plugins; returns the info for the manifest."""
    libs, interpreter = ldd(binary)
    qt = qt_plugin_dir(libs)
    plugin_files = {}
    for plugin in QT_PLUGINS:
        path = qt / plugin
        if not path.is_file():
            raise SystemExit("bundle.py: Qt plugin %s is missing" % path)
        plugin_files[plugin] = path
        more, _ = ldd(path)
        for soname, where in more.items():
            libs.setdefault(soname, where)
    if not interpreter:
        raise SystemExit("bundle.py: no ELF interpreter for %s" % binary)
    libs[os.path.basename(interpreter)] = interpreter
    for soname, where in sorted(libs.items()):
        if soname.startswith("linux-vdso"):
            continue
        package, version = package_of(where)
        stage.add("lib/" + soname, Path(os.path.realpath(where)).read_bytes(), 0o755,
                  {"origin": os.path.realpath(where), "package": package, "version": version})
    for plugin, path in plugin_files.items():
        package, version = package_of(path)
        stage.add("qt-plugins/" + plugin, path.read_bytes(), 0o755,
                  {"origin": str(path), "package": package, "version": version})
    return {"qt_plugins": str(qt)}


def starter_card(stage, roots):
    for repo, relative, name in CARD_PROGRAMS:
        if not re.fullmatch(r"[A-Z0-9_]{1,8}\.[A-Z0-9_]{1,3}", name):
            raise SystemExit("bundle.py: %s is not an 8.3 name" % name)
        path = roots[repo] / relative
        if not path.is_file():
            raise SystemExit("bundle.py: %s is missing; build it in the %s checkout" % (path, repo))
        stage.add_file("card/" + name, path, 0o644,
                       {"repo": repo, "path": relative, "changed": changed(roots[repo], relative)})
    stage.add("card/README.TXT", CARD_README, 0o644, {"repo": "emulator", "path": "tools/bundle.py"})


def write_archive(stage, out, stamp):
    """A deterministic xz tarball: sorted members, root-owned, fixed time."""
    members = sorted(stage.files)
    directories = sorted({str(Path(m).parent) for m in members if str(Path(m).parent) != "."} |
                         {str(p) for m in members for p in Path(m).parents if str(p) != "."})
    with tarfile.open(out, "w:xz", preset=6, format=tarfile.PAX_FORMAT) as tar:
        def common(info, mode):
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = stamp
            info.mode = mode
            return info
        top = tarfile.TarInfo(NAME)
        top.type = tarfile.DIRTYPE
        tar.addfile(common(top, 0o755))
        for d in directories:
            info = tarfile.TarInfo("%s/%s" % (NAME, d))
            info.type = tarfile.DIRTYPE
            tar.addfile(common(info, 0o755))
        for m in members:
            info = tarfile.TarInfo("%s/%s" % (NAME, m))
            data = stage.files[m]["data"]
            info.size = len(data)
            tar.addfile(common(info, stage.files[m]["mode"]), io.BytesIO(data))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--mame", type=Path, required=True, help="the release mamepbitz binary")
    parser.add_argument("--konaos-root", type=Path, required=True, help="the ZephyrOS checkout (image, map, card programs)")
    parser.add_argument("--zephyr-root", type=Path, default=ZEPHYR_ROOT, help="the Zephyr-80 checkout (default: this one)")
    parser.add_argument("--output", type=Path, default=EMULATOR / "tests/output/bundle",
                        help="directory for the archive (default tests/output/bundle, ignored by Git)")
    args = parser.parse_args(argv)

    mame = args.mame.resolve()
    konaos = args.konaos_root.resolve()
    zephyr = args.zephyr_root.resolve()
    emulator = zephyr / "Code/MODERN/Emulator"
    mame_tree = emulator / "mame"
    for path, what in ((mame, "the MAME binary"), (konaos / "build/konaos.bin", "the KonaOS image"),
                       (konaos / "build/konaos.map", "its map"), (mame_tree / "COPYING", "MAME's COPYING")):
        if not path.is_file():
            raise SystemExit("bundle.py: %s %s is missing" % (what, path))
    roots = {"konaos": konaos, "zephyr": zephyr, "mame": mame_tree, "emulator": zephyr}
    revisions = {"konaos": revision(konaos), "zephyr": revision(zephyr), "mame": revision(mame_tree)}
    if not all(revisions.values()):
        raise SystemExit("bundle.py: the three checkouts must be git working trees")
    stamp = revisions["konaos"]["commit_time"]

    stage = Stage()
    binary = mame.read_bytes()
    with tempfile.TemporaryDirectory() as tmp:
        stripped = Path(tmp) / "mamepbitz"
        run("strip", "-o", str(stripped), str(mame))
        stage.add("libexec/mamepbitz", stripped.read_bytes(), 0o755,
                  {"repo": "mame", "built_from": "src/mame/pbitz", "unstripped_sha256": sha256(binary),
                   "unstripped_bytes": len(binary)})
        requirements = glibc_requirements(mame)
        library_info = add_libraries(stage, mame)

    stage.add("mamepbitz", WRAPPER.encode(), 0o755, {"repo": "emulator", "path": "tools/bundle.py"})
    stage.add("start.sh", START.encode(), 0o755, {"repo": "emulator", "path": "tools/bundle.py"})
    stage.add("ini/mame.ini", MAME_INI.encode(), 0o644, {"repo": "emulator", "path": "tools/bundle.py"})
    stage.add("README.txt", README.encode(), 0o644, {"repo": "emulator", "path": "tools/bundle.py"})
    stage.add("LICENSES.txt", LICENSES.encode(), 0o644, {"repo": "emulator", "path": "tools/bundle.py"})
    stage.add_file("COPYING", mame_tree / "COPYING", 0o644,
                   {"repo": "mame", "path": "COPYING", "changed": changed(mame_tree, "COPYING")})
    stage.add_file("konaos.bin", konaos / "build/konaos.bin", 0o644,
                   {"repo": "konaos", "built_from": "make build/konaos.bin", "tree_changed": bool(revisions["konaos"]["changed"])})
    stage.add_file("konaos.map", konaos / "build/konaos.map", 0o644,
                   {"repo": "konaos", "built_from": "make build/konaos.bin", "tree_changed": bool(revisions["konaos"]["changed"])})
    for plugin in MAME_PLUGINS:
        source = mame_tree / "plugins" / plugin
        if source.is_dir():
            stage.add_tree("plugins/" + plugin, source, {"repo": "mame", "changed": changed(mame_tree, source)})
        elif source.is_file():
            stage.add_file("plugins/" + plugin, source, 0o644,
                           {"repo": "mame", "path": "plugins/" + plugin, "changed": changed(mame_tree, source)})
        else:
            raise SystemExit("bundle.py: plugin %s is missing" % source)
    for doc in DOCS:
        source = emulator / "docs" / doc
        if not source.is_file():
            raise SystemExit("bundle.py: %s is missing" % source)
        stage.add_file("docs/" + doc, source, 0o644,
                       {"repo": "zephyr", "path": "Code/MODERN/Emulator/docs/" + doc, "changed": changed(zephyr, source)})
    starter_card(stage, roots)

    manifest = {
        "bundle": NAME,
        "architecture": "linux-x86_64",
        "revisions": revisions,
        "host_requirements": {
            "build_host_glibc": run("ldd", "--version").splitlines()[0],
            "binary_needs": requirements,
            "bundled": "the glibc loader, libc, libm, libstdc++ and the other libraries in lib/ run the binary; "
                       "the host supplies the kernel, X11 or XWayland, the OpenGL and sound stack (drivers, servers)",
        },
        "libraries": library_info,
        "files": {path: {"bytes": len(f["data"]), "sha256": sha256(f["data"]), "mode": oct(f["mode"]), **f["source"]}
                  for path, f in sorted(stage.files.items())},
    }
    stage.add("MANIFEST.json", (json.dumps(manifest, indent=1) + "\n").encode(), 0o644)

    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / ARCHIVE
    partial = archive.with_suffix(".part")
    write_archive(stage, partial, stamp)
    partial.replace(archive)
    data = archive.read_bytes()
    print("archive   %s" % archive)
    print("size      %d bytes" % len(data))
    print("sha256    %s" % sha256(data))
    print("files     %d (binary %s stripped from %s)" % (len(stage.files), len(stage.files["libexec/mamepbitz"]["data"]),
                                                       sha256(binary)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
