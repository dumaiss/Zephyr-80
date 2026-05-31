# Zephyr-80 VDrip Disk

This note documents the current CP/M drive A format used by the VDrip storage
backend. It describes the active proxy-backed disk, not the inactive banked RAM
disk backend preserved in `src/cbios_storage_ramdisk.asm`.

## Active Disk

Drive A is a flat proxy-side image. The BIOS maps CP/M disk operations to
128-byte logical block addresses and sends those records over the Virtual Drip
storage protocol.

Current capacity:

```text
8,388,608 bytes
65,536 records
128 bytes per record
```

The BIOS accepts LBAs `0..65535`. The proxy should reject out-of-range access,
short reads/writes, unsupported drive numbers, and host I/O errors.

## cpmtools Disk Definition

The current `images/diskdef` entry is:

```text
diskdef zephyr80-vdrip
  seclen 128
  tracks 16384
  sectrk 4
  blocksize 4096
  maxdir 512
  skew 0
  boottrk 0
  os 2.2
end
```

Useful commands:

```sh
mkfs.cpm -f zephyr80-vdrip zephyr80-vdrip.cpm
cpmls -f zephyr80-vdrip zephyr80-vdrip.cpm
```

The image size should be:

```text
16384 tracks * 4 sectors/track * 128 bytes/sector = 8388608 bytes
```

## BIOS DPB

The active BIOS DPB is emitted by `src/cbios_storage_vdrip.asm` from constants
in `src/cbios_defs.inc`.

| DPB field | Current value | Meaning |
|---|---:|---|
| `SPT` | `0004h` | 4 logical 128-byte sectors per track |
| `BSH` | `05h` | 4096-byte allocation block shift |
| `BLM` | `1Fh` | 32 records per allocation block minus 1 |
| `EXM` | `01h` | Extent mask for CP/M 2.2 |
| `DSM` | `07FFh` | Highest allocation block number, 2048 blocks total |
| `DRM` | `01FFh` | Highest directory entry number, 512 entries total |
| `AL0` | `F0h` | Directory allocation bitmap high byte |
| `AL1` | `00h` | Directory allocation bitmap low byte |
| `CKS` | `0000h` | Fixed-disk behavior, no check vector |
| `OFF` | `0000h` | No reserved boot tracks |

Derived values:

```text
records per allocation block = 2^BSH = 32
allocation block bytes       = 32 * 128 = 4096
allocation blocks            = DSM + 1 = 2048
directory entries            = DRM + 1 = 512
directory bytes              = 512 * 32 = 16384
directory allocation blocks  = 16384 / 4096 = 4
AL0/AL1                      = F0 00, first four allocation blocks reserved
```

## DPH and Scratch Buffers

The drive A DPH points at:

| Object | Purpose |
|---|---|
| `VDRIP_STORAGE_DIRBUF` | CP/M directory scratch buffer |
| `VDRIP_STORAGE_DPB` | Drive A geometry |
| `VDRIP_STORAGE_CSV` | Zero-length fixed-disk check vector label |
| `VDRIP_STORAGE_ALV` | Allocation vector |

The DPH/DPB live at `VDRIP_STORAGE_DPHDPB_BASE`, separate from
`MOVE_BUFFER`. This is intentional: BDOS re-reads the DPH/DPB during disk login,
so transaction scratch must not overwrite those constants.

## LBA Mapping

The BIOS stores CP/M track and sector through `SETTRK` and `SETSEC`.

VDrip storage computes:

```text
LBA = track * VDRIP_STORAGE_SECTORS_PER_TRACK + sector
LBA = track * 4 + sector
```

Validation before a transaction:

```text
selected drive must be 0
track must be less than 4000h
sector high byte must be 0
sector must be less than 4
```

The computed 16-bit LBA is sent as a 32-bit little-endian payload field with
the high two bytes set to zero.

## CP/M Call Flow

A typical BDOS read path looks like:

```text
SELDSK A:
SETTRK track
SETSEC sector
SETDMA buffer
SETBNK bank, if using banked DMA
READ
```

The storage facade preserves caller registers around the backend and runs the
backend on the BIOS-owned stack. The backend copies between caller DMA and
`MOVE_BUFFER` while temporarily selecting the requested DMA bank, then restores
the previous bank.

## Active VDrip Disk vs Inactive RAM Disk

The active VDrip disk is:

```text
proxy-backed flat image
8 MiB
65536 records
4 sectors/track
4096-byte allocation blocks
```

The inactive legacy RAM disk source is:

```text
RAM banks 2-7
294912 bytes
0900h records
48 sectors/track
2048-byte allocation blocks
```

Those two geometries are deliberately different. Do not mix `RAMDISK_*`
constants into the active VDrip storage path.
