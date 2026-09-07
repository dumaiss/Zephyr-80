#include <string.h>

#include "fatmap.h"
#include "sd_card.h"
#include "sd_cache.h"

/* BPB field offsets, from the start of the volume's first sector. */
#define BPB_BytsPerSec   0x0Bu
#define BPB_SecPerClus   0x0Du
#define BPB_RsvdSecCnt   0x0Eu
#define BPB_NumFATs      0x10u
#define BPB_RootEntCnt   0x11u
#define BPB_TotSec16     0x13u
#define BPB_FATSz16      0x16u
#define BPB_TotSec32     0x20u
#define BPB_FATSz32      0x24u
#define BPB_RootClus     0x2Cu

/* MBR partition table. */
#define MBR_TABLE        446u
#define MBR_PTE_SIZE     16u
#define PTE_TYPE         4u
#define PTE_START_LBA    8u

/* Directory entry. */
#define DIR_ENTRY_SIZE   32u
#define DIR_NAME         0u
#define DIR_ATTR         11u
#define DIR_CLUS_HI      20u
#define DIR_CLUS_LO      26u
#define DIR_SIZE         28u

#define ATTR_READ_ONLY   0x01u
#define ATTR_VOLUME_ID   0x08u
#define ATTR_DIRECTORY   0x10u
#define ATTR_LFN         0x0Fu   /* an LFN fragment, never a real entry */

#define ENTRIES_PER_SEC  (SD_BLOCK_SIZE / DIR_ENTRY_SIZE)

/* Cached volume geometry.  Everything needed to turn a cluster number into an
 * LBA and to walk the FAT, and nothing else. */
typedef struct {
    bool     valid;
    bool     fat32;
    uint32_t fat_lba;         /* first FAT sector */
    uint32_t root_lba;        /* FAT16: first root-directory sector */
    uint32_t root_clus;       /* FAT32: root directory's first cluster */
    uint32_t data_lba;        /* sector of cluster 2 */
    uint32_t root_sectors;    /* FAT16: length of the fixed root region */
    uint16_t root_entries;    /* FAT16: how many entries that region holds */
    uint8_t  sec_per_clus;
} FatVol;

static FatVol vol;

void fatmap_invalidate(void) { vol.valid = false; }
bool fatmap_mounted(void)    { return vol.valid; }

/* ---------------------------------------------------------------------------
 * Small readers
 *
 * Every one goes through sd_cache, so a sector touched repeatedly -- and a
 * directory scan touches the same sector sixteen times -- costs one card read.
 * That is why nothing here needs a buffer of its own.
 * --------------------------------------------------------------------------- */

static bool rd(uint32_t lba, uint16_t off, uint16_t len, uint8_t *dst)
{
    return sd_cache_read_bytes(lba, off, len, dst) == SD_OK;
}

static bool rd16(uint32_t lba, uint16_t off, uint16_t *out)
{
    uint8_t b[2];

    if (!rd(lba, off, 2u, b))
        return false;

    *out = (uint16_t)b[0] | ((uint16_t)b[1] << 8);
    return true;
}

static bool rd32(uint32_t lba, uint16_t off, uint32_t *out)
{
    uint8_t b[4];

    if (!rd(lba, off, 4u, b))
        return false;

    *out =  (uint32_t)b[0]        | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    return true;
}

/* ---------------------------------------------------------------------------
 * Mounting
 * --------------------------------------------------------------------------- */

/* Does this sector look like a FAT BPB?
 *
 * Checked rather than assumed, because the alternative is the failure that
 * started all of this: a raw CP/M card's directory sector interpreted as a
 * partition table, sending reads to arbitrary LBAs past the end of the card
 * and killing the session the boot needed. */
static bool looks_like_bpb(uint32_t lba)
{
    uint16_t bps;
    uint16_t rsvd;
    uint8_t  spc;
    uint8_t  nfats;

    if (!rd16(lba, BPB_BytsPerSec, &bps))
        return false;
    if (!rd16(lba, BPB_RsvdSecCnt, &rsvd))
        return false;
    if (!rd(lba, BPB_SecPerClus, 1u, &spc))
        return false;
    if (!rd(lba, BPB_NumFATs, 1u, &nfats))
        return false;

    /* This driver moves 512-byte blocks and nothing else, so a volume with a
     * different sector size is refused here rather than mis-addressed later. */
    if (bps != SD_BLOCK_SIZE)
        return false;
    if ((spc == 0u) || ((spc & (uint8_t)(spc - 1u)) != 0u))
        return false;               /* must be a power of two */
    if (rsvd == 0u)
        return false;
    if ((nfats != 1u) && (nfats != 2u))
        return false;

    return true;
}

/* Read the BPB at `base` and fill the geometry. */
static FatMapStatus read_bpb(uint32_t base)
{
    uint16_t rsvd;
    uint16_t root_ent;
    uint16_t fatsz16;
    uint16_t totsec16;
    uint32_t fatsz;
    uint32_t totsec;
    uint32_t data_sectors;
    uint32_t clusters;
    uint8_t  nfats;

    if (!rd(base, BPB_SecPerClus, 1u, &vol.sec_per_clus)) return FATMAP_IO;
    if (!rd(base, BPB_NumFATs, 1u, &nfats))               return FATMAP_IO;
    if (!rd16(base, BPB_RsvdSecCnt, &rsvd))               return FATMAP_IO;
    if (!rd16(base, BPB_RootEntCnt, &root_ent))           return FATMAP_IO;
    if (!rd16(base, BPB_FATSz16, &fatsz16))               return FATMAP_IO;
    if (!rd16(base, BPB_TotSec16, &totsec16))             return FATMAP_IO;

    fatsz = fatsz16;
    if (fatsz == 0uL) {
        if (!rd32(base, BPB_FATSz32, &fatsz))             return FATMAP_IO;
    }

    totsec = totsec16;
    if (totsec == 0uL) {
        if (!rd32(base, BPB_TotSec32, &totsec))           return FATMAP_IO;
    }

    if ((fatsz == 0uL) || (totsec == 0uL))
        return FATMAP_NO_FS;

    /* The root directory is a fixed region on FAT16 and a cluster chain on
     * FAT32; on FAT32 root_ent is zero, so this is zero there too. */
    vol.root_sectors = ((uint32_t)root_ent * DIR_ENTRY_SIZE + (SD_BLOCK_SIZE - 1u))
                     / SD_BLOCK_SIZE;
    vol.root_entries = root_ent;

    vol.fat_lba  = base + rsvd;
    vol.root_lba = vol.fat_lba + ((uint32_t)nfats * fatsz);
    vol.data_lba = vol.root_lba + vol.root_sectors;

    if (vol.data_lba <= base)
        return FATMAP_NO_FS;

    data_sectors = totsec - (vol.data_lba - base);
    clusters     = data_sectors / vol.sec_per_clus;

    /* The count of clusters is what defines the FAT type -- not the label in
     * the boot sector, which is a comment and is routinely wrong. */
    if (clusters < 4085uL)
        return FATMAP_NO_FS;        /* FAT12: not supported, and not on an SD card */

    vol.fat32 = (clusters >= 65525uL);

    if (vol.fat32) {
        if (!rd32(base, BPB_RootClus, &vol.root_clus))    return FATMAP_IO;
        if (vol.root_clus < 2uL)
            return FATMAP_NO_FS;
    } else {
        vol.root_clus = 0uL;
        if (vol.root_entries == 0u)
            return FATMAP_NO_FS;
    }

    vol.valid = true;
    return FATMAP_OK;
}

/* Find the volume: a bare BPB at LBA 0, or the first MBR partition holding
 * one.  GPT is not handled; an SD card that ships GPT is not a card this
 * machine is going to boot from. */
static FatMapStatus mount(void)
{
    uint8_t  sig[2];
    uint8_t  i;

    if (vol.valid)
        return FATMAP_OK;

    memset(&vol, 0, sizeof(vol));

    /* Superfloppy first: a card formatted with no partition table. */
    if (looks_like_bpb(0uL))
        return read_bpb(0uL);

    if (!rd(0uL, SD_BLOCK_SIZE - 2u, 2u, sig))
        return FATMAP_IO;

    /* No boot signature means no MBR either.  A raw dd'd CP/M volume lands
     * here and is reported as "no filesystem", which is exactly what it is --
     * and, critically, without a single speculative read. */
    if ((sig[0] != 0x55u) || (sig[1] != 0xAAu))
        return FATMAP_NO_FS;

    for (i = 0u; i < 4u; i++) {
        uint16_t pte = (uint16_t)(MBR_TABLE + ((uint16_t)i * MBR_PTE_SIZE));
        uint32_t start;
        uint8_t  type;

        if (!rd(0uL, (uint16_t)(pte + PTE_TYPE), 1u, &type))
            return FATMAP_IO;
        if (type == 0u)
            continue;

        if (!rd32(0uL, (uint16_t)(pte + PTE_START_LBA), &start))
            return FATMAP_IO;
        if (start == 0uL)
            continue;

        /* The partition type byte is a hint, not evidence.  What settles it is
         * whether a BPB is actually there -- which is one cached read, and
         * means a partition mislabelled by whatever formatted it still works. */
        if (looks_like_bpb(start))
            return read_bpb(start);
    }

    return FATMAP_NO_FS;
}

/* ---------------------------------------------------------------------------
 * FAT chain
 * --------------------------------------------------------------------------- */

#define FAT_EOC32   0x0FFFFFF8uL
#define FAT_EOC16   0x0000FFF8uL

/* Next cluster in the chain, or 0 on an end-of-chain / bad marker.
 * Returns false only on a card failure, which the caller must distinguish from
 * a legitimate end of chain. */
static bool next_cluster(uint32_t clus, uint32_t *next, bool *end)
{
    uint32_t off;
    uint32_t lba;
    uint16_t within;

    *end = false;

    if (vol.fat32) {
        uint32_t v;

        off    = clus * 4uL;
        lba    = vol.fat_lba + (off / SD_BLOCK_SIZE);
        within = (uint16_t)(off % SD_BLOCK_SIZE);

        if (!rd32(lba, within, &v))
            return false;

        v &= 0x0FFFFFFFuL;
        if (v >= FAT_EOC32) { *end = true; return true; }
        if (v < 2uL)        { *end = true; return true; }
        *next = v;
    } else {
        uint16_t v;

        off    = clus * 2uL;
        lba    = vol.fat_lba + (off / SD_BLOCK_SIZE);
        within = (uint16_t)(off % SD_BLOCK_SIZE);

        if (!rd16(lba, within, &v))
            return false;

        if ((uint32_t)v >= FAT_EOC16) { *end = true; return true; }
        if (v < 2u)                   { *end = true; return true; }
        *next = v;
    }

    return true;
}

static uint32_t clus_to_lba(uint32_t clus)
{
    return vol.data_lba + ((clus - 2uL) * (uint32_t)vol.sec_per_clus);
}

/* Hard ceiling on any chain walk.
 *
 * A cross-linked or circular FAT would otherwise spin here forever, and WDTE
 * is OFF -- so a hang is not a reset, it is a controller that stops answering
 * with the host held waiting on COMMAND_READY.  The bound is generous: an
 * 8 MiB image is 16,384 clusters even at the smallest cluster size a FAT32
 * card uses, so nothing legitimate comes close. */
#define FATMAP_MAX_CHAIN  0x20000uL

/* ---------------------------------------------------------------------------
 * Directory search
 *
 * One flat function for all three cases -- the FAT16 fixed root, the FAT32 root
 * chain, and a subdirectory chain -- because making it recursive or generic
 * would buy nothing and cost the one property this module is here to keep.
 * --------------------------------------------------------------------------- */

static FatMapStatus find_entry(uint32_t start_clus, bool linear_root,
                               const uint8_t *name11, bool want_dir,
                               uint32_t *first_clus, uint32_t *size)
{
    uint32_t clus     = start_clus;
    uint32_t lba;
    uint32_t sec_left;
    uint32_t ent_left = linear_root ? vol.root_entries : 0xFFFFFFFFuL;
    uint32_t walked   = 0uL;

    if (linear_root) {
        lba      = vol.root_lba;
        sec_left = vol.root_sectors;
    } else {
        if (clus < 2uL)
            return FATMAP_NO_FILE;
        lba      = clus_to_lba(clus);
        sec_left = (uint32_t)vol.sec_per_clus;
    }

    for (;;) {
        uint8_t e;

        for (e = 0u; e < ENTRIES_PER_SEC; e++) {
            uint16_t off = (uint16_t)((uint16_t)e * DIR_ENTRY_SIZE);
            uint8_t  nm[11];
            uint8_t  attr;

            if (ent_left == 0uL)
                return FATMAP_NO_FILE;
            ent_left--;

            if (!rd(lba, off + DIR_NAME, 11u, nm))
                return FATMAP_IO;

            if (nm[0] == 0x00u)
                return FATMAP_NO_FILE;      /* end of directory */
            if (nm[0] == 0xE5u)
                continue;                   /* deleted */

            if (!rd(lba, off + DIR_ATTR, 1u, &attr))
                return FATMAP_IO;

            /* Long-filename fragments carry a name field that is UTF-16 text,
             * not a packed 8.3 name.  Skipping them is what lets this match
             * short names on a card written by a modern host. */
            if ((attr & ATTR_LFN) == ATTR_LFN)
                continue;
            if ((attr & ATTR_VOLUME_ID) != 0u)
                continue;

            if (memcmp(nm, name11, 11u) != 0)
                continue;

            if (want_dir != ((attr & ATTR_DIRECTORY) != 0u))
                continue;

            {
                uint16_t hi = 0u;
                uint16_t lo = 0u;

                if (vol.fat32 && !rd16(lba, off + DIR_CLUS_HI, &hi))
                    return FATMAP_IO;
                if (!rd16(lba, off + DIR_CLUS_LO, &lo))
                    return FATMAP_IO;
                if (!rd32(lba, off + DIR_SIZE, size))
                    return FATMAP_IO;

                *first_clus = ((uint32_t)hi << 16) | lo;
            }

            return FATMAP_OK;
        }

        /* Next sector, and next cluster when this one is used up. */
        lba++;
        sec_left--;

        if (sec_left != 0uL)
            continue;

        if (linear_root)
            return FATMAP_NO_FILE;          /* the fixed root has an end */

        {
            uint32_t next = 0uL;
            bool     end  = false;

            if (!next_cluster(clus, &next, &end))
                return FATMAP_IO;
            if (end)
                return FATMAP_NO_FILE;

            if (++walked > FATMAP_MAX_CHAIN)
                return FATMAP_NO_FS;    /* circular directory chain */

            clus     = next;
            lba      = clus_to_lba(clus);
            sec_left = (uint32_t)vol.sec_per_clus;
        }
    }
}

/* ---------------------------------------------------------------------------
 * The public call
 * --------------------------------------------------------------------------- */

FatMapStatus fatmap_resolve(const uint8_t *dir11, const uint8_t *name11,
                            uint32_t want_bytes,
                            FatExtent *out, uint8_t max_extents,
                            uint8_t *n_out)
{
    FatMapStatus st;
    uint32_t     dir_clus = 0uL;
    uint32_t     dir_size = 0uL;
    uint32_t     clus     = 0uL;
    uint32_t     size     = 0uL;
    uint32_t     run_start;
    uint32_t     run_len;
    uint32_t     mapped   = 0uL;
    uint32_t     walked   = 0uL;
    uint8_t      n        = 0u;

    *n_out = 0u;

    st = mount();
    if (st != FATMAP_OK)
        return st;

    /* /<dir11> */
    st = find_entry(vol.root_clus, !vol.fat32, dir11, true,
                    &dir_clus, &dir_size);
    if (st != FATMAP_OK)
        return st;

    /* /<dir11>/<name11> */
    st = find_entry(dir_clus, false, name11, false, &clus, &size);
    if (st != FATMAP_OK)
        return st;

    /* Size is checked BEFORE any mapping.  A file of the wrong length would
     * map most records correctly and then read somebody else's data at the
     * end, which is the failure this whole table exists to make impossible. */
    if (size != want_bytes)
        return FATMAP_BAD_SIZE;

    if (clus < 2uL)
        return FATMAP_NO_FILE;

    /* Walk the chain, coalescing contiguous clusters into runs. */
    run_start = clus;
    run_len   = 1uL;

    for (;;) {
        uint32_t next = 0uL;
        bool     end  = false;

        if (!next_cluster(clus, &next, &end))
            return FATMAP_IO;

        if (++walked > FATMAP_MAX_CHAIN)
            return FATMAP_NO_FS;        /* circular file chain */

        if (!end && (next == (clus + 1uL))) {
            clus = next;
            run_len++;
            continue;
        }

        if (n >= max_extents)
            return FATMAP_FRAGMENTED;

        out[n].start_lba = clus_to_lba(run_start);
        out[n].blocks    = run_len * (uint32_t)vol.sec_per_clus;
        mapped          += out[n].blocks;
        n++;

        if (end)
            break;

        clus      = next;
        run_start = next;
        run_len   = 1uL;
    }

    /* The chain must cover the file.  A short allocation is a corrupt
     * filesystem, and mapping it anyway is how CP/M would end up addressing
     * blocks that belong to something else. */
    if ((mapped * SD_BLOCK_SIZE) < want_bytes)
        return FATMAP_NO_FS;

    *n_out = n;
    return FATMAP_OK;
}
