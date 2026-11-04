"""FAT card images for the card tests, independent of the emulator.

`mkfs.fat` formats an image (FAT16 or FAT32, optionally inside an MBR
partition).  `Volume` then writes 8.3 files and directories into it with its
own FAT code (contiguous or deliberately fragmented chains) and reads a
volume's whole tree back, so what the emulator's FatFs wrote is checked by a
second implementation.  `fsck` runs `fsck.fat -n` on the result."""
from pathlib import Path
import shutil
import struct
import subprocess

SECTOR = 512
MKFS = shutil.which("mkfs.fat") or "/usr/sbin/mkfs.fat"
FSCK = shutil.which("fsck.fat") or "/usr/sbin/fsck.fat"


def pack83(name):
    """'NAME.EXT' to the 11-byte on-card short name (upper case)."""
    base, _, ext = name.upper().partition(".")
    assert 0 < len(base) <= 8 and len(ext) <= 3, name
    return (base.ljust(8) + ext.ljust(3)).encode("ascii")


def unpack83(raw):
    base, ext = raw[:8].decode("latin-1").rstrip(), raw[8:11].decode("latin-1").rstrip()
    return base + ("." + ext if ext else "")


def make_image(path, mib, fat, cluster_sectors=None, partition=False, label="ZEPHYR80"):
    """A new image of `mib` MiB formatted FAT`fat` (superfloppy, or in MBR partition 1 at 2048)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    size = mib << 20
    with open(path, "wb") as f:
        f.truncate(size)
    args = [MKFS, "-F", str(fat), "-n", label, "-i", "5a455031"]
    if cluster_sectors:
        args += ["-s", str(cluster_sectors)]
    if partition:
        start = 2048
        args += ["-h", str(start), "--offset", str(start), str(path), str((size - start * SECTOR) // 1024)]
    else:
        args += [str(path)]
    subprocess.run(args, check=True, capture_output=True, text=True)
    if partition:
        with open(path, "r+b") as f:
            mbr = bytearray(SECTOR)
            entry = struct.pack("<B3sB3sII", 0, b"\0\0\0", 0x0c if fat == 32 else 0x06, b"\0\0\0", start, size // SECTOR - start)
            mbr[446:462] = entry
            mbr[510:512] = b"\x55\xaa"
            f.write(mbr)
    return path


def fsck(path):
    """fsck.fat -n on a superfloppy image; returns (ok, output)."""
    result = subprocess.run([FSCK, "-n", str(path)], capture_output=True, text=True)
    return result.returncode == 0, result.stdout + result.stderr


class Volume:
    def __init__(self, path, write=False):
        self.f = open(path, "r+b" if write else "rb")
        boot = self.read(0)
        self.base = 0
        if not self.looks_like_bpb(boot):
            start = struct.unpack_from("<I", boot, 446 + 8)[0]
            self.base = start
            boot = self.read(start)
            assert self.looks_like_bpb(boot), "no FAT volume"
        (bps, self.spc, rsvd, self.nfats, root_ent, tot16, _, fatsz16) = struct.unpack_from("<HBHBHHBH", boot, 11)
        tot32, = struct.unpack_from("<I", boot, 32)
        fatsz32, = struct.unpack_from("<I", boot, 36)
        root_clus, = struct.unpack_from("<I", boot, 44)
        self.fatsz = fatsz16 or fatsz32
        total = tot16 or tot32
        self.fat_lba = self.base + rsvd
        self.root_sectors = (root_ent * 32 + SECTOR - 1) // SECTOR
        self.root_lba = self.fat_lba + self.nfats * self.fatsz
        self.data_lba = self.root_lba + self.root_sectors
        self.clusters = (total - (self.data_lba - self.base)) // self.spc
        self.fat32 = self.clusters >= 65525
        self.root_clus = root_clus if self.fat32 else 0
        self.fsinfo = self.base + struct.unpack_from("<H", boot, 48)[0] if self.fat32 else None
        self.fat = bytearray(self.read(self.fat_lba, self.fatsz))

    @staticmethod
    def looks_like_bpb(boot):
        bps, spc, rsvd, nfats = struct.unpack_from("<HBHB", boot, 11)
        return bps == SECTOR and spc and not spc & (spc - 1) and rsvd and nfats in (1, 2)

    def close(self):
        self.f.close()

    def read(self, lba, count=1):
        self.f.seek(lba * SECTOR)
        return self.f.read(count * SECTOR)

    def write(self, lba, data):
        self.f.seek(lba * SECTOR)
        self.f.write(data)

    def lba(self, cluster):
        return self.data_lba + (cluster - 2) * self.spc

    # FAT ---------------------------------------------------------------------

    def get(self, cluster):
        width = 4 if self.fat32 else 2
        value = int.from_bytes(self.fat[cluster * width:cluster * width + width], "little")
        return value & 0x0fffffff if self.fat32 else value

    def set(self, cluster, value):
        """One entry, written through to every FAT copy."""
        width = 4 if self.fat32 else 2
        off = cluster * width
        self.fat[off:off + width] = value.to_bytes(width, "little")
        sector = off // SECTOR
        for copy in range(self.nfats):
            self.write(self.fat_lba + copy * self.fatsz + sector, bytes(self.fat[sector * SECTOR:(sector + 1) * SECTOR]))

    def end(self, value):
        return value >= (0x0ffffff8 if self.fat32 else 0xfff8)

    def chain(self, cluster):
        out = []
        while 2 <= cluster < self.clusters + 2:
            out.append(cluster)
            cluster = self.get(cluster)
            assert len(out) <= self.clusters, "circular chain"
        return out

    def allocate(self, count, runs=1):
        """`count` free clusters linked; with `runs` > 1 one free cluster is skipped after each
        run of count/runs, so the chain has at least that many extents."""
        per_run = -(-count // runs)
        picked, in_run = [], 0
        for cluster in range(2, self.clusters + 2):
            if self.get(cluster):
                continue
            if runs > 1 and in_run == per_run:
                in_run = 0
                continue
            picked.append(cluster)
            in_run += 1
            if len(picked) == count:
                break
        assert len(picked) == count, "volume full"
        for a, b in zip(picked, picked[1:]):
            self.set(a, b)
        self.set(picked[-1], 0x0fffffff if self.fat32 else 0xffff)
        self.forget_free_count()
        return picked

    def forget_free_count(self):
        if self.fsinfo is not None:
            sector = bytearray(self.read(self.fsinfo))
            sector[488:496] = b"\xff" * 8
            self.write(self.fsinfo, bytes(sector))

    # Directories -------------------------------------------------------------

    def dir_sectors(self, cluster):
        if cluster == 0 and not self.fat32:
            return list(range(self.root_lba, self.root_lba + self.root_sectors))
        return [self.lba(c) + i for c in self.chain(cluster or self.root_clus) for i in range(self.spc)]

    def entries(self, cluster):
        for lba in self.dir_sectors(cluster):
            sector = self.read(lba)
            for i in range(0, SECTOR, 32):
                e = sector[i:i + 32]
                if e[0] == 0:
                    return
                yield lba, i, e

    def listing(self, cluster):
        """(name, attr, first cluster, size) of every live short entry, '.'/'..' skipped."""
        out = []
        for _, _, e in self.entries(cluster):
            attr = e[11]
            if e[0] == 0xe5 or attr & 0x0f == 0x0f or attr & 0x08 or e[0] == 0x2e:
                continue
            first = (struct.unpack_from("<H", e, 20)[0] << 16 if self.fat32 else 0) | struct.unpack_from("<H", e, 26)[0]
            out.append((unpack83(e[:11]), attr, first, struct.unpack_from("<I", e, 28)[0]))
        return out

    def lookup(self, path):
        """(attr, first cluster, size) of an absolute path; the root is (0x10, 0, 0)."""
        found = (0x10, 0, 0)
        for part in [p for p in path.split("/") if p]:
            assert found[0] & 0x10, path
            match = [x for x in self.listing(found[1]) if x[0] == part.upper()]
            if not match:
                return None
            found = match[0][1:]
        return found

    def free_slot(self, cluster):
        for lba in self.dir_sectors(cluster):
            sector = self.read(lba)
            for i in range(0, SECTOR, 32):
                if sector[i] in (0, 0xe5):
                    return lba, i
        assert cluster or self.fat32, "root directory full"
        new = self.allocate(1)[0]
        self.set(self.chain(cluster or self.root_clus)[-1], new)
        self.set(new, 0x0fffffff if self.fat32 else 0xffff)
        for i in range(self.spc):
            self.write(self.lba(new) + i, bytes(SECTOR))
        return self.lba(new), 0

    def add_entry(self, parent, name, attr, first, size):
        lba, offset = self.free_slot(parent)
        sector = bytearray(self.read(lba))
        e = pack83(name) + bytes([attr]) + bytes(8) + struct.pack("<H", first >> 16 if self.fat32 else 0) + \
            bytes(4) + struct.pack("<HI", first & 0xffff, size)
        sector[offset:offset + 32] = e
        self.write(lba, bytes(sector))

    def parent_of(self, path):
        head, _, name = path.rstrip("/").rpartition("/")
        parent = self.lookup(head or "/")
        assert parent and parent[0] & 0x10, path
        return parent[1], name

    def mkdir(self, path):
        parent, name = self.parent_of(path)
        cluster = self.allocate(1)[0]
        block = bytearray(self.spc * SECTOR)
        block[0:32] = b".          " + bytes([0x10]) + bytes(8) + struct.pack("<H", cluster >> 16) + bytes(4) + struct.pack("<HI", cluster & 0xffff, 0)
        up = parent  # 0 for the root
        block[32:64] = b"..         " + bytes([0x10]) + bytes(8) + struct.pack("<H", up >> 16) + bytes(4) + struct.pack("<HI", up & 0xffff, 0)
        for i in range(self.spc):
            self.write(self.lba(cluster) + i, bytes(block[i * SECTOR:(i + 1) * SECTOR]))
        self.add_entry(parent, name, 0x10, cluster, 0)

    def write_file(self, path, data, runs=1):
        parent, name = self.parent_of(path)
        cluster_bytes = self.spc * SECTOR
        first = 0
        if data:
            chain = self.allocate(-(-len(data) // cluster_bytes), runs)
            first = chain[0]
            for i, c in enumerate(chain):
                chunk = data[i * cluster_bytes:(i + 1) * cluster_bytes].ljust(cluster_bytes, b"\0")
                self.write(self.lba(c), chunk)
        self.add_entry(parent, name, 0x20, first, len(data))

    # Reading -----------------------------------------------------------------

    def read_file(self, first, size):
        out = bytearray()
        for c in self.chain(first):
            out += self.read(self.lba(c), self.spc)
        assert len(out) >= size, "chain shorter than the file"
        return bytes(out[:size])

    def extents(self, path):
        """(first card block, blocks) runs of a file's chain."""
        _, first, _ = self.lookup(path)
        runs = []
        for c in self.chain(first):
            if runs and runs[-1][0] + runs[-1][1] == self.lba(c):
                runs[-1][1] += self.spc
            else:
                runs.append([self.lba(c), self.spc])
        return [tuple(r) for r in runs]

    def tree(self, cluster=0, prefix=""):
        """{'/PATH': bytes, '/DIR/': None} for the whole volume."""
        out = {}
        for name, attr, first, size in self.listing(cluster):
            path = prefix + "/" + name
            if attr & 0x10:
                out[path + "/"] = None
                out.update(self.tree(first, path))
            else:
                out[path] = self.read_file(first, size)
        return out


def folder_tree(root, prefix=""):
    """The same map for a host folder: every regular file and directory, names as stored."""
    out = {}
    for entry in sorted(Path(root).iterdir()):
        if entry.is_symlink():
            continue
        path = prefix + "/" + entry.name
        if entry.is_dir():
            out[path + "/"] = None
            out.update(folder_tree(entry, path))
        elif entry.is_file():
            out[path] = entry.read_bytes()
    return out
