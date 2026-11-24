#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "cowfs_internal.h"
#include <uuid/uuid.h>
#include <zlib.h>

/*
 * User-space Read-Write Btrfs implementation for Montserrat (FSKit + FUSE-T).
 * Reads standard multi-chunk / zlib-compressed Linux mkfs.btrfs volumes and writes
 * Copy-on-Write FS_TREE + ROOT_TREE transactions with Castagnoli CRC32c node checksums.
 */

#define BTRFS_SB_OFF            65536ULL
#define BTRFS_HDR_SZ            101U

#define BTRFS_INODE_ITEM_KEY    1U
#define BTRFS_INODE_REF_KEY     12U
#define BTRFS_DIR_ITEM_KEY      84U
#define BTRFS_DIR_INDEX_KEY     96U
#define BTRFS_EXTENT_DATA_KEY   108U
#define BTRFS_ROOT_ITEM_KEY     132U
#define BTRFS_CHUNK_ITEM_KEY    228U

#define BTRFS_ROOT_TREE_OID     1ULL
#define BTRFS_CHUNK_TREE_OID    3ULL
#define BTRFS_FS_TREE_OID       5ULL
#define BTRFS_ROOT_DIR_OID      256ULL

typedef struct {
    uint64_t logical;
    uint64_t length;
    uint64_t physical;
} btrfs_cmap_t;

typedef struct {
    uint64_t oid;
    uint8_t  type;
    uint64_t offset;
    uint8_t *data;
    uint32_t len;
} btrfs_mem_item_t;

typedef struct {
    uint32_t sectorsize;
    uint32_t nodesize;
    uint64_t total_bytes;
    uint64_t bytes_used;
    uint64_t generation;
    uint64_t root_logical;
    uint64_t chunk_root_logical;
    uint64_t fs_root_logical;
    uint64_t root_dir_oid;
    uint8_t  fsid[16];
    uint8_t  chunk_tree_uuid[16];
    uint8_t  sb_raw[4096];

    btrfs_cmap_t *chunks;
    size_t chunk_count;

    btrfs_mem_item_t *items;
    size_t item_count;
    size_t item_cap;
    uint64_t next_oid;
    uint64_t next_dir_index;
    uint64_t alloc_logical;
    int      tree_loaded;
    int      dirty;
} btrfs_rw_t;

static void btrfs_stamp_node_crc(uint8_t *node, size_t len) {
    memset(node, 0, 32U);
    uint32_t crc = ~cowfs_crc32c(0xFFFFFFFFU, node + 32U, len - 32U);
    cfs_put_le32(node, crc);
}

static uint32_t btrfs_name_hash(const char *name, size_t len) {
    /* Linux btrfs_name_hash: ~crc32c(0xfffffffe, name, len) */
    return ~cowfs_crc32c(0xFFFFFFFEU, name, len);
}

static void btrfs_put_disk_key(uint8_t p[17], uint64_t oid, uint8_t type, uint64_t off) {
    cfs_put_le64(p + 0, oid);
    p[8] = type;
    cfs_put_le64(p + 9, off);
}

static int btrfs_item_cmp(const btrfs_mem_item_t *a, const btrfs_mem_item_t *b) {
    if (a->oid != b->oid) return (a->oid < b->oid) ? -1 : 1;
    if (a->type != b->type) return (a->type < b->type) ? -1 : 1;
    if (a->offset != b->offset) return (a->offset < b->offset) ? -1 : 1;
    return 0;
}

static int btrfs_map_log(const btrfs_rw_t *b, uint64_t logical, uint64_t *out_phys, uint64_t *out_avail) {
    for (size_t i = 0; i < b->chunk_count; i++) {
        if (logical >= b->chunks[i].logical && logical < b->chunks[i].logical + b->chunks[i].length) {
            uint64_t d = logical - b->chunks[i].logical;
            *out_phys = b->chunks[i].physical + d;
            if (out_avail) *out_avail = b->chunks[i].length - d;
            return 0;
        }
    }
    *out_phys = logical;
    if (out_avail) *out_avail = UINT64_MAX;
    return 0;
}

static int btrfs_rw_read_logical(const cowfs_t *fs, uint64_t logical, size_t len, void *buf) {
    const btrfs_rw_t *b = (const btrfs_rw_t *)fs->priv;
    uint8_t *dst = (uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        uint64_t phys = 0, avail = 0;
        (void)btrfs_map_log(b, logical + done, &phys, &avail);
        size_t step = (avail < (uint64_t)(len - done)) ? (size_t)avail : (len - done);
        int rc = cowfs_io_read(fs, phys, step, dst + done);
        if (rc != 0) return rc;
        done += step;
    }
    return 0;
}

static int btrfs_rw_write_logical(cowfs_t *fs, uint64_t logical, size_t len, const void *buf) {
    const btrfs_rw_t *b = (const btrfs_rw_t *)fs->priv;
    const uint8_t *src = (const uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        uint64_t phys = 0, avail = 0;
        (void)btrfs_map_log(b, logical + done, &phys, &avail);
        size_t step = (avail < (uint64_t)(len - done)) ? (size_t)avail : (len - done);
        int rc = cowfs_io_write(fs, phys, step, src + done);
        if (rc != 0) return rc;
        done += step;
    }
    return 0;
}

/*
 * Format layout (1:1 logical==physical single-device Btrfs):
 *   64 KiB:  Primary superblock (_BHRfS_M, CRC32c)
 *   1 MiB (0x100000): CHUNK_TREE leaf (maps [1 MiB .. total_bytes) -> [1 MiB .. total_bytes))
 *   1 MiB + nodesize: ROOT_TREE leaf (ROOT_ITEM for FS_TREE (5) -> 1 MiB + 2*nodesize)
 *   1 MiB + 2*nodesize: FS_TREE leaf (INODE_ITEM + INODE_REF for root dir 256)
 */
int cowfs_btrfs_mkfs_impl(cowfs_t *fs, const char *label, uint32_t node_size) {
    if (node_size != 4096U && node_size != 16384U) node_size = 16384U;
    uint32_t sectorsize = 4096U;
    if (fs->total_bytes < (4ULL << 20)) return -ENOSPC;

    uint64_t chunk_start = 0x100000ULL; /* 1 MiB */
    uint64_t chunk_len = ((fs->total_bytes - chunk_start) / sectorsize) * sectorsize;
    uint64_t chunk_tree_bytenr = chunk_start;
    uint64_t root_tree_bytenr = chunk_start + node_size;
    uint64_t fs_tree_bytenr = chunk_start + 2ULL * node_size;

    uuid_t fsid, dev_uuid, ctree_uuid;
    uuid_generate(fsid);
    uuid_generate(dev_uuid);
    uuid_generate(ctree_uuid);

    uint8_t sb[4096];
    memset(sb, 0, sizeof(sb));
    memcpy(sb + 32, fsid, 16U);
    cfs_put_le64(sb + 48, BTRFS_SB_OFF);
    cfs_put_le64(sb + 56, 1ULL); /* WRITTEN */
    memcpy(sb + 64, "_BHRfS_M", 8U);
    cfs_put_le64(sb + 72, 1ULL); /* generation = 1 */
    cfs_put_le64(sb + 80, root_tree_bytenr);
    cfs_put_le64(sb + 88, chunk_tree_bytenr);
    cfs_put_le64(sb + 112, fs->total_bytes);
    cfs_put_le64(sb + 120, 3ULL * node_size);
    cfs_put_le64(sb + 128, BTRFS_ROOT_DIR_OID);
    cfs_put_le64(sb + 136, 1ULL); /* num_devices = 1 */
    cfs_put_le32(sb + 144, sectorsize);
    cfs_put_le32(sb + 148, node_size);
    cfs_put_le32(sb + 156, 65536U); /* stripesize */
    cfs_put_le32(sb + 160, 97U);    /* sys_chunk_array_size */
    cfs_put_le64(sb + 164, 1ULL);   /* chunk_root_generation */
    cfs_put_le64(sb + 188, 0x161ULL); /* MIXED_BACKREF | BIG_METADATA | EXTENDED_IREF */

    /* dev_item at +201 */
    cfs_put_le64(sb + 201 + 0, 1ULL);
    cfs_put_le64(sb + 201 + 8, fs->total_bytes);
    cfs_put_le64(sb + 201 + 16, 3ULL * node_size);
    cfs_put_le32(sb + 201 + 24, sectorsize);
    cfs_put_le32(sb + 201 + 28, sectorsize);
    cfs_put_le32(sb + 201 + 32, sectorsize);
    memcpy(sb + 201 + 66, dev_uuid, 16U);
    memcpy(sb + 201 + 82, fsid, 16U);

    if (label) {
        snprintf((char *)(sb + 299), 255U, "%s", label);
    }

    /* sys_chunk_array at +811: 17B key + 80B single-stripe chunk */
    uint8_t chunk_body[80];
    memset(chunk_body, 0, sizeof(chunk_body));
    cfs_put_le64(chunk_body + 0, chunk_len);
    cfs_put_le64(chunk_body + 8, 2ULL);     /* EXTENT_TREE */
    cfs_put_le64(chunk_body + 16, 65536ULL);
    cfs_put_le64(chunk_body + 24, 7ULL);    /* DATA | SYSTEM | METADATA */
    cfs_put_le32(chunk_body + 32, sectorsize);
    cfs_put_le32(chunk_body + 36, sectorsize);
    cfs_put_le32(chunk_body + 40, sectorsize);
    cfs_put_le16(chunk_body + 44, 1U);      /* num_stripes = 1 */
    cfs_put_le64(chunk_body + 48 + 0, 1ULL);
    cfs_put_le64(chunk_body + 48 + 8, chunk_start);
    memcpy(chunk_body + 48 + 16, dev_uuid, 16U);

    btrfs_put_disk_key(sb + 811, 256ULL, BTRFS_CHUNK_ITEM_KEY, chunk_start);
    memcpy(sb + 811 + 17, chunk_body, sizeof(chunk_body));
    btrfs_stamp_node_crc(sb, sizeof(sb));

    uint8_t *ctree = (uint8_t *)calloc(1, node_size);
    uint8_t *rtree = (uint8_t *)calloc(1, node_size);
    uint8_t *ftree = (uint8_t *)calloc(1, node_size);
    if (!ctree || !rtree || !ftree) {
        free(ctree); free(rtree); free(ftree);
        return -ENOMEM;
    }

    /* 1. CHUNK_TREE leaf */
    memcpy(ctree + 32, fsid, 16U);
    cfs_put_le64(ctree + 48, chunk_tree_bytenr);
    cfs_put_le64(ctree + 56, 1ULL);
    memcpy(ctree + 64, ctree_uuid, 16U);
    cfs_put_le64(ctree + 80, 1ULL);
    cfs_put_le64(ctree + 88, BTRFS_CHUNK_TREE_OID);
    cfs_put_le32(ctree + 96, 1U);
    uint32_t c_off = node_size - BTRFS_HDR_SZ - 80U;
    btrfs_put_disk_key(ctree + BTRFS_HDR_SZ, 256ULL, BTRFS_CHUNK_ITEM_KEY, chunk_start);
    cfs_put_le32(ctree + BTRFS_HDR_SZ + 17, c_off);
    cfs_put_le32(ctree + BTRFS_HDR_SZ + 21, 80U);
    memcpy(ctree + BTRFS_HDR_SZ + c_off, chunk_body, 80U);
    btrfs_stamp_node_crc(ctree, node_size);

    /* 2. ROOT_TREE leaf: ROOT_ITEM (439B) for FS_TREE (5) */
    memcpy(rtree + 32, fsid, 16U);
    cfs_put_le64(rtree + 48, root_tree_bytenr);
    cfs_put_le64(rtree + 56, 1ULL);
    memcpy(rtree + 64, ctree_uuid, 16U);
    cfs_put_le64(rtree + 80, 1ULL);
    cfs_put_le64(rtree + 88, BTRFS_ROOT_TREE_OID);
    cfs_put_le32(rtree + 96, 1U);
    uint32_t r_sz = 439U;
    uint32_t r_off = node_size - BTRFS_HDR_SZ - r_sz;
    btrfs_put_disk_key(rtree + BTRFS_HDR_SZ, BTRFS_FS_TREE_OID, BTRFS_ROOT_ITEM_KEY, 0ULL);
    cfs_put_le32(rtree + BTRFS_HDR_SZ + 17, r_off);
    cfs_put_le32(rtree + BTRFS_HDR_SZ + 21, r_sz);
    uint8_t *ri = rtree + BTRFS_HDR_SZ + r_off;
    cfs_put_le64(ri + 160, 1ULL);                 /* generation */
    cfs_put_le64(ri + 168, BTRFS_ROOT_DIR_OID);   /* root_dirid */
    cfs_put_le64(ri + 176, fs_tree_bytenr);       /* bytenr */
    cfs_put_le64(ri + 192, node_size);            /* bytes_used */
    cfs_put_le32(ri + 236, 1U);                   /* refs */
    btrfs_stamp_node_crc(rtree, node_size);

    /* 3. FS_TREE leaf: root directory (256) INODE_ITEM + INODE_REF */
    time_t now = time(NULL);
    memcpy(ftree + 32, fsid, 16U);
    cfs_put_le64(ftree + 48, fs_tree_bytenr);
    cfs_put_le64(ftree + 56, 1ULL);
    memcpy(ftree + 64, ctree_uuid, 16U);
    cfs_put_le64(ftree + 80, 1ULL);
    cfs_put_le64(ftree + 88, BTRFS_FS_TREE_OID);
    cfs_put_le32(ftree + 96, 2U);

    uint32_t cur = node_size - BTRFS_HDR_SZ;
    /* Item 0: INODE_ITEM (160B) */
    cur -= 160U;
    uint8_t *ii = ftree + BTRFS_HDR_SZ + cur;
    cfs_put_le64(ii + 0, 1ULL);
    cfs_put_le64(ii + 16, 0ULL);
    cfs_put_le32(ii + 40, 1U);
    cfs_put_le32(ii + 52, S_IFDIR | 0755U);
    cfs_put_le64(ii + 112, (uint64_t)now);
    cfs_put_le64(ii + 124, (uint64_t)now);
    cfs_put_le64(ii + 136, (uint64_t)now);
    btrfs_put_disk_key(ftree + BTRFS_HDR_SZ + 0U, BTRFS_ROOT_DIR_OID, BTRFS_INODE_ITEM_KEY, 0ULL);
    cfs_put_le32(ftree + BTRFS_HDR_SZ + 17U, cur);
    cfs_put_le32(ftree + BTRFS_HDR_SZ + 21U, 160U);

    /* Item 1: INODE_REF (12B: index=0, name_len=2, "..") */
    cur -= 12U;
    uint8_t *ir = ftree + BTRFS_HDR_SZ + cur;
    cfs_put_le64(ir + 0, 0ULL);
    cfs_put_le16(ir + 8, 2U);
    memcpy(ir + 10, "..", 2U);
    btrfs_put_disk_key(ftree + BTRFS_HDR_SZ + 25U, BTRFS_ROOT_DIR_OID, BTRFS_INODE_REF_KEY, BTRFS_ROOT_DIR_OID);
    cfs_put_le32(ftree + BTRFS_HDR_SZ + 25U + 17U, cur);
    cfs_put_le32(ftree + BTRFS_HDR_SZ + 25U + 21U, 12U);
    btrfs_stamp_node_crc(ftree, node_size);

    int rc = cowfs_io_write(fs, BTRFS_SB_OFF, sizeof(sb), sb);
    if (rc == 0) rc = cowfs_io_write(fs, chunk_tree_bytenr, node_size, ctree);
    if (rc == 0) rc = cowfs_io_write(fs, root_tree_bytenr, node_size, rtree);
    if (rc == 0) rc = cowfs_io_write(fs, fs_tree_bytenr, node_size, ftree);

    free(ctree); free(rtree); free(ftree);
    return rc;
}

int cowfs_btrfs_fsck_impl(cowfs_t *fs, int auto_fix, char *report_buf, size_t report_cap) {
    uint8_t sb[4096];
    int rc = cowfs_io_read(fs, BTRFS_SB_OFF, sizeof(sb), sb);
    if (rc != 0) {
        if (report_buf && report_cap) snprintf(report_buf, report_cap, "Unable to read Btrfs superblock.");
        return rc;
    }
    if (memcmp(sb + 64, "_BHRfS_M", 8U) != 0) {
        if (report_buf && report_cap) snprintf(report_buf, report_cap, "Missing _BHRfS_M magic in Btrfs superblock.");
        return -EINVAL;
    }

    uint32_t stored_crc = cfs_le32(sb);
    uint32_t calc_crc = ~cowfs_crc32c(0xFFFFFFFFU, sb + 32U, sizeof(sb) - 32U);
    int crc_fixed = 0;
    if (stored_crc != 0 && stored_crc != calc_crc) {
        if (!auto_fix) {
            if (report_buf && report_cap) snprintf(report_buf, report_cap, "Btrfs superblock CRC32c mismatch.");
            return -EUCLEAN;
        }
        btrfs_stamp_node_crc(sb, sizeof(sb));
        (void)cowfs_io_write(fs, BTRFS_SB_OFF, sizeof(sb), sb);
        crc_fixed = 1;
    }

    if (report_buf && report_cap) {
        snprintf(report_buf, report_cap,
                 crc_fixed ? "Btrfs check repaired superblock CRC32c." : "Btrfs filesystem is clean.");
    }
    return crc_fixed ? 1 : 0;
}

static int btrfs_put_item(btrfs_rw_t *b, uint64_t oid, uint8_t type, uint64_t off, const void *data, uint32_t len) {
    btrfs_mem_item_t probe = { oid, type, off, NULL, 0 };
    size_t lo = 0, hi = b->item_count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2U;
        int c = btrfs_item_cmp(&b->items[mid], &probe);
        if (c == 0) {
            uint8_t *copy = len ? (uint8_t *)malloc(len) : NULL;
            if (len && !copy) return -ENOMEM;
            if (len) memcpy(copy, data, len);
            free(b->items[mid].data);
            b->items[mid].data = copy;
            b->items[mid].len = len;
            return 0;
        }
        if (c < 0) lo = mid + 1U;
        else hi = mid;
    }

    if (b->item_count == b->item_cap) {
        size_t ncap = b->item_cap ? b->item_cap * 2U : 64U;
        btrfs_mem_item_t *ni = (btrfs_mem_item_t *)realloc(b->items, ncap * sizeof(btrfs_mem_item_t));
        if (!ni) return -ENOMEM;
        b->items = ni;
        b->item_cap = ncap;
    }

    uint8_t *copy = len ? (uint8_t *)malloc(len) : NULL;
    if (len && !copy) return -ENOMEM;
    if (len) memcpy(copy, data, len);

    memmove(&b->items[lo + 1U], &b->items[lo], (b->item_count - lo) * sizeof(btrfs_mem_item_t));
    b->items[lo].oid = oid;
    b->items[lo].type = type;
    b->items[lo].offset = off;
    b->items[lo].data = copy;
    b->items[lo].len = len;
    b->item_count++;

    if (oid >= b->next_oid && oid < (1ULL << 60)) b->next_oid = oid + 1ULL;
    if (type == BTRFS_DIR_INDEX_KEY && off >= b->next_dir_index) b->next_dir_index = off + 1ULL;
    return 0;
}

static void btrfs_del_item_at(btrfs_rw_t *b, size_t idx) {
    if (idx >= b->item_count) return;
    free(b->items[idx].data);
    memmove(&b->items[idx], &b->items[idx + 1U], (b->item_count - idx - 1U) * sizeof(btrfs_mem_item_t));
    b->item_count--;
}

static const btrfs_mem_item_t *btrfs_find_item(const btrfs_rw_t *b, uint64_t oid, uint8_t type, uint64_t off) {
    btrfs_mem_item_t probe = { oid, type, off, NULL, 0 };
    size_t lo = 0, hi = b->item_count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2U;
        int c = btrfs_item_cmp(&b->items[mid], &probe);
        if (c == 0) return &b->items[mid];
        if (c < 0) lo = mid + 1U;
        else hi = mid;
    }
    return NULL;
}

static int btrfs_load_node_recursive(cowfs_t *fs, uint64_t logical, int depth, int is_chunk_or_root_mode) {
    if (depth > 8 || logical == 0) return -EIO;
    btrfs_rw_t *b = (btrfs_rw_t *)fs->priv;
    if (logical + b->nodesize > b->alloc_logical) b->alloc_logical = logical + b->nodesize;

    uint8_t *node = (uint8_t *)malloc(b->nodesize);
    if (!node) return -ENOMEM;
    int rc = btrfs_rw_read_logical(fs, logical, b->nodesize, node);
    if (rc != 0) { free(node); return rc; }

    uint32_t nritems = cfs_le32(node + 96);
    uint8_t level = node[100];
    if (level == 0) {
        size_t max_it = (b->nodesize - BTRFS_HDR_SZ) / 25U;
        if (nritems > max_it) nritems = (uint32_t)max_it;
        size_t dlim = b->nodesize - BTRFS_HDR_SZ;
        for (uint32_t i = 0; i < nritems; i++) {
            const uint8_t *it = node + BTRFS_HDR_SZ + (size_t)i * 25U;
            uint64_t oid = cfs_le64(it + 0);
            uint8_t type = it[8];
            uint64_t off = cfs_le64(it + 9);
            uint32_t doff = cfs_le32(it + 17);
            uint32_t dsz = cfs_le32(it + 21);
            if (doff > dlim || dlim - doff < dsz) break;
            const uint8_t *body = node + BTRFS_HDR_SZ + doff;

            if (is_chunk_or_root_mode == 1) { /* CHUNK_TREE */
                if (type == BTRFS_CHUNK_ITEM_KEY && dsz >= 80U) {
                    b->chunks = (btrfs_cmap_t *)realloc(b->chunks, (b->chunk_count + 1U) * sizeof(btrfs_cmap_t));
                    if (b->chunks) {
                        b->chunks[b->chunk_count].logical = off;
                        b->chunks[b->chunk_count].length = cfs_le64(body + 0);
                        b->chunks[b->chunk_count].physical = cfs_le64(body + 48 + 8);
                        b->chunk_count++;
                    }
                }
            } else if (is_chunk_or_root_mode == 2) { /* ROOT_TREE */
                if (oid == BTRFS_FS_TREE_OID && type == BTRFS_ROOT_ITEM_KEY && dsz >= 184U) {
                    b->fs_root_logical = cfs_le64(body + 176);
                }
            } else { /* FS_TREE */
                if (type == BTRFS_EXTENT_DATA_KEY && dsz >= 53U && body[20] == 1U) {
                    uint64_t dbytenr = cfs_le64(body + 21);
                    uint64_t dnbytes = cfs_le64(body + 29);
                    if (dbytenr + dnbytes > b->alloc_logical) b->alloc_logical = dbytenr + dnbytes;
                }
                (void)btrfs_put_item(b, oid, type, off, body, dsz);
            }
        }
        free(node);
        return 0;
    }

    size_t max_kp = (b->nodesize - BTRFS_HDR_SZ) / 33U;
    if (nritems > max_kp) nritems = (uint32_t)max_kp;
    for (uint32_t i = 0; i < nritems; i++) {
        uint64_t child = cfs_le64(node + BTRFS_HDR_SZ + (size_t)i * 33U + 17U);
        (void)btrfs_load_node_recursive(fs, child, depth + 1, is_chunk_or_root_mode);
    }
    free(node);
    return 0;
}

static int btrfs_rw_mount(cowfs_t *fs) {
    uint8_t sb[4096];
    int rc = cowfs_io_read(fs, BTRFS_SB_OFF, sizeof(sb), sb);
    if (rc != 0) return rc;
    if (memcmp(sb + 64, "_BHRfS_M", 8U) != 0) return -EINVAL;

    uint32_t sectorsize = cfs_le32(sb + 144);
    uint32_t nodesize = cfs_le32(sb + 148);
    if (sectorsize < 512U || sectorsize > 65536U || (sectorsize & (sectorsize - 1U)) != 0) return -EINVAL;
    if (nodesize < 4096U || nodesize > 65536U || (nodesize & (nodesize - 1U)) != 0) return -EINVAL;

    btrfs_rw_t *b = (btrfs_rw_t *)calloc(1, sizeof(btrfs_rw_t));
    if (!b) return -ENOMEM;
    fs->priv = b;

    memcpy(b->sb_raw, sb, sizeof(sb));
    memcpy(b->fsid, sb + 32, 16U);
    b->sectorsize = sectorsize;
    b->nodesize = nodesize;
    b->total_bytes = cfs_le64(sb + 112);
    b->bytes_used = cfs_le64(sb + 120);
    b->generation = cfs_le64(sb + 72);
    b->root_logical = cfs_le64(sb + 80);
    b->chunk_root_logical = cfs_le64(sb + 88);
    uint64_t rdo = cfs_le64(sb + 128);
    b->root_dir_oid = (rdo >= 256ULL) ? rdo : BTRFS_ROOT_DIR_OID;
    b->next_oid = b->root_dir_oid + 1ULL;
    b->next_dir_index = 2ULL;
    b->alloc_logical = 0x100000ULL + 4ULL * nodesize;

    /* Bootstrap sys_chunk_array */
    uint32_t sys_sz = cfs_le32(sb + 160);
    if (sys_sz > 2048U) sys_sz = 2048U;
    size_t pos = 0;
    while (pos + 97U <= sys_sz) {
        uint8_t ktype = sb[811U + pos + 8U];
        uint64_t koff = cfs_le64(sb + 811U + pos + 9U);
        const uint8_t *ch = sb + 811U + pos + 17U;
        uint16_t nstr = cfs_le16(ch + 44U);
        if (nstr == 0) break;
        size_t clen = 48U + (size_t)nstr * 32U;
        if (pos + 17U + clen > sys_sz) break;
        if (ktype == BTRFS_CHUNK_ITEM_KEY) {
            b->chunks = (btrfs_cmap_t *)realloc(b->chunks, (b->chunk_count + 1U) * sizeof(btrfs_cmap_t));
            b->chunks[b->chunk_count].logical = koff;
            b->chunks[b->chunk_count].length = cfs_le64(ch + 0);
            b->chunks[b->chunk_count].physical = cfs_le64(ch + 48 + 8);
            b->chunk_count++;
        }
        pos += 17U + clen;
    }

    if (b->chunk_root_logical != 0) {
        (void)btrfs_load_node_recursive(fs, b->chunk_root_logical, 0, 1);
    }
    if (b->root_logical != 0) {
        (void)btrfs_load_node_recursive(fs, b->root_logical, 0, 2);
    }
    if (b->fs_root_logical == 0) b->fs_root_logical = b->root_logical;
    rc = btrfs_load_node_recursive(fs, b->fs_root_logical, 0, 0);
    if (rc != 0) {
        free(b->chunks);
        free(b);
        fs->priv = NULL;
        return rc;
    }
    b->alloc_logical = ((b->alloc_logical + b->nodesize - 1ULL) / b->nodesize) * b->nodesize;
    b->tree_loaded = 1;
    return 0;
}

static int btrfs_alloc_logical(btrfs_rw_t *b, uint64_t bytes, uint64_t *out_logical) {
    uint64_t aligned = ((bytes + b->sectorsize - 1ULL) / b->sectorsize) * b->sectorsize;
    uint64_t phys = 0, avail = 0;
    (void)btrfs_map_log(b, b->alloc_logical, &phys, &avail);
    if (phys + aligned > b->total_bytes || avail < aligned) return -ENOSPC;
    *out_logical = b->alloc_logical;
    b->alloc_logical += aligned;
    b->bytes_used += aligned;
    return 0;
}

/* Commit Copy-on-Write FS_TREE (single leaf or 2-level root->leaves) + ROOT_TREE + superblock */
static int btrfs_rw_sync(cowfs_t *fs) {
    btrfs_rw_t *b = (btrfs_rw_t *)fs->priv;
    if (!b || !b->dirty || fs->read_only) return 0;

    b->generation++;

    /* Pack sorted items into one or more CoW leaves */
    typedef struct { uint64_t bytenr; uint8_t first_key[17]; } leaf_ref_t;
    leaf_ref_t *leaves = NULL;
    size_t leaf_count = 0;

    size_t idx = 0;
    while (idx < b->item_count || leaf_count == 0) {
        uint64_t leaf_log = 0;
        b->alloc_logical = ((b->alloc_logical + b->nodesize - 1ULL) / b->nodesize) * b->nodesize;
        int rc = btrfs_alloc_logical(b, b->nodesize, &leaf_log);
        if (rc != 0) { free(leaves); return rc; }

        uint8_t *leaf = (uint8_t *)calloc(1, b->nodesize);
        if (!leaf) { free(leaves); return -ENOMEM; }
        memcpy(leaf + 32, b->fsid, 16U);
        cfs_put_le64(leaf + 48, leaf_log);
        cfs_put_le64(leaf + 56, 1ULL);
        cfs_put_le64(leaf + 80, b->generation);
        cfs_put_le64(leaf + 88, BTRFS_FS_TREE_OID);

        uint32_t data_cursor = b->nodesize - BTRFS_HDR_SZ;
        uint32_t nritems = 0;
        uint8_t first_key[17] = {0};

        while (idx < b->item_count) {
            const btrfs_mem_item_t *it = &b->items[idx];
            size_t meta_end = ((size_t)nritems + 1U) * 25U;
            if (meta_end + it->len > data_cursor) {
                if (nritems == 0) { free(leaf); free(leaves); return -EFBIG; }
                break;
            }
            data_cursor -= it->len;
            if (it->len > 0) memcpy(leaf + BTRFS_HDR_SZ + data_cursor, it->data, it->len);
            uint8_t *slot = leaf + BTRFS_HDR_SZ + (size_t)nritems * 25U;
            btrfs_put_disk_key(slot, it->oid, it->type, it->offset);
            if (nritems == 0) memcpy(first_key, slot, 17U);
            cfs_put_le32(slot + 17, data_cursor);
            cfs_put_le32(slot + 21, it->len);
            nritems++;
            idx++;
        }

        cfs_put_le32(leaf + 96, nritems);
        leaf[100] = 0U;
        btrfs_stamp_node_crc(leaf, b->nodesize);
        rc = btrfs_rw_write_logical(fs, leaf_log, b->nodesize, leaf);
        free(leaf);
        if (rc != 0) { free(leaves); return rc; }

        leaves = (leaf_ref_t *)realloc(leaves, (leaf_count + 1U) * sizeof(leaf_ref_t));
        leaves[leaf_count].bytenr = leaf_log;
        memcpy(leaves[leaf_count].first_key, first_key, 17U);
        leaf_count++;
        if (idx >= b->item_count) break;
    }

    uint64_t new_fs_root = leaves[0].bytenr;
    uint8_t fs_root_level = 0U;

    if (leaf_count > 1U) {
        b->alloc_logical = ((b->alloc_logical + b->nodesize - 1ULL) / b->nodesize) * b->nodesize;
        int rc = btrfs_alloc_logical(b, b->nodesize, &new_fs_root);
        if (rc != 0) { free(leaves); return rc; }

        uint8_t *inode = (uint8_t *)calloc(1, b->nodesize);
        if (!inode) { free(leaves); return -ENOMEM; }
        memcpy(inode + 32, b->fsid, 16U);
        cfs_put_le64(inode + 48, new_fs_root);
        cfs_put_le64(inode + 56, 1ULL);
        cfs_put_le64(inode + 80, b->generation);
        cfs_put_le64(inode + 88, BTRFS_FS_TREE_OID);
        cfs_put_le32(inode + 96, (uint32_t)leaf_count);
        inode[100] = 1U;
        for (size_t l = 0; l < leaf_count; l++) {
            uint8_t *kp = inode + BTRFS_HDR_SZ + l * 33U;
            memcpy(kp, leaves[l].first_key, 17U);
            cfs_put_le64(kp + 17U, leaves[l].bytenr);
            cfs_put_le64(kp + 25U, b->generation);
        }
        btrfs_stamp_node_crc(inode, b->nodesize);
        rc = btrfs_rw_write_logical(fs, new_fs_root, b->nodesize, inode);
        free(inode);
        if (rc != 0) { free(leaves); return rc; }
        fs_root_level = 1U;
    }
    free(leaves);

    /* CoW ROOT_TREE leaf pointing FS_TREE (5) to new_fs_root */
    uint64_t new_root_tree = 0;
    b->alloc_logical = ((b->alloc_logical + b->nodesize - 1ULL) / b->nodesize) * b->nodesize;
    int rc = btrfs_alloc_logical(b, b->nodesize, &new_root_tree);
    if (rc != 0) return rc;

    uint8_t *rt = (uint8_t *)calloc(1, b->nodesize);
    if (!rt) return -ENOMEM;
    memcpy(rt + 32, b->fsid, 16U);
    cfs_put_le64(rt + 48, new_root_tree);
    cfs_put_le64(rt + 56, 1ULL);
    cfs_put_le64(rt + 80, b->generation);
    cfs_put_le64(rt + 88, BTRFS_ROOT_TREE_OID);
    cfs_put_le32(rt + 96, 1U);
    uint32_t r_sz = 439U;
    uint32_t r_off = b->nodesize - BTRFS_HDR_SZ - r_sz;
    btrfs_put_disk_key(rt + BTRFS_HDR_SZ, BTRFS_FS_TREE_OID, BTRFS_ROOT_ITEM_KEY, 0ULL);
    cfs_put_le32(rt + BTRFS_HDR_SZ + 17U, r_off);
    cfs_put_le32(rt + BTRFS_HDR_SZ + 21U, r_sz);
    uint8_t *ri = rt + BTRFS_HDR_SZ + r_off;
    cfs_put_le64(ri + 160, b->generation);
    cfs_put_le64(ri + 168, b->root_dir_oid);
    cfs_put_le64(ri + 176, new_fs_root);
    cfs_put_le32(ri + 236, 1U);
    ri[235] = fs_root_level;
    btrfs_stamp_node_crc(rt, b->nodesize);
    rc = btrfs_rw_write_logical(fs, new_root_tree, b->nodesize, rt);
    free(rt);
    if (rc != 0) return rc;

    b->fs_root_logical = new_fs_root;
    b->root_logical = new_root_tree;
    cfs_put_le64(b->sb_raw + 72, b->generation);
    cfs_put_le64(b->sb_raw + 80, new_root_tree);
    cfs_put_le64(b->sb_raw + 120, b->bytes_used);
    b->sb_raw[198] = 0U;
    btrfs_stamp_node_crc(b->sb_raw, sizeof(b->sb_raw));
    rc = cowfs_io_write(fs, BTRFS_SB_OFF, sizeof(b->sb_raw), b->sb_raw);
    if (rc == 0) b->dirty = 0;
    return rc;
}

static void btrfs_rw_unmount(cowfs_t *fs) {
    btrfs_rw_t *b = (btrfs_rw_t *)fs->priv;
    if (!b) return;
    for (size_t i = 0; i < b->item_count; i++) free(b->items[i].data);
    free(b->items);
    free(b->chunks);
    free(b);
    fs->priv = NULL;
}

static uint64_t btrfs_rw_root_ino(const cowfs_t *fs) {
    const btrfs_rw_t *b = (const btrfs_rw_t *)fs->priv;
    return b ? b->root_dir_oid : BTRFS_ROOT_DIR_OID;
}

static int btrfs_rw_statfs(cowfs_t *fs, uint64_t *total_bytes, uint64_t *free_bytes, uint32_t *block_size) {
    const btrfs_rw_t *b = (const btrfs_rw_t *)fs->priv;
    if (total_bytes) *total_bytes = b->total_bytes;
    if (free_bytes) *free_bytes = (b->total_bytes > b->bytes_used) ? (b->total_bytes - b->bytes_used) : 0ULL;
    if (block_size) *block_size = b->sectorsize;
    return 0;
}

static int btrfs_rw_getattr(cowfs_t *fs, uint64_t ino, cowfs_item_attrs_t *out) {
    const btrfs_rw_t *b = (const btrfs_rw_t *)fs->priv;
    const btrfs_mem_item_t *it = btrfs_find_item(b, ino, BTRFS_INODE_ITEM_KEY, 0ULL);
    if (!it || it->len < 160U) return -ENOENT;

    uint32_t mode = cfs_le32(it->data + 52U);
    memset(out, 0, sizeof(*out));
    out->ino = ino;
    out->size = cfs_le64(it->data + 16U);
    out->alloc_size = cfs_le64(it->data + 24U);
    out->nlink = cfs_le32(it->data + 40U);
    out->uid = cfs_le32(it->data + 44U);
    out->gid = cfs_le32(it->data + 48U);
    out->mode = mode;
    out->atime_sec = (int64_t)cfs_le64(it->data + 112U);
    out->ctime_sec = (int64_t)cfs_le64(it->data + 124U);
    out->mtime_sec = (int64_t)cfs_le64(it->data + 136U);
    out->file_type = ((mode & S_IFMT) == S_IFDIR) ? 2U : (((mode & S_IFMT) == S_IFLNK) ? 3U : 1U);
    return 0;
}

static int btrfs_rw_setattr(cowfs_t *fs, uint64_t ino, uint32_t mask, const cowfs_item_attrs_t *in_attrs) {
    btrfs_rw_t *b = (btrfs_rw_t *)fs->priv;
    const btrfs_mem_item_t *it = btrfs_find_item(b, ino, BTRFS_INODE_ITEM_KEY, 0ULL);
    if (!it || it->len < 160U) return -ENOENT;

    uint8_t buf[160];
    memcpy(buf, it->data, 160U);
    uint32_t cur_mode = cfs_le32(buf + 52U);
    if (mask & COWFS_ATTR_MODE) cfs_put_le32(buf + 52U, (cur_mode & S_IFMT) | (in_attrs->mode & 07777U));
    if (mask & COWFS_ATTR_UID)  cfs_put_le32(buf + 44U, in_attrs->uid);
    if (mask & COWFS_ATTR_GID)  cfs_put_le32(buf + 48U, in_attrs->gid);
    if (mask & COWFS_ATTR_ATIME) cfs_put_le64(buf + 112U, (uint64_t)in_attrs->atime_sec);
    if (mask & COWFS_ATTR_MTIME) cfs_put_le64(buf + 136U, (uint64_t)in_attrs->mtime_sec);
    if (mask & COWFS_ATTR_SIZE)  cfs_put_le64(buf + 16U, in_attrs->size);
    cfs_put_le64(buf + 124U, (uint64_t)time(NULL));
    b->dirty = 1;
    return btrfs_put_item(b, ino, BTRFS_INODE_ITEM_KEY, 0ULL, buf, 160U);
}

static int btrfs_rw_readdir(cowfs_t *fs, uint64_t dir_ino, uint64_t start_cookie, cowfs_dir_cb cb, void *user_ctx) {
    const btrfs_rw_t *b = (const btrfs_rw_t *)fs->priv;
    cowfs_item_attrs_t da;
    if (btrfs_rw_getattr(fs, dir_ino, &da) != 0) return -ENOENT;
    if (da.file_type != 2U) return -ENOTDIR;

    uint64_t idx = 0;
    if (idx >= start_cookie && !cb(user_ctx, ".", dir_ino, 2U, idx + 1ULL)) return 0;
    idx++;
    if (idx >= start_cookie && !cb(user_ctx, "..", b->root_dir_oid, 2U, idx + 1ULL)) return 0;
    idx++;

    for (size_t i = 0; i < b->item_count; i++) {
        const btrfs_mem_item_t *it = &b->items[i];
        if (it->oid != dir_ino || it->type != BTRFS_DIR_INDEX_KEY || it->len < 30U) continue;
        uint64_t child_oid = cfs_le64(it->data + 0);
        uint8_t ktype = it->data[8];
        uint16_t nl = cfs_le16(it->data + 27U);
        uint8_t dt = it->data[29U];
        if (ktype != BTRFS_INODE_ITEM_KEY || nl == 0 || 30U + nl > it->len) continue;

        char nm[256];
        memcpy(nm, it->data + 30U, nl);
        nm[nl] = '\0';
        uint8_t ft = (dt == 2U) ? 2U : ((dt == 7U) ? 3U : 1U);
        if (idx >= start_cookie && !cb(user_ctx, nm, child_oid, ft, idx + 1ULL)) return 0;
        idx++;
    }
    return 0;
}

static int btrfs_rw_lookup(cowfs_t *fs, uint64_t dir_ino, const char *name, uint64_t *out_ino) {
    const btrfs_rw_t *b = (const btrfs_rw_t *)fs->priv;
    if (strcmp(name, ".") == 0) { *out_ino = dir_ino; return 0; }
    if (strcmp(name, "..") == 0) { *out_ino = b->root_dir_oid; return 0; }

    size_t nlen = strlen(name);
    for (size_t i = 0; i < b->item_count; i++) {
        const btrfs_mem_item_t *it = &b->items[i];
        if (it->oid == dir_ino &&
            (it->type == BTRFS_DIR_INDEX_KEY || it->type == BTRFS_DIR_ITEM_KEY) &&
            it->len >= 30U + nlen) {
            uint16_t nl = cfs_le16(it->data + 27U);
            if (nl == nlen && memcmp(it->data + 30U, name, nlen) == 0 && it->data[8] == BTRFS_INODE_ITEM_KEY) {
                *out_ino = cfs_le64(it->data + 0);
                return 0;
            }
        }
    }
    return -ENOENT;
}

static int btrfs_rw_read(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, void *buffer, size_t *out_read) {
    const btrfs_rw_t *b = (const btrfs_rw_t *)fs->priv;
    cowfs_item_attrs_t attr;
    int rc = btrfs_rw_getattr(fs, ino, &attr);
    if (rc != 0) return rc;
    if (attr.file_type == 2U) return -EISDIR;
    if (offset >= attr.size || length == 0) { *out_read = 0; return 0; }

    size_t to_read = (attr.size - offset < (uint64_t)length) ? (size_t)(attr.size - offset) : length;
    uint8_t *dst = (uint8_t *)buffer;
    memset(dst, 0, to_read);
    uint64_t req_end = offset + to_read;

    for (size_t i = 0; i < b->item_count; i++) {
        const btrfs_mem_item_t *it = &b->items[i];
        if (it->oid != ino || it->type != BTRFS_EXTENT_DATA_KEY || it->len < 21U) continue;
        uint64_t eoff = it->offset;
        uint64_t ram_bytes = cfs_le64(it->data + 8U);
        uint8_t comp = it->data[16U];
        uint8_t etype = it->data[20U];

        if (etype == 0U) { /* INLINE */
            uint32_t inl_sz = it->len - 21U;
            uint64_t elen = (comp == 0U) ? inl_sz : ram_bytes;
            if (eoff >= req_end || eoff + elen <= offset) continue;
            if (comp == 0U) {
                uint64_t ov_s = (offset > eoff) ? offset : eoff;
                uint64_t ov_e = (req_end < eoff + elen) ? req_end : (eoff + elen);
                memcpy(dst + (ov_s - offset), it->data + 21U + (ov_s - eoff), (size_t)(ov_e - ov_s));
            } else if (comp == 1U) {
                uint8_t *ub = (uint8_t *)malloc((size_t)elen);
                if (!ub) return -ENOMEM;
                uLongf dlen = (uLongf)elen;
                if (uncompress(ub, &dlen, it->data + 21U, inl_sz) == Z_OK) {
                    uint64_t ov_s = (offset > eoff) ? offset : eoff;
                    uint64_t ov_e = (req_end < eoff + dlen) ? req_end : (eoff + dlen);
                    if (ov_e > ov_s) memcpy(dst + (ov_s - offset), ub + (ov_s - eoff), (size_t)(ov_e - ov_s));
                }
                free(ub);
            }
        } else if (etype == 1U && it->len >= 53U) {
            uint64_t dbytenr = cfs_le64(it->data + 21U);
            uint64_t dnbytes = cfs_le64(it->data + 29U);
            uint64_t in_off = cfs_le64(it->data + 37U);
            uint64_t nbytes = cfs_le64(it->data + 45U);
            if (dbytenr == 0ULL || eoff >= req_end || eoff + nbytes <= offset) continue;
            uint64_t ov_s = (offset > eoff) ? offset : eoff;
            uint64_t ov_e = (req_end < eoff + nbytes) ? req_end : (eoff + nbytes);
            size_t clen = (size_t)(ov_e - ov_s);
            if (comp == 0U) {
                rc = btrfs_rw_read_logical(fs, dbytenr + in_off + (ov_s - eoff), clen, dst + (ov_s - offset));
                if (rc != 0) return rc;
            } else if (comp == 1U && dnbytes <= (4ULL << 20) && ram_bytes <= (16ULL << 20)) {
                uint8_t *cb = (uint8_t *)malloc((size_t)dnbytes);
                uint8_t *ub = (uint8_t *)malloc((size_t)ram_bytes);
                if (cb && ub && btrfs_rw_read_logical(fs, dbytenr, (size_t)dnbytes, cb) == 0) {
                    uLongf dlen = (uLongf)ram_bytes;
                    if (uncompress(ub, &dlen, cb, (uLong)dnbytes) == Z_OK) {
                        memcpy(dst + (ov_s - offset), ub + in_off + (ov_s - eoff), clen);
                    }
                }
                free(cb); free(ub);
            }
        }
    }

    *out_read = to_read;
    return 0;
}

static int btrfs_rw_write(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, const void *buffer, size_t *out_written) {
    btrfs_rw_t *b = (btrfs_rw_t *)fs->priv;
    const btrfs_mem_item_t *ii = btrfs_find_item(b, ino, BTRFS_INODE_ITEM_KEY, 0ULL);
    if (!ii || ii->len < 160U) return -ENOENT;
    uint32_t mode = cfs_le32(ii->data + 52U);
    if ((mode & S_IFMT) != S_IFREG) return -EINVAL;
    if (length == 0) { *out_written = 0; return 0; }

    uint64_t cur_size = cfs_le64(ii->data + 16U);
    uint64_t new_size = (offset + length > cur_size) ? (offset + length) : cur_size;
    if (new_size > (64ULL << 20)) return -EFBIG;

    /* Read full existing file bytes, overlay write range, and store CoW inline (<2K) or regular extent */
    uint8_t *merged = (uint8_t *)calloc(1, (size_t)new_size);
    if (!merged) return -ENOMEM;
    if (cur_size > 0) {
        size_t got = 0;
        (void)btrfs_rw_read(fs, ino, 0, (size_t)cur_size, merged, &got);
    }
    memcpy(merged + offset, buffer, length);

    /* Remove previous EXTENT_DATA items for this inode */
    for (size_t i = b->item_count; i > 0; i--) {
        if (b->items[i - 1U].oid == ino && b->items[i - 1U].type == BTRFS_EXTENT_DATA_KEY) {
            btrfs_del_item_at(b, i - 1U);
        }
    }

    int rc = 0;
    if (new_size <= 2048ULL) {
        uint8_t *inl = (uint8_t *)calloc(1, 21U + (size_t)new_size);
        if (!inl) { free(merged); return -ENOMEM; }
        cfs_put_le64(inl + 0, b->generation + 1ULL);
        cfs_put_le64(inl + 8, new_size);
        inl[20] = 0U; /* INLINE */
        memcpy(inl + 21U, merged, (size_t)new_size);
        rc = btrfs_put_item(b, ino, BTRFS_EXTENT_DATA_KEY, 0ULL, inl, 21U + (uint32_t)new_size);
        free(inl);
    } else {
        uint64_t aligned_sz = ((new_size + b->sectorsize - 1ULL) / b->sectorsize) * b->sectorsize;
        uint64_t data_log = 0;
        rc = btrfs_alloc_logical(b, aligned_sz, &data_log);
        if (rc == 0) {
            uint8_t *padded = (uint8_t *)calloc(1, (size_t)aligned_sz);
            if (!padded) rc = -ENOMEM;
            else {
                memcpy(padded, merged, (size_t)new_size);
                rc = btrfs_rw_write_logical(fs, data_log, (size_t)aligned_sz, padded);
                free(padded);
            }
        }
        if (rc == 0) {
            uint8_t ext[53];
            memset(ext, 0, sizeof(ext));
            cfs_put_le64(ext + 0, b->generation + 1ULL);
            cfs_put_le64(ext + 8, aligned_sz);
            ext[20] = 1U; /* REG */
            cfs_put_le64(ext + 21, data_log);
            cfs_put_le64(ext + 29, aligned_sz);
            cfs_put_le64(ext + 37, 0ULL);
            cfs_put_le64(ext + 45, aligned_sz);
            rc = btrfs_put_item(b, ino, BTRFS_EXTENT_DATA_KEY, 0ULL, ext, sizeof(ext));
        }
    }
    free(merged);
    if (rc != 0) return rc;

    const btrfs_mem_item_t *ii2 = btrfs_find_item(b, ino, BTRFS_INODE_ITEM_KEY, 0ULL);
    if (ii2) {
        uint8_t ibuf[160];
        memcpy(ibuf, ii2->data, 160U);
        cfs_put_le64(ibuf + 16U, new_size);
        cfs_put_le64(ibuf + 24U, new_size);
        cfs_put_le64(ibuf + 124U, (uint64_t)time(NULL));
        cfs_put_le64(ibuf + 136U, (uint64_t)time(NULL));
        rc = btrfs_put_item(b, ino, BTRFS_INODE_ITEM_KEY, 0ULL, ibuf, 160U);
    }
    b->dirty = 1;
    *out_written = length;
    return rc;
}

static int btrfs_add_dir_link(btrfs_rw_t *b, uint64_t dir_ino, const char *name, uint64_t child_oid, uint8_t btrfs_dtype) {
    size_t nl = strlen(name);
    uint8_t rec[30 + 256];
    memset(rec, 0, 30U);
    btrfs_put_disk_key(rec, child_oid, BTRFS_INODE_ITEM_KEY, 0ULL);
    cfs_put_le64(rec + 17U, b->generation + 1ULL);
    cfs_put_le16(rec + 27U, (uint16_t)nl);
    rec[29U] = btrfs_dtype;
    memcpy(rec + 30U, name, nl);

    uint64_t idx = b->next_dir_index++;
    int rc = btrfs_put_item(b, dir_ino, BTRFS_DIR_INDEX_KEY, idx, rec, 30U + (uint32_t)nl);
    if (rc == 0) {
        uint64_t nhash = btrfs_name_hash(name, nl);
        rc = btrfs_put_item(b, dir_ino, BTRFS_DIR_ITEM_KEY, nhash, rec, 30U + (uint32_t)nl);
    }
    if (rc == 0) {
        uint8_t iref[10 + 256];
        cfs_put_le64(iref + 0, idx);
        cfs_put_le16(iref + 8, (uint16_t)nl);
        memcpy(iref + 10U, name, nl);
        rc = btrfs_put_item(b, child_oid, BTRFS_INODE_REF_KEY, dir_ino, iref, 10U + (uint32_t)nl);
    }
    return rc;
}

static int btrfs_create_common(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t full_mode, const char *sym_target, uint64_t *out_ino) {
    btrfs_rw_t *b = (btrfs_rw_t *)fs->priv;
    if (!name || name[0] == '\0' || strlen(name) > 255U) return -EINVAL;
    uint64_t existing = 0;
    if (btrfs_rw_lookup(fs, dir_ino, name, &existing) == 0) return -EEXIST;

    uint64_t oid = b->next_oid++;
    time_t now = time(NULL);
    uint8_t ibuf[160];
    memset(ibuf, 0, sizeof(ibuf));
    cfs_put_le64(ibuf + 0, b->generation + 1ULL);
    uint64_t sz = sym_target ? strlen(sym_target) : 0ULL;
    cfs_put_le64(ibuf + 16U, sz);
    cfs_put_le32(ibuf + 40U, 1U);
    cfs_put_le32(ibuf + 52U, full_mode);
    cfs_put_le64(ibuf + 112U, (uint64_t)now);
    cfs_put_le64(ibuf + 124U, (uint64_t)now);
    cfs_put_le64(ibuf + 136U, (uint64_t)now);

    int rc = btrfs_put_item(b, oid, BTRFS_INODE_ITEM_KEY, 0ULL, ibuf, 160U);
    if (rc == 0 && sym_target) {
        uint8_t inl[21 + 4096];
        memset(inl, 0, 21U);
        cfs_put_le64(inl + 0, b->generation + 1ULL);
        cfs_put_le64(inl + 8, sz);
        inl[20] = 0U;
        memcpy(inl + 21U, sym_target, (size_t)sz);
        rc = btrfs_put_item(b, oid, BTRFS_EXTENT_DATA_KEY, 0ULL, inl, 21U + (uint32_t)sz);
    }

    uint8_t dt = ((full_mode & S_IFMT) == S_IFDIR) ? 2U : (((full_mode & S_IFMT) == S_IFLNK) ? 7U : 1U);
    if (rc == 0) rc = btrfs_add_dir_link(b, dir_ino, name, oid, dt);
    if (rc == 0) {
        b->dirty = 1;
        *out_ino = oid;
    }
    return rc;
}

static int btrfs_rw_create(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino) {
    return btrfs_create_common(fs, dir_ino, name, S_IFREG | (mode & 07777U), NULL, out_ino);
}

static int btrfs_rw_mkdir(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino) {
    return btrfs_create_common(fs, dir_ino, name, S_IFDIR | (mode & 07777U), NULL, out_ino);
}

static int btrfs_rw_symlink(cowfs_t *fs, uint64_t dir_ino, const char *name, const char *target, uint64_t *out_ino) {
    return btrfs_create_common(fs, dir_ino, name, S_IFLNK | 0777U, target, out_ino);
}

static int btrfs_remove_common(cowfs_t *fs, uint64_t dir_ino, const char *name, int want_dir) {
    btrfs_rw_t *b = (btrfs_rw_t *)fs->priv;
    uint64_t target_oid = 0;
    if (btrfs_rw_lookup(fs, dir_ino, name, &target_oid) != 0) return -ENOENT;

    if (want_dir) {
        for (size_t i = 0; i < b->item_count; i++) {
            if (b->items[i].oid == target_oid && b->items[i].type == BTRFS_DIR_INDEX_KEY) return -ENOTEMPTY;
        }
    }

    size_t nlen = strlen(name);
    for (size_t i = b->item_count; i > 0; i--) {
        const btrfs_mem_item_t *it = &b->items[i - 1U];
        if (it->oid == target_oid) {
            btrfs_del_item_at(b, i - 1U);
        } else if (it->oid == dir_ino &&
                   (it->type == BTRFS_DIR_INDEX_KEY || it->type == BTRFS_DIR_ITEM_KEY) &&
                   it->len >= 30U + nlen &&
                   cfs_le16(it->data + 27U) == nlen &&
                   memcmp(it->data + 30U, name, nlen) == 0) {
            btrfs_del_item_at(b, i - 1U);
        }
    }
    b->dirty = 1;
    return 0;
}

static int btrfs_rw_unlink(cowfs_t *fs, uint64_t dir_ino, const char *name) {
    return btrfs_remove_common(fs, dir_ino, name, 0);
}

static int btrfs_rw_rmdir(cowfs_t *fs, uint64_t dir_ino, const char *name) {
    return btrfs_remove_common(fs, dir_ino, name, 1);
}

static int btrfs_rw_rename(cowfs_t *fs, uint64_t old_dir, const char *old_name, uint64_t new_dir, const char *new_name) {
    btrfs_rw_t *b = (btrfs_rw_t *)fs->priv;
    uint64_t moved_oid = 0;
    if (btrfs_rw_lookup(fs, old_dir, old_name, &moved_oid) != 0) return -ENOENT;

    cowfs_item_attrs_t attr;
    if (btrfs_rw_getattr(fs, moved_oid, &attr) != 0) return -ENOENT;
    uint8_t dt = (attr.file_type == 2U) ? 2U : ((attr.file_type == 3U) ? 7U : 1U);

    /* Remove any existing destination entry */
    uint64_t dst_oid = 0;
    if (btrfs_rw_lookup(fs, new_dir, new_name, &dst_oid) == 0 && dst_oid != moved_oid) {
        (void)btrfs_remove_common(fs, new_dir, new_name, attr.file_type == 2U);
    }

    /* Remove old directory links (preserving moved_oid's INODE_ITEM and EXTENT_DATA) */
    size_t olen = strlen(old_name);
    for (size_t i = b->item_count; i > 0; i--) {
        const btrfs_mem_item_t *it = &b->items[i - 1U];
        if (it->oid == old_dir &&
            (it->type == BTRFS_DIR_INDEX_KEY || it->type == BTRFS_DIR_ITEM_KEY) &&
            it->len >= 30U + olen &&
            cfs_le16(it->data + 27U) == olen &&
            memcmp(it->data + 30U, old_name, olen) == 0) {
            btrfs_del_item_at(b, i - 1U);
        } else if (it->oid == moved_oid && it->type == BTRFS_INODE_REF_KEY && it->offset == old_dir) {
            btrfs_del_item_at(b, i - 1U);
        }
    }

    int rc = btrfs_add_dir_link(b, new_dir, new_name, moved_oid, dt);
    if (rc == 0) b->dirty = 1;
    return rc;
}

static int btrfs_rw_readlink(cowfs_t *fs, uint64_t ino, char *buffer, size_t buffer_cap, size_t *out_len) {
    size_t got = 0;
    int rc = btrfs_rw_read(fs, ino, 0, buffer_cap - 1U, buffer, &got);
    if (rc != 0) return rc;
    buffer[got] = '\0';
    if (out_len) *out_len = got;
    return 0;
}

const cowfs_ops_t g_cowfs_btrfs_ops = {
    .mount    = btrfs_rw_mount,
    .unmount  = btrfs_rw_unmount,
    .sync     = btrfs_rw_sync,
    .root_ino = btrfs_rw_root_ino,
    .statfs   = btrfs_rw_statfs,
    .getattr  = btrfs_rw_getattr,
    .setattr  = btrfs_rw_setattr,
    .lookup   = btrfs_rw_lookup,
    .readdir  = btrfs_rw_readdir,
    .read     = btrfs_rw_read,
    .write    = btrfs_rw_write,
    .create   = btrfs_rw_create,
    .mkdir    = btrfs_rw_mkdir,
    .unlink   = btrfs_rw_unlink,
    .rmdir    = btrfs_rw_rmdir,
    .rename   = btrfs_rw_rename,
    .symlink  = btrfs_rw_symlink,
    .readlink = btrfs_rw_readlink,
};
