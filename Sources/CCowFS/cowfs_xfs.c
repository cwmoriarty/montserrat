#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "cowfs_internal.h"
#include <uuid/uuid.h>

/*
 * User-space Read-Write XFS (v4 & v5) implementation for Montserrat (FSKit + FUSE-T).
 * Supports multi-AG Linux mkfs.xfs images as well as Montserrat-formatted XFS v5 volumes
 * with Castagnoli CRC32c metadata integrity.
 */

#define XFS_SB_MAGIC      0x58465342U /* "XFSB" */
#define XFS_AGF_MAGIC     0x58414746U /* "XAGF" */
#define XFS_AGI_MAGIC     0x58414749U /* "XAGI" */
#define XFS_AGFL_MAGIC    0x5841464CU /* "XAFL" */
#define XFS_ABTB_MAGIC    0x41425442U /* "ABTB" v4 */
#define XFS_AB3B_MAGIC    0x41423342U /* "AB3B" v5 */
#define XFS_ABTC_MAGIC    0x41425443U /* "ABTC" v4 */
#define XFS_AB3C_MAGIC    0x41423343U /* "AB3C" v5 */
#define XFS_IBTB_MAGIC    0x49425442U /* "IBTB" v4 */
#define XFS_IB3B_MAGIC    0x49423342U /* "IB3B" v5 */
#define XFS_DINODE_MAGIC  0x494EU     /* "IN" */

#define XFS_FMT_LOCAL     1U
#define XFS_FMT_EXTENTS   2U
#define XFS_FMT_BTREE     3U

typedef struct {
    uint32_t bsize;
    uint8_t  blocklog;
    uint16_t inodesize;
    uint8_t  inopblog;
    uint8_t  agblklog;
    uint32_t agblocks;
    uint32_t agcount;
    uint64_t dblocks;
    uint64_t fdblocks;
    uint64_t icount;
    uint64_t ifree;
    uint64_t rootino;
    int      is_v5;
    int      has_ftype;
    uint8_t  uuid[16];
    uint64_t alloc_cursor_fsb; /* sequential allocator cursor for AG 0 writes */
    uint8_t  sb_raw[512];
    int      dirty;
} xfs_rw_t;

typedef struct {
    uint64_t startoff;
    uint64_t startblock;
    uint64_t blockcount;
    uint8_t  unwritten;
} xfs_bmbt_t;

static uint32_t xfs_calc_crc(const void *buf, size_t len, size_t crc_offset) {
    uint8_t *copy = (uint8_t *)malloc(len);
    if (!copy) return 0;
    memcpy(copy, buf, len);
    memset(copy + crc_offset, 0, 4);
    uint32_t c = ~cowfs_crc32c(0xFFFFFFFFU, copy, len);
    free(copy);
    return c;
}

static void xfs_stamp_crc(void *buf, size_t len, size_t crc_offset) {
    /* XFS stores CRC32c in little-endian byte order on disk (even though XFS fields are big-endian!) */
    uint32_t c = xfs_calc_crc(buf, len, crc_offset);
    cfs_put_le32((uint8_t *)buf + crc_offset, c);
}

static uint8_t ilog2_u32(uint32_t v) {
    uint8_t r = 0;
    while ((1U << r) < v && r < 31U) r++;
    return r;
}

static uint64_t xfs_fsb_off(const xfs_rw_t *x, uint64_t fsb) {
    uint64_t agno = fsb >> x->agblklog;
    uint64_t agbno = fsb & ((1ULL << x->agblklog) - 1ULL);
    if (agno >= x->agcount || agbno >= x->agblocks) return UINT64_MAX;
    return (agno * (uint64_t)x->agblocks + agbno) * (uint64_t)x->bsize;
}

static uint64_t xfs_ino_off(const xfs_rw_t *x, uint64_t ino) {
    uint32_t agino_bits = (uint32_t)x->inopblog + (uint32_t)x->agblklog;
    if (agino_bits >= 60U) return UINT64_MAX;
    uint64_t agno = ino >> agino_bits;
    uint64_t agino = ino & ((1ULL << agino_bits) - 1ULL);
    uint64_t agbno = agino >> x->inopblog;
    uint64_t slot = agino & ((1ULL << x->inopblog) - 1ULL);
    if (agno >= x->agcount || agbno >= x->agblocks) return UINT64_MAX;
    return (agno * (uint64_t)x->agblocks + agbno) * (uint64_t)x->bsize + slot * (uint64_t)x->inodesize;
}

static void xfs_pack_bmbt(uint8_t out[16], uint64_t startoff, uint64_t startblock, uint64_t blockcount) {
    uint64_t hi = ((startoff & ((1ULL << 54) - 1ULL)) << 9) | ((startblock >> 43) & 0x1FFULL);
    uint64_t lo = ((startblock & ((1ULL << 43) - 1ULL)) << 21) | (blockcount & 0x1FFFFFULL);
    cfs_put_be64(out, hi);
    cfs_put_be64(out + 8, lo);
}

static void xfs_unpack_bmbt(const uint8_t rec[16], xfs_bmbt_t *out) {
    uint64_t hi = cfs_be64(rec);
    uint64_t lo = cfs_be64(rec + 8);
    out->unwritten = (uint8_t)((hi >> 63) & 1ULL);
    out->startoff = (hi >> 9) & ((1ULL << 54) - 1ULL);
    out->startblock = ((hi & 0x1FFULL) << 43) | (lo >> 21);
    out->blockcount = lo & 0x1FFFFFULL;
}

/*
 * Format layout (single AG XFS v5):
 *   Block 0: Sector 0 = XFSB, Sector 1 = XAGF, Sector 2 = XAGI, Sector 3 = XAFL
 *   Block 1: AB3B (free space by block B+tree root leaf)
 *   Block 2: AB3C (free space by count B+tree root leaf)
 *   Block 3: IB3B (inode B+tree root leaf: 1 chunk of 64 inodes at agbno 8 -> ino 64..127)
 *   Blocks 8..15: Preallocated 64-inode chunk (8 blocks * 8 inodes/block = 64 x 512B v3 dinodes!)
 *     ino 64 = root directory (shortform LOCAL initially)
 *   Blocks 16..agblocks-1: Free data/dir/inode blocks!
 */
int cowfs_xfs_mkfs_impl(cowfs_t *fs, const char *label, uint32_t block_size) {
    if (block_size != 4096U) block_size = 4096U;
    uint64_t total_blocks = fs->total_bytes / block_size;
    if (total_blocks < 64ULL) return -ENOSPC;
    if (total_blocks > (1ULL << 30)) total_blocks = (1ULL << 30);

    uint32_t agblocks = (uint32_t)total_blocks;
    uint8_t agblklog = ilog2_u32(agblocks);
    uint16_t inodesize = 512U;
    uint8_t inopblog = 3U; /* 4096 / 512 = 8 inodes per block */
    uint64_t rootino = 64ULL; /* agbno 8 * 8 = 64 */
    uint32_t free_start = 16U;
    uint32_t free_count = agblocks - free_start;

    uuid_t uu;
    uuid_generate(uu);

    uint8_t *blk0 = (uint8_t *)calloc(1, block_size);
    uint8_t *blk1 = (uint8_t *)calloc(1, block_size);
    uint8_t *blk2 = (uint8_t *)calloc(1, block_size);
    uint8_t *blk3 = (uint8_t *)calloc(1, block_size);
    uint8_t *ichunk = (uint8_t *)calloc(8U, block_size);
    if (!blk0 || !blk1 || !blk2 || !blk3 || !ichunk) {
        free(blk0); free(blk1); free(blk2); free(blk3); free(ichunk);
        return -ENOMEM;
    }

    /* 1. Superblock (XFSB v5 at sector 0) */
    uint8_t *sb = blk0;
    cfs_put_be32(sb + 0, XFS_SB_MAGIC);
    cfs_put_be32(sb + 4, block_size);
    cfs_put_be64(sb + 8, agblocks);      /* sb_dblocks */
    memcpy(sb + 32, uu, 16);             /* sb_uuid */
    cfs_put_be64(sb + 56, rootino);      /* sb_rootino = 64 */
    cfs_put_be32(sb + 84, agblocks);     /* sb_agblocks */
    cfs_put_be32(sb + 88, 1U);           /* sb_agcount = 1 */
    cfs_put_be16(sb + 100, 0xB4A5U);     /* v5 | ATTR2 | FTYPE | CRC |SECTOR */
    cfs_put_be16(sb + 102, 512U);        /* sb_sectsize */
    cfs_put_be16(sb + 104, inodesize);
    cfs_put_be16(sb + 106, 8U);          /* sb_inopblock */
    if (label) {
        size_t llen = strlen(label);
        if (llen > 12U) llen = 12U;
        memcpy(sb + 108, label, llen);
    }
    sb[120] = 12U;                       /* sb_blocklog */
    sb[121] = 9U;                        /* sb_sectlog */
    sb[122] = 9U;                        /* sb_inodelog */
    sb[123] = inopblog;
    sb[124] = agblklog;
    cfs_put_be64(sb + 128, 64ULL);       /* sb_icount = 64 */
    cfs_put_be64(sb + 136, 63ULL);       /* sb_ifree = 63 */
    cfs_put_be64(sb + 144, free_count);  /* sb_fdblocks */
    cfs_put_be32(sb + 200, 0x00000200U); /* FEATURES2_FTYPE */
    cfs_put_be32(sb + 208, 0x00000001U); /* INCOMPAT_FTYPE */
    memcpy(sb + 240, uu, 16);            /* sb_meta_uuid */
    xfs_stamp_crc(sb, 512U, 224U);

    /* 2. AGF at sector 1 (+512) */
    uint8_t *agf = blk0 + 512U;
    cfs_put_be32(agf + 0, XFS_AGF_MAGIC);
    cfs_put_be32(agf + 4, 1U);
    cfs_put_be32(agf + 8, 0U);           /* seqno = 0 */
    cfs_put_be32(agf + 12, agblocks);
    cfs_put_be32(agf + 16, 1U);          /* bno_root = block 1 */
    cfs_put_be32(agf + 20, 2U);          /* cnt_root = block 2 */
    cfs_put_be32(agf + 28, 1U);          /* bno_level = 1 */
    cfs_put_be32(agf + 32, 1U);          /* cnt_level = 1 */
    cfs_put_be32(agf + 48, free_count);  /* freeblks */
    cfs_put_be32(agf + 52, free_count);  /* longest */
    memcpy(agf + 64, uu, 16);
    xfs_stamp_crc(agf, 512U, 88U);

    /* 3. AGI at sector 2 (+1024) */
    uint8_t *agi = blk0 + 1024U;
    cfs_put_be32(agi + 0, XFS_AGI_MAGIC);
    cfs_put_be32(agi + 4, 1U);
    cfs_put_be32(agi + 8, 0U);
    cfs_put_be32(agi + 12, agblocks);
    cfs_put_be32(agi + 16, 64U);         /* count = 64 */
    cfs_put_be32(agi + 20, 3U);          /* root = block 3 */
    cfs_put_be32(agi + 24, 1U);          /* level = 1 */
    cfs_put_be32(agi + 28, 63U);         /* freecount = 63 */
    cfs_put_be32(agi + 32, 64U);         /* newino = 64 */
    memcpy(agi + 296, uu, 16);
    xfs_stamp_crc(agi, 512U, 320U);

    /* 4. AGFL at sector 3 (+1536) */
    uint8_t *agfl = blk0 + 1536U;
    cfs_put_be32(agfl + 0, XFS_AGFL_MAGIC);
    cfs_put_be32(agfl + 4, 0U);
    memcpy(agfl + 8, uu, 16);
    memset(agfl + 36, 0xFF, 512U - 36U);
    xfs_stamp_crc(agfl, 512U, 32U);

    /* 5. AB3B (block 1) and AB3C (block 2) 56-byte v5 short btree block header */
    cfs_put_be32(blk1 + 0, XFS_AB3B_MAGIC);
    cfs_put_be16(blk1 + 4, 0U);
    cfs_put_be16(blk1 + 6, 1U);
    cfs_put_be32(blk1 + 8, 0xFFFFFFFFU);
    cfs_put_be32(blk1 + 12, 0xFFFFFFFFU);
    cfs_put_be64(blk1 + 16, 1ULL * 8ULL);
    memcpy(blk1 + 32, uu, 16);
    cfs_put_be32(blk1 + 56, free_start);
    cfs_put_be32(blk1 + 60, free_count);
    xfs_stamp_crc(blk1, block_size, 28U);

    memcpy(blk2, blk1, block_size);
    cfs_put_be32(blk2 + 0, XFS_AB3C_MAGIC);
    cfs_put_be64(blk2 + 16, 2ULL * 8ULL);
    xfs_stamp_crc(blk2, block_size, 28U);

    /* 6. IB3B (block 3): 1 inobt record [startino=64, freecount=63, free=0xFFFFFFFFFFFFFFFE] */
    cfs_put_be32(blk3 + 0, XFS_IB3B_MAGIC);
    cfs_put_be16(blk3 + 4, 0U);
    cfs_put_be16(blk3 + 6, 1U);
    cfs_put_be32(blk3 + 8, 0xFFFFFFFFU);
    cfs_put_be32(blk3 + 12, 0xFFFFFFFFU);
    cfs_put_be64(blk3 + 16, 3ULL * 8ULL);
    memcpy(blk3 + 32, uu, 16);
    cfs_put_be32(blk3 + 56, 64U);
    cfs_put_be32(blk3 + 60, 63U);
    cfs_put_be64(blk3 + 64, 0xFFFFFFFFFFFFFFFEULL);
    xfs_stamp_crc(blk3, block_size, 28U);

    /* 7. Initialize 64 v3 dinodes in blocks 8..15; slot 0 (ino 64) is root shortform directory */
    time_t now = time(NULL);
    for (uint32_t s = 0; s < 64U; s++) {
        uint8_t *di = ichunk + s * inodesize;
        cfs_put_be16(di + 0, XFS_DINODE_MAGIC);
        di[4] = 3U; /* v3 */
        cfs_put_be64(di + 152, 64ULL + s);
        memcpy(di + 160, uu, 16);
        if (s == 0U) {
            cfs_put_be16(di + 2, S_IFDIR | 0755U);
            di[5] = XFS_FMT_LOCAL;
            cfs_put_be32(di + 16, 2U); /* nlink */
            cfs_put_be32(di + 32, (uint32_t)now);
            cfs_put_be32(di + 40, (uint32_t)now);
            cfs_put_be32(di + 48, (uint32_t)now);
            cfs_put_be64(di + 56, 6ULL); /* empty shortform header (count=0, i8count=0, parent=64) */
            uint8_t *sf = di + 176U;
            sf[0] = 0U;
            sf[1] = 0U;
            cfs_put_be32(sf + 2U, 64U);
        }
        xfs_stamp_crc(di, inodesize, 100U);
    }

    int rc = cowfs_io_write(fs, 0, block_size, blk0);
    if (rc == 0) rc = cowfs_io_write(fs, 1ULL * block_size, block_size, blk1);
    if (rc == 0) rc = cowfs_io_write(fs, 2ULL * block_size, block_size, blk2);
    if (rc == 0) rc = cowfs_io_write(fs, 3ULL * block_size, block_size, blk3);
    if (rc == 0) rc = cowfs_io_write(fs, 8ULL * block_size, 8U * block_size, ichunk);

    free(blk0); free(blk1); free(blk2); free(blk3); free(ichunk);
    return rc;
}

int cowfs_xfs_fsck_impl(cowfs_t *fs, int auto_fix, char *report_buf, size_t report_cap) {
    uint8_t sb[512];
    int rc = cowfs_io_read(fs, 0, sizeof(sb), sb);
    if (rc != 0) {
        if (report_buf && report_cap) snprintf(report_buf, report_cap, "Unable to read XFS superblock.");
        return rc;
    }
    if (cfs_be32(sb + 0) != XFS_SB_MAGIC) {
        if (report_buf && report_cap) snprintf(report_buf, report_cap, "Missing XFSB magic in primary superblock.");
        return -EINVAL;
    }

    uint32_t bsize = cfs_be32(sb + 4);
    uint16_t inodesize = cfs_be16(sb + 104);
    uint16_t ver = cfs_be16(sb + 100);
    uint64_t rootino = cfs_be64(sb + 56);
    int is_v5 = ((ver & 0x0FU) == 5U);
    int crc_errors = 0;

    if (is_v5) {
        uint32_t expected = xfs_calc_crc(sb, 512U, 224U);
        uint32_t stored = cfs_le32(sb + 224U);
        if (stored != 0 && stored != expected) {
            crc_errors++;
            if (auto_fix) {
                xfs_stamp_crc(sb, 512U, 224U);
                (void)cowfs_io_write(fs, 0, 512U, sb);
            }
        }
    }

    /* Check root dinode */
    xfs_rw_t tmp;
    memset(&tmp, 0, sizeof(tmp));
    tmp.bsize = bsize;
    tmp.inodesize = inodesize;
    tmp.inopblog = sb[123];
    tmp.agblklog = sb[124];
    tmp.agblocks = cfs_be32(sb + 84);
    tmp.agcount = cfs_be32(sb + 88);

    uint64_t r_off = xfs_ino_off(&tmp, rootino);
    if (r_off == UINT64_MAX || inodesize < 256U || inodesize > 2048U) {
        if (report_buf && report_cap) snprintf(report_buf, report_cap, "Invalid XFS root inode geometry.");
        return -EIO;
    }
    uint8_t rdi[2048];
    if (cowfs_io_read(fs, r_off, inodesize, rdi) != 0 || cfs_be16(rdi) != XFS_DINODE_MAGIC) {
        if (report_buf && report_cap) snprintf(report_buf, report_cap, "Root XFS dinode corrupted.");
        return -EIO;
    }
    if (rdi[4] >= 3U) {
        uint32_t exp_icrc = xfs_calc_crc(rdi, inodesize, 100U);
        uint32_t got_icrc = cfs_le32(rdi + 100U);
        if (got_icrc != 0 && got_icrc != exp_icrc) {
            crc_errors++;
            if (auto_fix) {
                xfs_stamp_crc(rdi, inodesize, 100U);
                (void)cowfs_io_write(fs, r_off, inodesize, rdi);
            }
        }
    }

    if (crc_errors > 0 && !auto_fix) {
        if (report_buf && report_cap) snprintf(report_buf, report_cap, "XFS CRC32c mismatch detected (%d metadata blocks).", crc_errors);
        return -EUCLEAN;
    }
    if (report_buf && report_cap) {
        snprintf(report_buf, report_cap,
                 crc_errors > 0 ? "XFS v%u check repaired %d metadata CRC32c block(s)." : "XFS v%u filesystem is clean.",
                 is_v5 ? 5U : 4U, crc_errors);
    }
    return (crc_errors > 0 && auto_fix) ? 1 : 0;
}

static int xfs_rw_mount(cowfs_t *fs) {
    uint8_t sb[512];
    int rc = cowfs_io_read(fs, 0, sizeof(sb), sb);
    if (rc != 0) return rc;
    if (cfs_be32(sb + 0) != XFS_SB_MAGIC) return -EINVAL;

    uint32_t bsize = cfs_be32(sb + 4);
    uint16_t inodesize = cfs_be16(sb + 104);
    if (bsize < 512U || bsize > 65536U || (bsize & (bsize - 1U)) != 0) return -EINVAL;
    if (inodesize < 256U || inodesize > 2048U || (inodesize & (inodesize - 1U)) != 0) return -EINVAL;

    xfs_rw_t *x = (xfs_rw_t *)calloc(1, sizeof(xfs_rw_t));
    if (!x) return -ENOMEM;
    memcpy(x->sb_raw, sb, sizeof(sb));
    x->bsize = bsize;
    x->blocklog = sb[120];
    x->inodesize = inodesize;
    x->inopblog = sb[123];
    x->agblklog = sb[124];
    x->agblocks = cfs_be32(sb + 84);
    x->agcount = cfs_be32(sb + 88);
    x->dblocks = cfs_be64(sb + 8);
    x->icount = cfs_be64(sb + 128);
    x->ifree = cfs_be64(sb + 136);
    x->fdblocks = cfs_be64(sb + 144);
    x->rootino = cfs_be64(sb + 56);
    uint16_t ver = cfs_be16(sb + 100);
    x->is_v5 = ((ver & 0x0FU) == 5U);
    x->has_ftype = x->is_v5 || ((ver & 0x8000U) != 0 && (cfs_be32(sb + 200) & 0x200U) != 0);
    memcpy(x->uuid, sb + (x->is_v5 ? 240U : 32U), 16U);

    /* Discover free space start from ABTB/AB3B at block 1 if present */
    uint8_t *blk1 = (uint8_t *)malloc(bsize);
    x->alloc_cursor_fsb = 16ULL;
    if (blk1 && cowfs_io_read(fs, 1ULL * bsize, bsize, blk1) == 0) {
        uint32_t m = cfs_be32(blk1);
        size_t hdr = (m == XFS_AB3B_MAGIC) ? 56U : ((m == XFS_ABTB_MAGIC) ? 16U : 0U);
        if (hdr > 0 && cfs_be16(blk1 + 4) == 0 && cfs_be16(blk1 + 6) >= 1U) {
            uint32_t fstart = cfs_be32(blk1 + hdr);
            if (fstart >= 4U && fstart < x->agblocks) {
                x->alloc_cursor_fsb = fstart;
            }
        }
    }
    free(blk1);

    fs->priv = x;
    return 0;
}

static int xfs_rw_sync(cowfs_t *fs) {
    xfs_rw_t *x = (xfs_rw_t *)fs->priv;
    if (!x || !x->dirty || fs->read_only) return 0;

    cfs_put_be64(x->sb_raw + 128, x->icount);
    cfs_put_be64(x->sb_raw + 136, x->ifree);
    cfs_put_be64(x->sb_raw + 144, x->fdblocks);
    if (x->is_v5) xfs_stamp_crc(x->sb_raw, 512U, 224U);
    int rc = cowfs_io_write(fs, 0, 512U, x->sb_raw);

    /* Update AB3B/AB3C free-space record in AG 0 if single-AG Montserrat layout */
    uint8_t *blk1 = (uint8_t *)malloc(x->bsize);
    if (blk1 && cowfs_io_read(fs, 1ULL * x->bsize, x->bsize, blk1) == 0 &&
        cfs_be32(blk1) == XFS_AB3B_MAGIC && x->alloc_cursor_fsb <= x->agblocks) {
        uint32_t rem = (uint32_t)(x->agblocks - x->alloc_cursor_fsb);
        cfs_put_be32(blk1 + 56, (uint32_t)x->alloc_cursor_fsb);
        cfs_put_be32(blk1 + 60, rem);
        xfs_stamp_crc(blk1, x->bsize, 28U);
        (void)cowfs_io_write(fs, 1ULL * x->bsize, x->bsize, blk1);

        cfs_put_be32(blk1 + 0, XFS_AB3C_MAGIC);
        cfs_put_be64(blk1 + 16, 2ULL * 8ULL);
        xfs_stamp_crc(blk1, x->bsize, 28U);
        (void)cowfs_io_write(fs, 2ULL * x->bsize, x->bsize, blk1);
    }
    free(blk1);

    x->dirty = 0;
    return rc;
}

static void xfs_rw_unmount(cowfs_t *fs) {
    free(fs->priv);
    fs->priv = NULL;
}

static uint64_t xfs_rw_root_ino(const cowfs_t *fs) {
    const xfs_rw_t *x = (const xfs_rw_t *)fs->priv;
    return x ? x->rootino : 64ULL;
}

static int xfs_rw_statfs(cowfs_t *fs, uint64_t *total_bytes, uint64_t *free_bytes, uint32_t *block_size) {
    const xfs_rw_t *x = (const xfs_rw_t *)fs->priv;
    if (total_bytes) *total_bytes = x->dblocks * x->bsize;
    if (free_bytes) *free_bytes = x->fdblocks * x->bsize;
    if (block_size) *block_size = x->bsize;
    return 0;
}

static int xfs_alloc_blocks(cowfs_t *fs, uint32_t count, uint64_t *out_fsb) {
    xfs_rw_t *x = (xfs_rw_t *)fs->priv;
    if (x->alloc_cursor_fsb + count > x->agblocks || x->fdblocks < count) return -ENOSPC;
    uint64_t fsb = x->alloc_cursor_fsb;
    x->alloc_cursor_fsb += count;
    x->fdblocks -= count;
    x->dirty = 1;

    uint8_t *zeros = (uint8_t *)calloc(count, x->bsize);
    if (zeros) {
        (void)cowfs_io_write(fs, xfs_fsb_off(x, fsb), (size_t)count * x->bsize, zeros);
        free(zeros);
    }
    *out_fsb = fsb;
    return 0;
}

static int xfs_alloc_inode(cowfs_t *fs, uint16_t mode, uint64_t *out_ino) {
    xfs_rw_t *x = (xfs_rw_t *)fs->priv;
    uint8_t *blk3 = (uint8_t *)malloc(x->bsize);
    if (!blk3) return -ENOMEM;

    int rc = cowfs_io_read(fs, 3ULL * x->bsize, x->bsize, blk3);
    uint32_t m = (rc == 0) ? cfs_be32(blk3) : 0U;
    size_t hdr = (m == XFS_IB3B_MAGIC) ? 56U : ((m == XFS_IBTB_MAGIC) ? 16U : 0U);
    if (hdr == 0U || cfs_be16(blk3 + 4) != 0U) {
        free(blk3);
        return -ENOSPC;
    }

    uint16_t numrecs = cfs_be16(blk3 + 6);
    uint64_t chosen_ino = 0;

    for (uint16_t r = 0; r < numrecs; r++) {
        uint8_t *rec = blk3 + hdr + (size_t)r * 16U;
        uint32_t startino = cfs_be32(rec + 0);
        uint32_t freecnt = cfs_be32(rec + 4);
        uint64_t freemask = cfs_be64(rec + 8);
        if (freecnt > 0 && freemask != 0ULL) {
            for (uint32_t bit = 0; bit < 64U; bit++) {
                if ((freemask & (1ULL << bit)) != 0ULL) {
                    chosen_ino = (uint64_t)startino + bit;
                    freemask &= ~(1ULL << bit);
                    cfs_put_be32(rec + 4, freecnt - 1U);
                    cfs_put_be64(rec + 8, freemask);
                    if (x->ifree > 0) x->ifree--;
                    break;
                }
            }
            if (chosen_ino != 0) break;
        }
    }

    /* Allocate a new 64-inode chunk if existing chunks are full */
    if (chosen_ino == 0) {
        uint32_t chunk_blocks = (64U * x->inodesize) / x->bsize;
        uint64_t chunk_fsb = 0;
        if (hdr + ((size_t)numrecs + 1U) * 16U > x->bsize ||
            xfs_alloc_blocks(fs, chunk_blocks, &chunk_fsb) != 0) {
            free(blk3);
            return -ENOSPC;
        }
        uint32_t startino = (uint32_t)(chunk_fsb << x->inopblog);
        chosen_ino = startino;

        uint8_t *ichunk = (uint8_t *)calloc(chunk_blocks, x->bsize);
        if (!ichunk) { free(blk3); return -ENOMEM; }
        for (uint32_t s = 0; s < 64U; s++) {
            uint8_t *di = ichunk + s * x->inodesize;
            cfs_put_be16(di + 0, XFS_DINODE_MAGIC);
            di[4] = x->is_v5 ? 3U : 2U;
            if (x->is_v5) {
                cfs_put_be64(di + 152, (uint64_t)startino + s);
                memcpy(di + 160, x->uuid, 16U);
                xfs_stamp_crc(di, x->inodesize, 100U);
            }
        }
        (void)cowfs_io_write(fs, xfs_fsb_off(x, chunk_fsb), (size_t)chunk_blocks * x->bsize, ichunk);
        free(ichunk);

        uint8_t *rec = blk3 + hdr + (size_t)numrecs * 16U;
        cfs_put_be32(rec + 0, startino);
        cfs_put_be32(rec + 4, 63U);
        cfs_put_be64(rec + 8, 0xFFFFFFFFFFFFFFFEULL);
        cfs_put_be16(blk3 + 6, numrecs + 1U);
        x->icount += 64ULL;
        x->ifree += 63ULL;
    }

    if (m == XFS_IB3B_MAGIC) xfs_stamp_crc(blk3, x->bsize, 28U);
    rc = cowfs_io_write(fs, 3ULL * x->bsize, x->bsize, blk3);
    free(blk3);
    if (rc != 0) return rc;

    /* Write fresh dinode */
    uint8_t di[2048];
    memset(di, 0, x->inodesize);
    time_t now = time(NULL);
    cfs_put_be16(di + 0, XFS_DINODE_MAGIC);
    cfs_put_be16(di + 2, mode);
    di[4] = x->is_v5 ? 3U : 2U;
    di[5] = ((mode & S_IFMT) == S_IFDIR || (mode & S_IFMT) == S_IFLNK) ? XFS_FMT_LOCAL : XFS_FMT_EXTENTS;
    cfs_put_be32(di + 16, ((mode & S_IFMT) == S_IFDIR) ? 2U : 1U);
    cfs_put_be32(di + 32, (uint32_t)now);
    cfs_put_be32(di + 40, (uint32_t)now);
    cfs_put_be32(di + 48, (uint32_t)now);
    if (x->is_v5) {
        cfs_put_be64(di + 152, chosen_ino);
        memcpy(di + 160, x->uuid, 16U);
        xfs_stamp_crc(di, x->inodesize, 100U);
    }

    rc = cowfs_io_write(fs, xfs_ino_off(x, chosen_ino), x->inodesize, di);
    if (rc == 0) {
        x->dirty = 1;
        *out_ino = chosen_ino;
    }
    return rc;
}

static int xfs_read_dinode(const cowfs_t *fs, uint64_t ino, uint8_t di[2048], size_t *fork_off, size_t *fork_cap) {
    const xfs_rw_t *x = (const xfs_rw_t *)fs->priv;
    uint64_t off = xfs_ino_off(x, ino);
    if (off == UINT64_MAX) return -ENOENT;
    int rc = cowfs_io_read(fs, off, x->inodesize, di);
    if (rc != 0) return rc;
    if (cfs_be16(di + 0) != XFS_DINODE_MAGIC || (cfs_be16(di + 2) & S_IFMT) == 0) return -ENOENT;
    uint8_t ver = di[4];
    size_t foff = (ver >= 3U) ? 176U : 100U;
    uint8_t fo8 = di[82];
    size_t fcap = (fo8 > 0U && foff + (size_t)fo8 * 8U <= x->inodesize) ? ((size_t)fo8 * 8U) : (x->inodesize - foff);
    if (fork_off) *fork_off = foff;
    if (fork_cap) *fork_cap = fcap;
    return 0;
}

static int xfs_write_dinode(cowfs_t *fs, uint64_t ino, uint8_t di[2048]) {
    xfs_rw_t *x = (xfs_rw_t *)fs->priv;
    uint64_t off = xfs_ino_off(x, ino);
    if (off == UINT64_MAX) return -ENOENT;
    if (di[4] >= 3U) xfs_stamp_crc(di, x->inodesize, 100U);
    x->dirty = 1;
    return cowfs_io_write(fs, off, x->inodesize, di);
}

static uint8_t mode_to_ft(uint32_t mode) {
    switch (mode & S_IFMT) {
    case S_IFREG: return 1U;
    case S_IFDIR: return 2U;
    case S_IFLNK: return 3U;
    default:      return 0U;
    }
}

static int xfs_rw_getattr(cowfs_t *fs, uint64_t ino, cowfs_item_attrs_t *out) {
    const xfs_rw_t *x = (const xfs_rw_t *)fs->priv;
    uint8_t di[2048];
    int rc = xfs_read_dinode(fs, ino, di, NULL, NULL);
    if (rc != 0) return rc;

    uint16_t mode = cfs_be16(di + 2);
    memset(out, 0, sizeof(*out));
    out->ino = ino;
    out->mode = mode;
    out->uid = cfs_be32(di + 8);
    out->gid = cfs_be32(di + 12);
    out->nlink = (di[4] == 1U) ? cfs_be16(di + 6) : cfs_be32(di + 16);
    out->size = cfs_be64(di + 56);
    out->alloc_size = cfs_be64(di + 64) * x->bsize;
    out->atime_sec = (int32_t)cfs_be32(di + 32);
    out->mtime_sec = (int32_t)cfs_be32(di + 40);
    out->ctime_sec = (int32_t)cfs_be32(di + 48);
    out->file_type = mode_to_ft(mode);
    return 0;
}

static int xfs_rw_setattr(cowfs_t *fs, uint64_t ino, uint32_t mask, const cowfs_item_attrs_t *in_attrs) {
    uint8_t di[2048];
    int rc = xfs_read_dinode(fs, ino, di, NULL, NULL);
    if (rc != 0) return rc;

    uint16_t cur_mode = cfs_be16(di + 2);
    if (mask & COWFS_ATTR_MODE) {
        cfs_put_be16(di + 2, (cur_mode & S_IFMT) | (in_attrs->mode & 07777U));
    }
    if (mask & COWFS_ATTR_UID) cfs_put_be32(di + 8, in_attrs->uid);
    if (mask & COWFS_ATTR_GID) cfs_put_be32(di + 12, in_attrs->gid);
    if (mask & COWFS_ATTR_ATIME) cfs_put_be32(di + 32, (uint32_t)in_attrs->atime_sec);
    if (mask & COWFS_ATTR_MTIME) cfs_put_be32(di + 40, (uint32_t)in_attrs->mtime_sec);
    if (mask & COWFS_ATTR_SIZE) {
        cfs_put_be64(di + 56, in_attrs->size);
    }
    cfs_put_be32(di + 48, (uint32_t)time(NULL));
    return xfs_write_dinode(fs, ino, di);
}

/* Parse shortform or single-block directory into a clean in-memory entry list for read & mutation */
typedef struct {
    char     name[256];
    uint64_t ino;
    uint8_t  xfs_ft; /* 1=reg, 2=dir, 7=lnk */
} xfs_dent_t;

typedef struct {
    uint64_t    parent_ino;
    xfs_dent_t *ents;
    size_t      count;
    size_t      cap;
} xfs_dir_list_t;

static int xfs_dir_push(xfs_dir_list_t *d, const char *name, uint64_t ino, uint8_t xfs_ft) {
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) return 0;
    if (d->count == d->cap) {
        size_t ncap = d->cap ? d->cap * 2U : 16U;
        xfs_dent_t *ne = (xfs_dent_t *)realloc(d->ents, ncap * sizeof(xfs_dent_t));
        if (!ne) return -ENOMEM;
        d->ents = ne;
        d->cap = ncap;
    }
    snprintf(d->ents[d->count].name, sizeof(d->ents[d->count].name), "%s", name);
    d->ents[d->count].ino = ino;
    d->ents[d->count].xfs_ft = xfs_ft;
    d->count++;
    return 0;
}

static int xfs_load_dir_entries(cowfs_t *fs, uint64_t dir_ino, xfs_dir_list_t *out) {
    const xfs_rw_t *x = (const xfs_rw_t *)fs->priv;
    memset(out, 0, sizeof(*out));
    out->parent_ino = x->rootino;

    uint8_t di[2048];
    size_t fork_off = 0, fork_cap = 0;
    int rc = xfs_read_dinode(fs, dir_ino, di, &fork_off, &fork_cap);
    if (rc != 0) return rc;
    if ((cfs_be16(di + 2) & S_IFMT) != S_IFDIR) return -ENOTDIR;

    const uint8_t *fork = di + fork_off;
    uint8_t fmt = di[5];
    uint64_t dsize = cfs_be64(di + 56);

    if (fmt == XFS_FMT_LOCAL) {
        size_t lim = (dsize < fork_cap) ? (size_t)dsize : fork_cap;
        if (lim < 6U) return 0;
        uint8_t cnt = fork[0];
        uint8_t i8 = fork[1];
        size_t ilen = i8 ? 8U : 4U;
        if (2U + ilen > lim) return 0;
        out->parent_ino = i8 ? cfs_be64(fork + 2U) : cfs_be32(fork + 2U);

        size_t pos = 2U + ilen;
        for (uint8_t i = 0; i < cnt; i++) {
            if (pos + 3U > lim) break;
            uint8_t nl = fork[pos];
            size_t need = 3U + nl + (x->has_ftype ? 1U : 0U) + ilen;
            if (nl == 0 || pos + need > lim) break;
            char nm[256];
            memcpy(nm, fork + pos + 3U, nl);
            nm[nl] = '\0';
            size_t p2 = pos + 3U + nl;
            uint8_t ft = x->has_ftype ? fork[p2++] : 1U;
            uint64_t cino = i8 ? cfs_be64(fork + p2) : cfs_be32(fork + p2);
            (void)xfs_dir_push(out, nm, cino, ft);
            pos = p2 + ilen;
        }
        return 0;
    }

    if (fmt == XFS_FMT_EXTENTS) {
        uint32_t nexts = cfs_be32(di + 76);
        if (nexts > fork_cap / 16U) nexts = (uint32_t)(fork_cap / 16U);
        uint64_t leaf_blocks = (32ULL << 30) >> x->blocklog;
        uint8_t *blk = (uint8_t *)malloc(x->bsize);
        if (!blk) return -ENOMEM;

        for (uint32_t e = 0; e < nexts; e++) {
            xfs_bmbt_t bm;
            xfs_unpack_bmbt(fork + (size_t)e * 16U, &bm);
            if (bm.startoff >= leaf_blocks) continue;
            for (uint64_t b = 0; b < bm.blockcount && bm.startoff + b < leaf_blocks; b++) {
                uint64_t boff = xfs_fsb_off(x, bm.startblock + b);
                if (boff == UINT64_MAX || cowfs_io_read(fs, boff, x->bsize, blk) != 0) continue;
                uint32_t m = cfs_be32(blk);
                size_t pos = 0, end = x->bsize;
                int single = 0;
                if (m == 0x58443242U) { pos = 16U; single = 1; }
                else if (m == 0x58444233U) { pos = 64U; single = 1; }
                else if (m == 0x58443244U) { pos = 16U; }
                else if (m == 0x58444433U) { pos = 64U; }
                else continue;

                if (single) {
                    uint32_t btc = cfs_be32(blk + x->bsize - 8U);
                    size_t tb = 8U + (size_t)btc * 8U;
                    if (tb < end - pos) end -= tb;
                }
                while (pos + 6U <= end) {
                    if (cfs_be16(blk + pos) == 0xFFFFU) {
                        uint16_t fl = cfs_be16(blk + pos + 2U);
                        if (fl < 4U) break;
                        pos += fl;
                        continue;
                    }
                    if (pos + 11U > end) break;
                    uint64_t cino = cfs_be64(blk + pos);
                    uint8_t nl = blk[pos + 8U];
                    size_t rlen = 8U + 1U + nl + (x->has_ftype ? 1U : 0U) + 2U;
                    size_t elen = (rlen + 7U) & ~(size_t)7U;
                    if (nl == 0 || pos + elen > end) break;
                    char nm[256];
                    memcpy(nm, blk + pos + 9U, nl);
                    nm[nl] = '\0';
                    uint8_t ft = x->has_ftype ? blk[pos + 9U + nl] : 1U;
                    if (strcmp(nm, "..") == 0) out->parent_ino = cino;
                    else (void)xfs_dir_push(out, nm, cino, ft);
                    pos += elen;
                }
            }
        }
        free(blk);
    }
    return 0;
}

static int xfs_save_dir_entries(cowfs_t *fs, uint64_t dir_ino, const xfs_dir_list_t *d) {
    xfs_rw_t *x = (xfs_rw_t *)fs->priv;
    uint8_t di[2048];
    size_t fork_off = 0, fork_cap = 0;
    int rc = xfs_read_dinode(fs, dir_ino, di, &fork_off, &fork_cap);
    if (rc != 0) return rc;

    /* Measure if shortform LOCAL fits inside fork_cap */
    int need_i8 = (d->parent_ino > 0xFFFFFFFFULL);
    for (size_t i = 0; i < d->count; i++) {
        if (d->ents[i].ino > 0xFFFFFFFFULL) need_i8 = 1;
    }
    size_t ilen = need_i8 ? 8U : 4U;
    size_t sf_bytes = 2U + ilen;
    for (size_t i = 0; i < d->count; i++) {
        sf_bytes += 3U + strlen(d->ents[i].name) + (x->has_ftype ? 1U : 0U) + ilen;
    }

    if (d->count < 250U && sf_bytes <= fork_cap && di[5] == XFS_FMT_LOCAL) {
        uint8_t *sf = di + fork_off;
        memset(sf, 0, fork_cap);
        sf[0] = (uint8_t)d->count;
        sf[1] = need_i8 ? (uint8_t)d->count : 0U;
        if (need_i8) cfs_put_be64(sf + 2U, d->parent_ino);
        else cfs_put_be32(sf + 2U, (uint32_t)d->parent_ino);

        size_t pos = 2U + ilen;
        uint16_t off_tag = 0x60U;
        for (size_t i = 0; i < d->count; i++) {
            uint8_t nl = (uint8_t)strlen(d->ents[i].name);
            sf[pos] = nl;
            cfs_put_be16(sf + pos + 1U, off_tag);
            off_tag = (uint16_t)(off_tag + 0x10U);
            memcpy(sf + pos + 3U, d->ents[i].name, nl);
            size_t p2 = pos + 3U + nl;
            if (x->has_ftype) sf[p2++] = d->ents[i].xfs_ft;
            if (need_i8) cfs_put_be64(sf + p2, d->ents[i].ino);
            else cfs_put_be32(sf + p2, (uint32_t)d->ents[i].ino);
            pos = p2 + ilen;
        }
        cfs_put_be64(di + 56, pos);
        cfs_put_be32(di + 40, (uint32_t)time(NULL));
        cfs_put_be32(di + 48, (uint32_t)time(NULL));
        return xfs_write_dinode(fs, dir_ino, di);
    }

    /* Promote or update XDB3 / XD2B single-block directory */
    uint64_t dir_fsb = 0;
    if (di[5] == XFS_FMT_EXTENTS && cfs_be32(di + 76) >= 1U) {
        xfs_bmbt_t bm;
        xfs_unpack_bmbt(di + fork_off, &bm);
        dir_fsb = bm.startblock;
    } else {
        rc = xfs_alloc_blocks(fs, 1U, &dir_fsb);
        if (rc != 0) return rc;
        di[5] = XFS_FMT_EXTENTS;
        memset(di + fork_off, 0, fork_cap);
        xfs_pack_bmbt(di + fork_off, 0ULL, dir_fsb, 1ULL);
        cfs_put_be32(di + 76, 1U);
        cfs_put_be64(di + 64, 1ULL);
    }

    uint8_t *blk = (uint8_t *)calloc(1, x->bsize);
    if (!blk) return -ENOMEM;
    size_t hdr = x->is_v5 ? 64U : 16U;
    cfs_put_be32(blk, x->is_v5 ? 0x58444233U : 0x58443242U);
    if (x->is_v5) {
        cfs_put_be64(blk + 16, xfs_fsb_off(x, dir_fsb) / 512ULL);
        memcpy(blk + 32, x->uuid, 16U);
        cfs_put_be64(blk + 48, dir_ino);
    }

    size_t total_ents = 2U + d->count;
    size_t tail_bytes = 8U + total_ents * 8U;
    if (hdr + tail_bytes + 64U > x->bsize) {
        free(blk);
        return -ENOSPC;
    }
    size_t data_limit = x->bsize - tail_bytes;
    size_t pos = hdr;

    for (size_t idx = 0; idx < total_ents; idx++) {
        const char *nm = (idx == 0) ? "." : ((idx == 1) ? ".." : d->ents[idx - 2U].name);
        uint64_t cino = (idx == 0) ? dir_ino : ((idx == 1) ? d->parent_ino : d->ents[idx - 2U].ino);
        uint8_t ft = (idx < 2U) ? 2U : d->ents[idx - 2U].xfs_ft;
        uint8_t nl = (uint8_t)strlen(nm);
        size_t rlen = 8U + 1U + nl + (x->has_ftype ? 1U : 0U) + 2U;
        size_t elen = (rlen + 7U) & ~(size_t)7U;
        if (pos + elen > data_limit) {
            free(blk);
            return -ENOSPC;
        }
        cfs_put_be64(blk + pos, cino);
        blk[pos + 8U] = nl;
        memcpy(blk + pos + 9U, nm, nl);
        if (x->has_ftype) blk[pos + 9U + nl] = ft;
        cfs_put_be16(blk + pos + elen - 2U, (uint16_t)pos);

        /* Record leaf entry at tail */
        uint8_t *le = blk + data_limit + idx * 8U;
        cfs_put_be32(le + 0, (uint32_t)(idx + 1U));
        cfs_put_be32(le + 4, (uint32_t)(pos >> 3));
        pos += elen;
    }

    if (pos + 4U <= data_limit) {
        uint16_t free_len = (uint16_t)(data_limit - pos);
        cfs_put_be16(blk + pos, 0xFFFFU);
        cfs_put_be16(blk + pos + 2U, free_len);
        cfs_put_be16(blk + pos + free_len - 2U, (uint16_t)pos);
    }
    cfs_put_be32(blk + x->bsize - 8U, (uint32_t)total_ents);
    cfs_put_be32(blk + x->bsize - 4U, 0U);
    if (x->is_v5) xfs_stamp_crc(blk, x->bsize, 8U);

    rc = cowfs_io_write(fs, xfs_fsb_off(x, dir_fsb), x->bsize, blk);
    free(blk);
    if (rc != 0) return rc;

    cfs_put_be64(di + 56, x->bsize);
    cfs_put_be32(di + 40, (uint32_t)time(NULL));
    cfs_put_be32(di + 48, (uint32_t)time(NULL));
    return xfs_write_dinode(fs, dir_ino, di);
}

static uint8_t xfs_ft_to_cowfs(uint8_t xft) {
    if (xft == 2U) return 2U;
    if (xft == 7U) return 3U;
    return 1U;
}

static int xfs_rw_readdir(cowfs_t *fs, uint64_t dir_ino, uint64_t start_cookie, cowfs_dir_cb cb, void *user_ctx) {
    xfs_dir_list_t dl;
    int rc = xfs_load_dir_entries(fs, dir_ino, &dl);
    if (rc != 0) return rc;

    size_t total = 2U + dl.count;
    for (size_t i = (size_t)start_cookie; i < total; i++) {
        const char *nm = (i == 0) ? "." : ((i == 1) ? ".." : dl.ents[i - 2U].name);
        uint64_t ino = (i == 0) ? dir_ino : ((i == 1) ? dl.parent_ino : dl.ents[i - 2U].ino);
        uint8_t ft = (i < 2U) ? 2U : xfs_ft_to_cowfs(dl.ents[i - 2U].xfs_ft);
        if (!cb(user_ctx, nm, ino, ft, (uint64_t)(i + 1U))) break;
    }
    free(dl.ents);
    return 0;
}

static int xfs_rw_lookup(cowfs_t *fs, uint64_t dir_ino, const char *name, uint64_t *out_ino) {
    xfs_dir_list_t dl;
    int rc = xfs_load_dir_entries(fs, dir_ino, &dl);
    if (rc != 0) return rc;
    int found = 0;
    if (strcmp(name, ".") == 0) { *out_ino = dir_ino; found = 1; }
    else if (strcmp(name, "..") == 0) { *out_ino = dl.parent_ino; found = 1; }
    else {
        for (size_t i = 0; i < dl.count; i++) {
            if (strcmp(dl.ents[i].name, name) == 0) {
                *out_ino = dl.ents[i].ino;
                found = 1;
                break;
            }
        }
    }
    free(dl.ents);
    return found ? 0 : -ENOENT;
}

static int xfs_rw_read(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, void *buffer, size_t *out_read) {
    const xfs_rw_t *x = (const xfs_rw_t *)fs->priv;
    uint8_t di[2048];
    size_t fork_off = 0, fork_cap = 0;
    int rc = xfs_read_dinode(fs, ino, di, &fork_off, &fork_cap);
    if (rc != 0) return rc;
    if ((cfs_be16(di + 2) & S_IFMT) == S_IFDIR) return -EISDIR;

    uint64_t fsize = cfs_be64(di + 56);
    if (offset >= fsize || length == 0) {
        *out_read = 0;
        return 0;
    }
    size_t to_read = (fsize - offset < (uint64_t)length) ? (size_t)(fsize - offset) : length;
    const uint8_t *fork = di + fork_off;

    if (di[5] == XFS_FMT_LOCAL) {
        if (offset + to_read > fork_cap) return -EIO;
        memcpy(buffer, fork + offset, to_read);
        *out_read = to_read;
        return 0;
    }

    uint32_t nexts = cfs_be32(di + 76);
    if (nexts > fork_cap / 16U) nexts = (uint32_t)(fork_cap / 16U);
    uint8_t *dst = (uint8_t *)buffer;
    memset(dst, 0, to_read);
    size_t done = 0;

    while (done < to_read) {
        uint64_t cur = offset + done;
        uint64_t lblk = cur >> x->blocklog;
        uint32_t boff = (uint32_t)(cur & (x->bsize - 1U));
        size_t chunk = x->bsize - boff;
        if (chunk > to_read - done) chunk = to_read - done;

        for (uint32_t e = 0; e < nexts; e++) {
            xfs_bmbt_t bm;
            xfs_unpack_bmbt(fork + (size_t)e * 16U, &bm);
            if (lblk >= bm.startoff && lblk < bm.startoff + bm.blockcount && !bm.unwritten) {
                uint64_t disk_off = xfs_fsb_off(x, bm.startblock + (lblk - bm.startoff));
                if (disk_off == UINT64_MAX) return -EIO;
                rc = cowfs_io_read(fs, disk_off + boff, chunk, dst + done);
                if (rc != 0) return rc;
                break;
            }
        }
        done += chunk;
    }

    *out_read = to_read;
    return 0;
}

static int xfs_rw_write(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, const void *buffer, size_t *out_written) {
    xfs_rw_t *x = (xfs_rw_t *)fs->priv;
    uint8_t di[2048];
    size_t fork_off = 0, fork_cap = 0;
    int rc = xfs_read_dinode(fs, ino, di, &fork_off, &fork_cap);
    if (rc != 0) return rc;
    if ((cfs_be16(di + 2) & S_IFMT) != S_IFREG) return -EINVAL;
    if (length == 0) { *out_written = 0; return 0; }

    uint8_t *fork = di + fork_off;
    uint32_t max_exts = (uint32_t)(fork_cap / 16U);
    uint32_t nexts = cfs_be32(di + 76);
    if (nexts > max_exts) nexts = max_exts;
    uint64_t nblocks = cfs_be64(di + 64);

    const uint8_t *src = (const uint8_t *)buffer;
    size_t done = 0;

    while (done < length) {
        uint64_t cur = offset + done;
        uint64_t lblk = cur >> x->blocklog;
        uint32_t boff = (uint32_t)(cur & (x->bsize - 1U));
        size_t chunk = x->bsize - boff;
        if (chunk > length - done) chunk = length - done;

        uint64_t target_fsb = UINT64_MAX;
        for (uint32_t e = 0; e < nexts; e++) {
            xfs_bmbt_t bm;
            xfs_unpack_bmbt(fork + (size_t)e * 16U, &bm);
            if (lblk >= bm.startoff && lblk < bm.startoff + bm.blockcount) {
                target_fsb = bm.startblock + (lblk - bm.startoff);
                break;
            }
        }

        if (target_fsb == UINT64_MAX) {
            uint64_t new_fsb = 0;
            rc = xfs_alloc_blocks(fs, 1U, &new_fsb);
            if (rc != 0) return rc;
            target_fsb = new_fsb;
            nblocks++;

            /* Coalesce with trailing contiguous extent when possible */
            int merged = 0;
            if (nexts > 0U) {
                xfs_bmbt_t prev;
                xfs_unpack_bmbt(fork + (size_t)(nexts - 1U) * 16U, &prev);
                if (!prev.unwritten &&
                    prev.startoff + prev.blockcount == lblk &&
                    prev.startblock + prev.blockcount == new_fsb) {
                    xfs_pack_bmbt(fork + (size_t)(nexts - 1U) * 16U, prev.startoff, prev.startblock, prev.blockcount + 1ULL);
                    merged = 1;
                }
            }
            if (!merged) {
                if (nexts >= max_exts) return -EFBIG;
                xfs_pack_bmbt(fork + (size_t)nexts * 16U, lblk, new_fsb, 1ULL);
                nexts++;
            }
        }

        rc = cowfs_io_write(fs, xfs_fsb_off(x, target_fsb) + boff, chunk, src + done);
        if (rc != 0) return rc;
        done += chunk;
    }

    uint64_t old_size = cfs_be64(di + 56);
    if (offset + length > old_size) cfs_put_be64(di + 56, offset + length);
    cfs_put_be64(di + 64, nblocks);
    cfs_put_be32(di + 76, nexts);
    cfs_put_be32(di + 40, (uint32_t)time(NULL));
    cfs_put_be32(di + 48, (uint32_t)time(NULL));

    rc = xfs_write_dinode(fs, ino, di);
    if (rc == 0) *out_written = done;
    return rc;
}

static int xfs_create_common(cowfs_t *fs, uint64_t dir_ino, const char *name, uint16_t full_mode, const char *sym_target, uint64_t *out_ino) {
    if (!name || name[0] == '\0' || strlen(name) > 255U) return -EINVAL;
    uint64_t existing = 0;
    if (xfs_rw_lookup(fs, dir_ino, name, &existing) == 0) return -EEXIST;

    xfs_dir_list_t dl;
    int rc = xfs_load_dir_entries(fs, dir_ino, &dl);
    if (rc != 0) return rc;

    uint64_t new_ino = 0;
    rc = xfs_alloc_inode(fs, full_mode, &new_ino);
    if (rc != 0) { free(dl.ents); return rc; }

    if ((full_mode & S_IFMT) == S_IFDIR) {
        xfs_dir_list_t child_dl = { dir_ino, NULL, 0, 0 };
        rc = xfs_save_dir_entries(fs, new_ino, &child_dl);
        if (rc != 0) { free(dl.ents); return rc; }
    } else if ((full_mode & S_IFMT) == S_IFLNK && sym_target) {
        uint8_t di[2048];
        size_t foff = 0, fcap = 0;
        if (xfs_read_dinode(fs, new_ino, di, &foff, &fcap) == 0) {
            size_t slen = strlen(sym_target);
            if (slen > fcap) slen = fcap;
            memcpy(di + foff, sym_target, slen);
            cfs_put_be64(di + 56, slen);
            (void)xfs_write_dinode(fs, new_ino, di);
        }
    }

    uint8_t xft = ((full_mode & S_IFMT) == S_IFDIR) ? 2U : (((full_mode & S_IFMT) == S_IFLNK) ? 7U : 1U);
    rc = xfs_dir_push(&dl, name, new_ino, xft);
    if (rc == 0) rc = xfs_save_dir_entries(fs, dir_ino, &dl);
    free(dl.ents);
    if (rc == 0) *out_ino = new_ino;
    return rc;
}

static int xfs_rw_create(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino) {
    return xfs_create_common(fs, dir_ino, name, (uint16_t)(S_IFREG | (mode & 07777U)), NULL, out_ino);
}

static int xfs_rw_mkdir(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino) {
    return xfs_create_common(fs, dir_ino, name, (uint16_t)(S_IFDIR | (mode & 07777U)), NULL, out_ino);
}

static int xfs_rw_symlink(cowfs_t *fs, uint64_t dir_ino, const char *name, const char *target, uint64_t *out_ino) {
    return xfs_create_common(fs, dir_ino, name, (uint16_t)(S_IFLNK | 0777U), target, out_ino);
}

static int xfs_remove_common(cowfs_t *fs, uint64_t dir_ino, const char *name, int want_dir) {
    xfs_dir_list_t dl;
    int rc = xfs_load_dir_entries(fs, dir_ino, &dl);
    if (rc != 0) return rc;

    size_t idx = dl.count;
    for (size_t i = 0; i < dl.count; i++) {
        if (strcmp(dl.ents[i].name, name) == 0) { idx = i; break; }
    }
    if (idx == dl.count) {
        free(dl.ents);
        return -ENOENT;
    }

    uint64_t target_ino = dl.ents[idx].ino;
    if (want_dir) {
        xfs_dir_list_t cdl;
        if (xfs_load_dir_entries(fs, target_ino, &cdl) == 0) {
            size_t n = cdl.count;
            free(cdl.ents);
            if (n > 0) { free(dl.ents); return -ENOTEMPTY; }
        }
    }

    memmove(&dl.ents[idx], &dl.ents[idx + 1U], (dl.count - idx - 1U) * sizeof(xfs_dent_t));
    dl.count--;
    rc = xfs_save_dir_entries(fs, dir_ino, &dl);
    free(dl.ents);

    if (rc == 0) {
        uint8_t di[2048];
        if (xfs_read_dinode(fs, target_ino, di, NULL, NULL) == 0) {
            cfs_put_be16(di + 2, 0U);
            cfs_put_be32(di + 16, 0U);
            (void)xfs_write_dinode(fs, target_ino, di);
        }
    }
    return rc;
}

static int xfs_rw_unlink(cowfs_t *fs, uint64_t dir_ino, const char *name) {
    return xfs_remove_common(fs, dir_ino, name, 0);
}

static int xfs_rw_rmdir(cowfs_t *fs, uint64_t dir_ino, const char *name) {
    return xfs_remove_common(fs, dir_ino, name, 1);
}

static int xfs_rw_rename(cowfs_t *fs, uint64_t old_dir, const char *old_name, uint64_t new_dir, const char *new_name) {
    xfs_dir_list_t odl;
    int rc = xfs_load_dir_entries(fs, old_dir, &odl);
    if (rc != 0) return rc;

    size_t idx = odl.count;
    for (size_t i = 0; i < odl.count; i++) {
        if (strcmp(odl.ents[i].name, old_name) == 0) { idx = i; break; }
    }
    if (idx == odl.count) { free(odl.ents); return -ENOENT; }
    xfs_dent_t moved = odl.ents[idx];

    if (old_dir == new_dir) {
        for (size_t i = 0; i < odl.count; i++) {
            if (i != idx && strcmp(odl.ents[i].name, new_name) == 0) {
                odl.ents[i].ino = moved.ino;
                odl.ents[i].xfs_ft = moved.xfs_ft;
                memmove(&odl.ents[idx], &odl.ents[idx + 1U], (odl.count - idx - 1U) * sizeof(xfs_dent_t));
                odl.count--;
                rc = xfs_save_dir_entries(fs, old_dir, &odl);
                free(odl.ents);
                return rc;
            }
        }
        snprintf(odl.ents[idx].name, sizeof(odl.ents[idx].name), "%s", new_name);
        rc = xfs_save_dir_entries(fs, old_dir, &odl);
        free(odl.ents);
        return rc;
    }

    xfs_dir_list_t ndl;
    rc = xfs_load_dir_entries(fs, new_dir, &ndl);
    if (rc != 0) { free(odl.ents); return rc; }

    int replaced = 0;
    for (size_t i = 0; i < ndl.count; i++) {
        if (strcmp(ndl.ents[i].name, new_name) == 0) {
            ndl.ents[i].ino = moved.ino;
            ndl.ents[i].xfs_ft = moved.xfs_ft;
            replaced = 1;
            break;
        }
    }
    if (!replaced) rc = xfs_dir_push(&ndl, new_name, moved.ino, moved.xfs_ft);
    if (rc == 0) rc = xfs_save_dir_entries(fs, new_dir, &ndl);
    if (rc == 0) {
        memmove(&odl.ents[idx], &odl.ents[idx + 1U], (odl.count - idx - 1U) * sizeof(xfs_dent_t));
        odl.count--;
        rc = xfs_save_dir_entries(fs, old_dir, &odl);
    }
    free(odl.ents);
    free(ndl.ents);
    return rc;
}

static int xfs_rw_readlink(cowfs_t *fs, uint64_t ino, char *buffer, size_t buffer_cap, size_t *out_len) {
    size_t got = 0;
    int rc = xfs_rw_read(fs, ino, 0, buffer_cap - 1U, buffer, &got);
    if (rc != 0) return rc;
    buffer[got] = '\0';
    if (out_len) *out_len = got;
    return 0;
}

const cowfs_ops_t g_cowfs_xfs_ops = {
    .mount    = xfs_rw_mount,
    .unmount  = xfs_rw_unmount,
    .sync     = xfs_rw_sync,
    .root_ino = xfs_rw_root_ino,
    .statfs   = xfs_rw_statfs,
    .getattr  = xfs_rw_getattr,
    .setattr  = xfs_rw_setattr,
    .lookup   = xfs_rw_lookup,
    .readdir  = xfs_rw_readdir,
    .read     = xfs_rw_read,
    .write    = xfs_rw_write,
    .create   = xfs_rw_create,
    .mkdir    = xfs_rw_mkdir,
    .unlink   = xfs_rw_unlink,
    .rmdir    = xfs_rw_rmdir,
    .rename   = xfs_rw_rename,
    .symlink  = xfs_rw_symlink,
    .readlink = xfs_rw_readlink,
};
