#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "cowfs_internal.h"
#include <ctype.h>
#include <fcntl.h>
#include <unistd.h>

/*
 * Multi-Disk LVM2 Logical Volume Assembly (Linear + Striped across 1..N PVs)
 * and Linux mdadm Software RAID-0 / RAID-1 / RAID-5 Read-Only Assembly
 * (v0.90, v1.0, v1.1, v1.2 metadata + single-disk degraded XOR parity recovery).
 */

static int fd_pread_aligned(int fd, uint32_t align, uint64_t off, size_t len, void *buf) {
    if (len == 0) return 0;
    if (align <= 1U || ((off % align) == 0 && (len % align) == 0)) {
        uint8_t *dst = (uint8_t *)buf;
        size_t done = 0;
        while (done < len) {
            ssize_t r = pread(fd, dst + done, len - done, (off_t)(off + done));
            if (r <= 0) return -EIO;
            done += (size_t)r;
        }
        return 0;
    }
    uint64_t a_start = (off / align) * align;
    uint64_t a_end = ((off + len + align - 1ULL) / align) * align;
    size_t a_len = (size_t)(a_end - a_start);
    uint8_t *tmp = (uint8_t *)malloc(a_len);
    if (!tmp) return -ENOMEM;
    size_t done = 0;
    while (done < a_len) {
        ssize_t r = pread(fd, tmp + done, a_len - done, (off_t)(a_start + done));
        if (r <= 0) { free(tmp); return -EIO; }
        done += (size_t)r;
    }
    memcpy(buf, tmp + (size_t)(off - a_start), len);
    free(tmp);
    return 0;
}

static int fd_pwrite_aligned(int fd, uint32_t align, uint64_t off, size_t len, const void *buf) {
    if (len == 0) return 0;
    if (align <= 1U || ((off % align) == 0 && (len % align) == 0)) {
        const uint8_t *src = (const uint8_t *)buf;
        size_t done = 0;
        while (done < len) {
            ssize_t w = pwrite(fd, src + done, len - done, (off_t)(off + done));
            if (w <= 0) return -EIO;
            done += (size_t)w;
        }
        return 0;
    }
    uint64_t a_start = (off / align) * align;
    uint64_t a_end = ((off + len + align - 1ULL) / align) * align;
    size_t a_len = (size_t)(a_end - a_start);
    uint8_t *tmp = (uint8_t *)malloc(a_len);
    if (!tmp) return -ENOMEM;
    if (fd_pread_aligned(fd, align, a_start, a_len, tmp) != 0) {
        free(tmp);
        return -EIO;
    }
    memcpy(tmp + (size_t)(off - a_start), buf, len);
    size_t done = 0;
    while (done < a_len) {
        ssize_t w = pwrite(fd, tmp + done, a_len - done, (off_t)(a_start + done));
        if (w <= 0) { free(tmp); return -EIO; }
        done += (size_t)w;
    }
    free(tmp);
    return 0;
}

/* ---------------- Multi-PV LVM2 Logical Volume Assembly ---------------- */

#define MAX_LVM_PVS      16U
#define MAX_LVM_STRIPES  16U
#define MAX_LVM_SEGS     64U

typedef struct {
    int      fd;
    uint32_t align;
    uint64_t dev_size;
    uint64_t pe_start;
    char     pv_name[64]; /* e.g. "pv0" in VG metadata */
    char     pv_uuid[64]; /* formatted 6-4-4-4-4-4-6 */
} lvm_pv_slot_t;

typedef struct {
    uint64_t start_extent;
    uint64_t extent_count;
    uint32_t stripe_count;
    uint64_t stripe_bytes; /* used when stripe_count > 1 */
    int      pv_idx[MAX_LVM_STRIPES];
    uint64_t start_pe[MAX_LVM_STRIPES];
} lvm_segment_t;

struct cowfs_lvm_lv_ctx {
    int            read_only;
    pthread_mutex_t lock;
    char           vg_name[64];
    char           lv_name[64];
    uint64_t       extent_bytes;
    uint64_t       total_bytes;
    size_t         pv_count;
    lvm_pv_slot_t  pvs[MAX_LVM_PVS];
    size_t         seg_count;
    lvm_segment_t  segs[MAX_LVM_SEGS];
};

static const char *skip_ws(const char *p, const char *end) {
    while (p < end) {
        while (p < end && isspace((unsigned char)*p)) p++;
        if (p < end && *p == '#') {
            while (p < end && *p != '\n') p++;
        } else {
            break;
        }
    }
    return p;
}

static int parse_ident(const char **pp, const char *end, char *out, size_t cap) {
    const char *p = skip_ws(*pp, end);
    if (p >= end) return -1;
    size_t i = 0;
    if (*p == '"') {
        p++;
        while (p < end && *p != '"') {
            if (i + 1U < cap) out[i++] = *p;
            p++;
        }
        if (p < end && *p == '"') p++;
    } else {
        while (p < end && (isalnum((unsigned char)*p) || *p == '_' || *p == '-' || *p == '.')) {
            if (i + 1U < cap) out[i++] = *p;
            p++;
        }
    }
    if (i == 0) return -1;
    out[i] = '\0';
    *pp = p;
    return 0;
}

static const char *match_brace(const char *open_b, const char *end) {
    if (!open_b || open_b >= end || *open_b != '{') return NULL;
    int depth = 0, in_str = 0;
    for (const char *p = open_b; p < end; p++) {
        if (*p == '#' && !in_str) {
            while (p < end && *p != '\n') p++;
            if (p >= end) break;
        } else if (*p == '"') {
            in_str = !in_str;
        } else if (!in_str) {
            if (*p == '{') depth++;
            else if (*p == '}') {
                depth--;
                if (depth == 0) return p + 1;
            }
        }
    }
    return NULL;
}

static int find_u64_prop(const char *start, const char *end, const char *prop, uint64_t *out) {
    size_t plen = strlen(prop);
    for (const char *p = start; p + plen < end; p++) {
        if (memcmp(p, prop, plen) == 0 &&
            (p == start || (!isalnum((unsigned char)p[-1]) && p[-1] != '_')) &&
            !isalnum((unsigned char)p[plen]) && p[plen] != '_') {
            const char *q = skip_ws(p + plen, end);
            if (q < end && *q == '=') {
                q = skip_ws(q + 1, end);
                if (q < end && isdigit((unsigned char)*q)) {
                    *out = strtoull(q, NULL, 10);
                    return 0;
                }
            }
        }
    }
    return -ENOENT;
}

static int find_str_prop(const char *start, const char *end, const char *prop, char *out, size_t cap) {
    size_t plen = strlen(prop);
    for (const char *p = start; p + plen < end; p++) {
        if (memcmp(p, prop, plen) == 0 &&
            (p == start || (!isalnum((unsigned char)p[-1]) && p[-1] != '_')) &&
            !isalnum((unsigned char)p[plen]) && p[plen] != '_') {
            const char *q = skip_ws(p + plen, end);
            if (q < end && *q == '=') {
                q = skip_ws(q + 1, end);
                return parse_ident(&q, end, out, cap);
            }
        }
    }
    return -ENOENT;
}

static void normalize_uuid_alnum(const char *in, char *out, size_t cap) {
    size_t o = 0;
    for (size_t i = 0; in[i] && o + 1U < cap; i++) {
        if (isalnum((unsigned char)in[i])) out[o++] = in[i];
    }
    out[o] = '\0';
}

static int read_pv_header_and_mda(
    lvm_pv_slot_t *slot,
    char **out_meta
) {
    uint8_t sec[512];
    int found = 0;
    for (uint64_t s = 0; s < 4ULL; s++) {
        if (fd_pread_aligned(slot->fd, slot->align, s * 512ULL, sizeof(sec), sec) == 0 &&
            memcmp(sec, "LABELONE", 8) == 0 &&
            memcmp(sec + 24, "LVM2 001", 8) == 0) {
            found = 1;
            break;
        }
    }
    if (!found) return -EINVAL;

    uint32_t pv_hdr_rel = cfs_le32(sec + 20);
    if (pv_hdr_rel < 32U || pv_hdr_rel + 80U > 512U) return -EINVAL;

    char raw_uuid[33];
    memcpy(raw_uuid, sec + pv_hdr_rel, 32);
    raw_uuid[32] = '\0';
    snprintf(slot->pv_uuid, sizeof(slot->pv_uuid),
             "%.6s-%.4s-%.4s-%.4s-%.4s-%.4s-%.6s",
             raw_uuid, raw_uuid + 6, raw_uuid + 10, raw_uuid + 14,
             raw_uuid + 18, raw_uuid + 22, raw_uuid + 26);

    slot->pe_start = 1048576ULL;
    uint64_t mda_off = 4096ULL, mda_sz = 0ULL;
    size_t pos = pv_hdr_rel + 40U;
    int first_da = 1;
    while (pos + 16U <= 512U) {
        uint64_t d_off = cfs_le64(sec + pos);
        uint64_t d_sz = cfs_le64(sec + pos + 8);
        pos += 16U;
        if (d_off == 0 && d_sz == 0) break;
        if (first_da) { slot->pe_start = d_off; first_da = 0; }
    }
    while (pos + 16U <= 512U) {
        uint64_t mo = cfs_le64(sec + pos);
        uint64_t ms = cfs_le64(sec + pos + 8);
        pos += 16U;
        if (mo == 0 && ms == 0) break;
        mda_off = mo;
        mda_sz = ms;
        break;
    }

    if (!out_meta || *out_meta != NULL) return 0;

    static const uint8_t k_fmtt[16] = {
        ' ', 'L', 'V', 'M', '2', ' ', 'x', '[', '5', 'A', '%', 'r', '0', 'N', '*', '>'
    };
    uint8_t mdah[512];
    if (fd_pread_aligned(slot->fd, slot->align, mda_off, sizeof(mdah), mdah) != 0 ||
        memcmp(mdah + 4, k_fmtt, 16) != 0) {
        return 0;
    }
    if (mda_sz == 0) mda_sz = cfs_le64(mdah + 32);
    uint64_t rloc_off = cfs_le64(mdah + 40);
    uint64_t rloc_sz = cfs_le64(mdah + 48);
    if (rloc_off == 0 || rloc_sz == 0 || rloc_sz > (2ULL << 20)) return 0;

    char *meta = (char *)calloc(1, (size_t)rloc_sz + 1U);
    if (!meta) return -ENOMEM;
    int rc = 0;
    if (mda_sz > 512ULL && rloc_off + rloc_sz > mda_sz) {
        size_t first = (size_t)(mda_sz - rloc_off);
        rc = fd_pread_aligned(slot->fd, slot->align, mda_off + rloc_off, first, meta);
        if (rc == 0) {
            rc = fd_pread_aligned(slot->fd, slot->align, mda_off + 512ULL, (size_t)rloc_sz - first, meta + first);
        }
    } else {
        rc = fd_pread_aligned(slot->fd, slot->align, mda_off + rloc_off, (size_t)rloc_sz, meta);
    }
    if (rc != 0) { free(meta); return rc; }
    *out_meta = meta;
    return 0;
}

int cowfs_lvm_open_lv(
    const char *const *pv_paths,
    size_t pv_count,
    const char *lv_name,
    int read_only,
    cowfs_lvm_lv_ctx_t **out_lv
) {
    if (!pv_paths || pv_count == 0 || pv_count > MAX_LVM_PVS || !out_lv) return -EINVAL;
    *out_lv = NULL;

    cowfs_lvm_lv_ctx_t *ctx = (cowfs_lvm_lv_ctx_t *)calloc(1, sizeof(cowfs_lvm_lv_ctx_t));
    if (!ctx) return -ENOMEM;
    ctx->read_only = read_only ? 1 : 0;
    pthread_mutex_init(&ctx->lock, NULL);
    for (size_t i = 0; i < MAX_LVM_PVS; i++) ctx->pvs[i].fd = -1;

    char *meta = NULL;
    int rc = 0;
    for (size_t i = 0; i < pv_count; i++) {
        lvm_pv_slot_t *s = &ctx->pvs[ctx->pv_count];
        rc = cowfs_open_device_fd(pv_paths[i], ctx->read_only, &s->fd, &s->dev_size, &s->align);
        if (rc != 0) goto fail;
        rc = read_pv_header_and_mda(s, &meta);
        if (rc != 0) { close(s->fd); s->fd = -1; goto fail; }
        ctx->pv_count++;
    }
    if (!meta) { rc = -EINVAL; goto fail; }

    const char *mend = meta + strlen(meta);
    const char *p = meta;
    if (parse_ident(&p, mend, ctx->vg_name, sizeof(ctx->vg_name)) != 0) { rc = -EINVAL; goto fail; }
    p = skip_ws(p, mend);
    const char *vg_end = match_brace(p, mend);
    if (!vg_end) { rc = -EINVAL; goto fail; }

    uint64_t extent_sectors = 8192ULL;
    (void)find_u64_prop(p + 1, vg_end, "extent_size", &extent_sectors);
    ctx->extent_bytes = extent_sectors * 512ULL;

    /* Match VG physical_volumes { pv0 { id = "..." pe_start = ... } } against opened PVs */
    const char *pv_kw = strstr(p + 1, "physical_volumes");
    if (pv_kw && pv_kw < vg_end) {
        const char *pb = skip_ws(pv_kw + strlen("physical_volumes"), vg_end);
        const char *pb_end = match_brace(pb, vg_end);
        if (pb && pb_end) {
            const char *cur = pb + 1;
            while (cur < pb_end - 1) {
                char pname[64];
                if (parse_ident(&cur, pb_end - 1, pname, sizeof(pname)) != 0) break;
                cur = skip_ws(cur, pb_end - 1);
                if (cur < pb_end - 1 && *cur == '=') {
                    while (cur < pb_end - 1 && *cur != '\n') cur++;
                    continue;
                }
                const char *pclose = match_brace(cur, pb_end);
                if (!pclose) break;

                char id_str[64] = "";
                uint64_t pe_start_sec = 0;
                int has_pe = (find_u64_prop(cur + 1, pclose, "pe_start", &pe_start_sec) == 0);
                if (find_str_prop(cur + 1, pclose, "id", id_str, sizeof(id_str)) == 0) {
                    char norm_meta[40];
                    normalize_uuid_alnum(id_str, norm_meta, sizeof(norm_meta));
                    for (size_t i = 0; i < ctx->pv_count; i++) {
                        char norm_pv[40];
                        normalize_uuid_alnum(ctx->pvs[i].pv_uuid, norm_pv, sizeof(norm_pv));
                        if (strcmp(norm_meta, norm_pv) == 0) {
                            snprintf(ctx->pvs[i].pv_name, sizeof(ctx->pvs[i].pv_name), "%s", pname);
                            if (has_pe) ctx->pvs[i].pe_start = pe_start_sec * 512ULL;
                        }
                    }
                }
                cur = pclose;
            }
        }
    }
    /* Fallback default PV name pv0 if single-PV metadata omitted UUID match */
    if (ctx->pv_count == 1U && !ctx->pvs[0].pv_name[0]) {
        snprintf(ctx->pvs[0].pv_name, sizeof(ctx->pvs[0].pv_name), "pv0");
    }

    /* Parse target Logical Volume and all of its linear/striped segments */
    const char *lv_kw = strstr(p + 1, "logical_volumes");
    const char *lb = lv_kw ? skip_ws(lv_kw + strlen("logical_volumes"), vg_end) : NULL;
    const char *lb_end = lb ? match_brace(lb, vg_end) : NULL;
    if (!lb || !lb_end) { rc = -ENOENT; goto fail; }

    int found_lv = 0;
    const char *cur = lb + 1;
    while (cur < lb_end - 1) {
        char cand_lv[64];
        if (parse_ident(&cur, lb_end - 1, cand_lv, sizeof(cand_lv)) != 0) break;
        cur = skip_ws(cur, lb_end - 1);
        if (cur < lb_end - 1 && *cur == '=') {
            while (cur < lb_end - 1 && *cur != '\n') cur++;
            continue;
        }
        const char *lv_close = match_brace(cur, lb_end);
        if (!lv_close) break;

        if (!lv_name || !lv_name[0] || strcmp(cand_lv, lv_name) == 0) {
            snprintf(ctx->lv_name, sizeof(ctx->lv_name), "%s", cand_lv);
            found_lv = 1;

            const char *sp = cur + 1;
            while (sp < lv_close - 1 && ctx->seg_count < MAX_LVM_SEGS) {
                char sname[64];
                if (parse_ident(&sp, lv_close - 1, sname, sizeof(sname)) != 0) break;
                sp = skip_ws(sp, lv_close - 1);
                if (sp < lv_close - 1 && *sp == '=') {
                    while (sp < lv_close - 1 && *sp != '\n') sp++;
                    continue;
                }
                const char *sclose = match_brace(sp, lv_close);
                if (!sclose) break;

                uint64_t s_start = 0, s_cnt = 0, s_stripes = 1, s_stripe_sec = 128;
                if (find_u64_prop(sp + 1, sclose, "start_extent", &s_start) == 0 &&
                    find_u64_prop(sp + 1, sclose, "extent_count", &s_cnt) == 0 && s_cnt > 0) {
                    (void)find_u64_prop(sp + 1, sclose, "stripe_count", &s_stripes);
                    (void)find_u64_prop(sp + 1, sclose, "stripe_size", &s_stripe_sec);
                    if (s_stripes == 0 || s_stripes > MAX_LVM_STRIPES) { rc = -ENOTSUP; goto fail; }

                    lvm_segment_t *seg = &ctx->segs[ctx->seg_count++];
                    memset(seg, 0, sizeof(*seg));
                    seg->start_extent = s_start;
                    seg->extent_count = s_cnt;
                    seg->stripe_count = (uint32_t)s_stripes;
                    seg->stripe_bytes = (s_stripe_sec ? s_stripe_sec : 128ULL) * 512ULL;
                    for (size_t k = 0; k < MAX_LVM_STRIPES; k++) seg->pv_idx[k] = -1;

                    const char *st_kw = strstr(sp + 1, "stripes");
                    const char *br = st_kw ? memchr(st_kw, '[', (size_t)(sclose - st_kw)) : NULL;
                    const char *br_end = br ? memchr(br, ']', (size_t)(sclose - br)) : NULL;
                    if (!br || !br_end) { rc = -EINVAL; goto fail; }

                    const char * elem = br + 1;
                    for (uint32_t k = 0; k < seg->stripe_count; k++) {
                        while (elem < br_end && (*elem == ',' || isspace((unsigned char)*elem))) elem++;
                        char pv_ref[64];
                        if (parse_ident(&elem, br_end, pv_ref, sizeof(pv_ref)) != 0) { rc = -EINVAL; goto fail; }
                        while (elem < br_end && (*elem == ',' || isspace((unsigned char)*elem))) elem++;
                        if (elem >= br_end || !isdigit((unsigned char)*elem)) { rc = -EINVAL; goto fail; }
                        char *endnum = NULL;
                        seg->start_pe[k] = strtoull(elem, &endnum, 10);
                        elem = endnum ? endnum : elem;

                        int matched_pv = -1;
                        for (size_t pi = 0; pi < ctx->pv_count; pi++) {
                            if (strcmp(ctx->pvs[pi].pv_name, pv_ref) == 0) {
                                matched_pv = (int)pi;
                                break;
                            }
                        }
                        if (matched_pv < 0) {
                            /* Missing PV in multi-disk VG */
                            rc = -ENODEV;
                            goto fail;
                        }
                        seg->pv_idx[k] = matched_pv;
                    }
                    uint64_t seg_end_ext = seg->start_extent + seg->extent_count;
                    if (seg_end_ext * ctx->extent_bytes > ctx->total_bytes) {
                        ctx->total_bytes = seg_end_ext * ctx->extent_bytes;
                    }
                }
                sp = sclose;
            }
            break;
        }
        cur = lv_close;
    }

    if (!found_lv || ctx->seg_count == 0 || ctx->total_bytes == 0) {
        rc = -ENOENT;
        goto fail;
    }

    free(meta);
    *out_lv = ctx;
    return 0;

fail:
    free(meta);
    cowfs_lvm_close_lv(ctx);
    return rc;
}

void cowfs_lvm_close_lv(cowfs_lvm_lv_ctx_t *lv) {
    if (!lv) return;
    for (size_t i = 0; i < lv->pv_count; i++) {
        if (lv->pvs[i].fd >= 0) close(lv->pvs[i].fd);
    }
    pthread_mutex_destroy(&lv->lock);
    free(lv);
}

uint64_t cowfs_lvm_lv_size(const cowfs_lvm_lv_ctx_t *lv) {
    return lv ? lv->total_bytes : 0ULL;
}

const char *cowfs_lvm_lv_name(const cowfs_lvm_lv_ctx_t *lv) {
    return lv ? lv->lv_name : "";
}

static int lvm_lv_io(cowfs_lvm_lv_ctx_t *lv, int is_write, uint64_t offset, size_t length, void *buffer) {
    if (!lv || (!buffer && length > 0)) return -EINVAL;
    if (is_write && lv->read_only) return -EROFS;
    if (length == 0) return 0;
    if (offset + length > lv->total_bytes) return is_write ? -ENOSPC : -EIO;

    pthread_mutex_lock(&lv->lock);
    uint8_t *ptr = (uint8_t *)buffer;
    size_t done = 0;
    int rc = 0;

    while (done < length) {
        uint64_t cur = offset + done;
        uint64_t cur_ext = cur / lv->extent_bytes;
        const lvm_segment_t *seg = NULL;
        for (size_t i = 0; i < lv->seg_count; i++) {
            if (cur_ext >= lv->segs[i].start_extent &&
                cur_ext < lv->segs[i].start_extent + lv->segs[i].extent_count) {
                seg = &lv->segs[i];
                break;
            }
        }
        if (!seg) { rc = -EIO; break; }

        uint64_t seg_rel = cur - seg->start_extent * lv->extent_bytes;
        uint64_t seg_rem = seg->extent_count * lv->extent_bytes - seg_rel;
        size_t want = length - done;
        if ((uint64_t)want > seg_rem) want = (size_t)seg_rem;

        int pv_i = 0;
        uint64_t phys_off = 0;
        size_t step = want;

        if (seg->stripe_count <= 1U) {
            pv_i = seg->pv_idx[0];
            phys_off = lv->pvs[pv_i].pe_start + seg->start_pe[0] * lv->extent_bytes + seg_rel;
        } else {
            uint64_t chunk_no = seg_rel / seg->stripe_bytes;
            uint64_t in_chunk = seg_rel % seg->stripe_bytes;
            uint32_t stripe_idx = (uint32_t)(chunk_no % seg->stripe_count);
            uint64_t stripe_row = chunk_no / seg->stripe_count;
            pv_i = seg->pv_idx[stripe_idx];
            phys_off = lv->pvs[pv_i].pe_start + seg->start_pe[stripe_idx] * lv->extent_bytes +
                       stripe_row * seg->stripe_bytes + in_chunk;
            if (in_chunk + step > seg->stripe_bytes) {
                step = (size_t)(seg->stripe_bytes - in_chunk);
            }
        }

        if (is_write) {
            rc = fd_pwrite_aligned(lv->pvs[pv_i].fd, lv->pvs[pv_i].align, phys_off, step, ptr + done);
        } else {
            rc = fd_pread_aligned(lv->pvs[pv_i].fd, lv->pvs[pv_i].align, phys_off, step, ptr + done);
        }
        if (rc != 0) break;
        done += step;
    }

    pthread_mutex_unlock(&lv->lock);
    return rc;
}

int cowfs_lvm_lv_pread(cowfs_lvm_lv_ctx_t *lv, uint64_t offset, size_t length, void *buffer) {
    return lvm_lv_io(lv, 0, offset, length, buffer);
}

int cowfs_lvm_lv_pwrite(cowfs_lvm_lv_ctx_t *lv, uint64_t offset, size_t length, const void *buffer) {
    return lvm_lv_io(lv, 1, offset, length, (void *)buffer);
}

/* ---------------- Linux mdadm Software RAID-0 / RAID-1 / RAID-5 Assembly ---------------- */

#define MD_SB_MAGIC 0xA92B4EFEU
#define MAX_RAID_DISKS 16U

typedef struct {
    int      present;
    int      fd;
    uint32_t align;
    uint64_t data_offset;
    uint64_t component_bytes;
} raid_slot_t;

struct cowfs_mdraid_ctx {
    pthread_mutex_t lock;
    int             level;
    uint32_t        layout;
    uint32_t        raid_disks;
    uint32_t        present_disks;
    uint32_t        chunk_bytes;
    uint64_t        component_bytes;
    uint64_t        array_bytes;
    int             degraded;
    char            set_name[64];
    char            set_uuid[40];
    raid_slot_t     slots[MAX_RAID_DISKS];
};

static void format_uuid_bytes(const uint8_t u[16], char *out, size_t cap) {
    snprintf(out, cap,
             "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
             u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}

static int probe_mdraid_fd(int fd, uint64_t dev_size, uint32_t align, cowfs_mdraid_member_info_t *out) {
    memset(out, 0, sizeof(*out));
    uint8_t sb[1024];

    /* Check v1.2 (4096), v1.1 (0), and v1.0 (near end of device) */
    uint64_t v1_offsets[3] = {
        4096ULL,
        0ULL,
        (dev_size >= 16384ULL) ? ((dev_size - 8192ULL) & ~4095ULL) : 0xFFFFFFFFFFFFFFFFULL
    };
    int v1_minors[3] = { 2, 1, 0 };

    for (int k = 0; k < 3; k++) {
        uint64_t off = v1_offsets[k];
        if (off == 0xFFFFFFFFFFFFFFFFULL || off + sizeof(sb) > dev_size) continue;
        if (fd_pread_aligned(fd, align, off, sizeof(sb), sb) != 0) continue;
        if (cfs_le32(sb + 0) != MD_SB_MAGIC || cfs_le32(sb + 4) != 1U) continue;

        /* Verify super_offset matches expected sector */
        uint64_t super_sec = cfs_le64(sb + 144);
        if (super_sec * 512ULL != off) continue;

        int32_t level = (int32_t)cfs_le32(sb + 72);
        uint32_t layout = cfs_le32(sb + 76);
        uint64_t comp_sec = cfs_le64(sb + 80);
        uint32_t chunk_sec = cfs_le32(sb + 88);
        uint32_t raid_disks = cfs_le32(sb + 92);
        uint64_t data_off_sec = cfs_le64(sb + 128);
        uint64_t data_sz_sec = cfs_le64(sb + 136);
        uint32_t dev_num = cfs_le32(sb + 160);

        if (raid_disks == 0 || raid_disks > MAX_RAID_DISKS) return -ENOTSUP;
        if (256U + (size_t)dev_num * 2U + 2U > sizeof(sb)) return -EINVAL;
        uint16_t role = cfs_le16(sb + 256U + (size_t)dev_num * 2U);
        if (role >= raid_disks) return -ENODEV; /* spare or faulty */

        out->major_ver = 1;
        out->minor_ver = v1_minors[k];
        out->level = (int)level;
        out->layout = layout;
        out->raid_disks = raid_disks;
        out->dev_role = role;
        out->chunk_bytes = (chunk_sec ? chunk_sec : 128U) * 512U;
        out->data_offset = data_off_sec * 512ULL;
        uint64_t usable_sec = comp_sec ? comp_sec : data_sz_sec;
        out->component_bytes = usable_sec * 512ULL;

        if (level == 0) out->array_bytes = out->component_bytes * raid_disks;
        else if (level == 1) out->array_bytes = out->component_bytes;
        else if (level == 5 && raid_disks >= 3U) out->array_bytes = out->component_bytes * (raid_disks - 1U);
        else return -ENOTSUP;

        format_uuid_bytes(sb + 16, out->set_uuid, sizeof(out->set_uuid));
        memcpy(out->set_name, sb + 32, 32);
        out->set_name[32] = '\0';
        return 0;
    }

    /* Check v0.90 superblock at (dev_size & ~65535) - 65536 */
    if (dev_size >= 131072ULL) {
        uint64_t sb0_off = (dev_size & ~65535ULL) - 65536ULL;
        uint8_t sb0[4096];
        if (fd_pread_aligned(fd, align, sb0_off, sizeof(sb0), sb0) == 0 &&
            cfs_le32(sb0 + 0) == MD_SB_MAGIC &&
            cfs_le32(sb0 + 4) == 0U) {
            int32_t level = (int32_t)cfs_le32(sb0 + 28);
            uint32_t comp_kib = cfs_le32(sb0 + 32);
            uint32_t raid_disks = cfs_le32(sb0 + 40);
            uint32_t layout = cfs_le32(sb0 + 68);
            uint32_t chunk_bytes = cfs_le32(sb0 + 72);
            uint32_t role = cfs_le32(sb0 + 1004); /* this_disk.raid_disk */
            if (raid_disks == 0 || raid_disks > MAX_RAID_DISKS || role >= raid_disks) return -ENOTSUP;

            out->major_ver = 0;
            out->minor_ver = (int)cfs_le32(sb0 + 8);
            out->level = (int)level;
            out->layout = layout;
            out->raid_disks = raid_disks;
            out->dev_role = role;
            out->chunk_bytes = chunk_bytes ? chunk_bytes : 65536U;
            out->data_offset = 0ULL;
            out->component_bytes = (uint64_t)comp_kib * 1024ULL;
            if (out->component_bytes == 0) out->component_bytes = sb0_off;

            if (level == 0) out->array_bytes = out->component_bytes * raid_disks;
            else if (level == 1) out->array_bytes = out->component_bytes;
            else if (level == 5 && raid_disks >= 3U) out->array_bytes = out->component_bytes * (raid_disks - 1U);
            else return -ENOTSUP;

            uint8_t u16[16];
            memcpy(u16, sb0 + 20, 4);
            memcpy(u16 + 4, sb0 + 52, 12);
            format_uuid_bytes(u16, out->set_uuid, sizeof(out->set_uuid));
            snprintf(out->set_name, sizeof(out->set_name), "md_v090");
            return 0;
        }
    }

    return -EINVAL;
}

int cowfs_mdraid_probe(const char *path, cowfs_mdraid_member_info_t *out_info) {
    if (!path || !out_info) return -EINVAL;
    int fd = -1;
    uint64_t dev_size = 0;
    uint32_t align = 1U;
    int rc = cowfs_open_device_fd(path, 1, &fd, &dev_size, &align);
    if (rc != 0) return rc;
    rc = probe_mdraid_fd(fd, dev_size, align, out_info);
    close(fd);
    return rc;
}

int cowfs_mdraid_assemble(
    const char *const *member_paths,
    size_t path_count,
    cowfs_mdraid_t **out_raid
) {
    if (!member_paths || path_count == 0 || !out_raid) return -EINVAL;
    *out_raid = NULL;

    cowfs_mdraid_t *r = (cowfs_mdraid_t *)calloc(1, sizeof(cowfs_mdraid_t));
    if (!r) return -ENOMEM;
    pthread_mutex_init(&r->lock, NULL);
    for (size_t i = 0; i < MAX_RAID_DISKS; i++) r->slots[i].fd = -1;

    int initialized = 0;
    int rc = 0;
    for (size_t i = 0; i < path_count; i++) {
        int fd = -1;
        uint64_t dev_size = 0;
        uint32_t align = 1U;
        rc = cowfs_open_device_fd(member_paths[i], 1, &fd, &dev_size, &align);
        if (rc != 0) continue; /* allow caller to pass paths where a missing disk fails open */

        cowfs_mdraid_member_info_t mi;
        if (probe_mdraid_fd(fd, dev_size, align, &mi) != 0) {
            close(fd);
            rc = -EINVAL;
            goto fail;
        }

        if (!initialized) {
            r->level = mi.level;
            r->layout = mi.layout;
            r->raid_disks = mi.raid_disks;
            r->chunk_bytes = mi.chunk_bytes;
            r->component_bytes = mi.component_bytes;
            r->array_bytes = mi.array_bytes;
            snprintf(r->set_name, sizeof(r->set_name), "%s", mi.set_name[0] ? mi.set_name : "md0");
            snprintf(r->set_uuid, sizeof(r->set_uuid), "%s", mi.set_uuid);
            initialized = 1;
        } else {
            if (strcmp(r->set_uuid, mi.set_uuid) != 0 || r->raid_disks != mi.raid_disks || r->level != mi.level) {
                close(fd);
                rc = -EXDEV;
                goto fail;
            }
        }

        if (mi.dev_role < r->raid_disks && !r->slots[mi.dev_role].present) {
            r->slots[mi.dev_role].present = 1;
            r->slots[mi.dev_role].fd = fd;
            r->slots[mi.dev_role].align = align;
            r->slots[mi.dev_role].data_offset = mi.data_offset;
            r->slots[mi.dev_role].component_bytes = mi.component_bytes;
            r->present_disks++;
        } else {
            close(fd);
        }
    }

    if (!initialized || r->present_disks == 0) {
        rc = -ENOENT;
        goto fail;
    }

    r->degraded = (r->present_disks < r->raid_disks) ? 1 : 0;
    if (r->level == 0 && r->present_disks < r->raid_disks) {
        rc = -ENODEV; /* RAID-0 requires all members */
        goto fail;
    }
    if (r->level == 1 && r->present_disks < 1U) {
        rc = -ENODEV;
        goto fail;
    }
    if (r->level == 5 && r->present_disks + 1U < r->raid_disks) {
        rc = -ENODEV; /* RAID-5 tolerates at most 1 missing disk */
        goto fail;
    }

    *out_raid = r;
    return 0;

fail:
    cowfs_mdraid_close(r);
    return rc;
}

void cowfs_mdraid_close(cowfs_mdraid_t *raid) {
    if (!raid) return;
    for (size_t i = 0; i < MAX_RAID_DISKS; i++) {
        if (raid->slots[i].fd >= 0) close(raid->slots[i].fd);
    }
    pthread_mutex_destroy(&raid->lock);
    free(raid);
}

uint64_t cowfs_mdraid_size(const cowfs_mdraid_t *raid) {
    return raid ? raid->array_bytes : 0ULL;
}

int cowfs_mdraid_degraded(const cowfs_mdraid_t *raid) {
    return raid ? raid->degraded : 0;
}

int cowfs_mdraid_level(const cowfs_mdraid_t *raid) {
    return raid ? raid->level : -1;
}

const char *cowfs_mdraid_name(const cowfs_mdraid_t *raid) {
    return raid ? raid->set_name : "";
}

static void raid5_map_stripe(
    uint32_t raid_disks,
    uint32_t layout,
    uint64_t stripe_no,
    uint32_t chunk_in_stripe,
    uint32_t *out_data_disk,
    uint32_t *out_parity_disk
) {
    uint32_t pd = 0, dd = 0;
    switch (layout & 0x3U) {
        case 0U: /* ALGORITHM_LEFT_ASYMMETRIC */
            pd = (raid_disks - 1U) - (uint32_t)(stripe_no % raid_disks);
            dd = (chunk_in_stripe < pd) ? chunk_in_stripe : (chunk_in_stripe + 1U);
            break;
        case 1U: /* ALGORITHM_RIGHT_ASYMMETRIC */
            pd = (uint32_t)(stripe_no % raid_disks);
            dd = (chunk_in_stripe < pd) ? chunk_in_stripe : (chunk_in_stripe + 1U);
            break;
        case 3U: /* ALGORITHM_RIGHT_SYMMETRIC */
            pd = (uint32_t)(stripe_no % raid_disks);
            dd = (pd + 1U + chunk_in_stripe) % raid_disks;
            break;
        case 2U: /* ALGORITHM_LEFT_SYMMETRIC (Linux default) */
        default:
            pd = (raid_disks - 1U) - (uint32_t)(stripe_no % raid_disks);
            dd = (pd + 1U + chunk_in_stripe) % raid_disks;
            break;
    }
    *out_data_disk = dd;
    *out_parity_disk = pd;
}

int cowfs_mdraid_pread(cowfs_mdraid_t *raid, uint64_t offset, size_t length, void *buffer) {
    if (!raid || (!buffer && length > 0)) return -EINVAL;
    if (length == 0) return 0;
    if (offset + length > raid->array_bytes) return -EIO;

    pthread_mutex_lock(&raid->lock);
    uint8_t *dst = (uint8_t *)buffer;
    size_t done = 0;
    int rc = 0;

    if (raid->level == 1) {
        rc = -EIO;
        for (uint32_t d = 0; d < raid->raid_disks; d++) {
            if (!raid->slots[d].present) continue;
            if (fd_pread_aligned(raid->slots[d].fd, raid->slots[d].align,
                                 raid->slots[d].data_offset + offset, length, dst) == 0) {
                rc = 0;
                break;
            }
        }
        pthread_mutex_unlock(&raid->lock);
        return rc;
    }

    uint8_t *xor_tmp = NULL;
    if (raid->level == 5 && raid->degraded) {
        size_t xcap = (length < raid->chunk_bytes) ? length : raid->chunk_bytes;
        xor_tmp = (uint8_t *)malloc(xcap);
        if (!xor_tmp) {
            pthread_mutex_unlock(&raid->lock);
            return -ENOMEM;
        }
    }

    while (done < length) {
        uint64_t cur = offset + done;
        uint64_t chunk_no = cur / raid->chunk_bytes;
        uint64_t in_chunk = cur % raid->chunk_bytes;
        size_t step = length - done;
        if (in_chunk + step > raid->chunk_bytes) {
            step = (size_t)(raid->chunk_bytes - in_chunk);
        }

        if (raid->level == 0) {
            uint32_t dd = (uint32_t)(chunk_no % raid->raid_disks);
            uint64_t row = chunk_no / raid->raid_disks;
            uint64_t phys = raid->slots[dd].data_offset + row * raid->chunk_bytes + in_chunk;
            rc = fd_pread_aligned(raid->slots[dd].fd, raid->slots[dd].align, phys, step, dst + done);
            if (rc != 0) break;
        } else if (raid->level == 5) {
            uint32_t data_disks = raid->raid_disks - 1U;
            uint64_t stripe_no = chunk_no / data_disks;
            uint32_t chunk_in_stripe = (uint32_t)(chunk_no % data_disks);
            uint32_t dd = 0, pd = 0;
            raid5_map_stripe(raid->raid_disks, raid->layout, stripe_no, chunk_in_stripe, &dd, &pd);
            (void)pd;

            uint64_t member_rel = stripe_no * raid->chunk_bytes + in_chunk;
            if (raid->slots[dd].present) {
                rc = fd_pread_aligned(
                    raid->slots[dd].fd,
                    raid->slots[dd].align,
                    raid->slots[dd].data_offset + member_rel,
                    step,
                    dst + done
                );
                if (rc != 0) break;
            } else {
                /* Reconstruct missing data chunk by XORing all remaining N-1 disks (siblings + parity) */
                memset(dst + done, 0, step);
                for (uint32_t m = 0; m < raid->raid_disks; m++) {
                    if (m == dd) continue;
                    if (!raid->slots[m].present) { rc = -EIO; break; }
                    rc = fd_pread_aligned(
                        raid->slots[m].fd,
                        raid->slots[m].align,
                        raid->slots[m].data_offset + member_rel,
                        step,
                        xor_tmp
                    );
                    if (rc != 0) break;
                    uint8_t *out_s = dst + done;
                    for (size_t b = 0; b < step; b++) out_s[b] ^= xor_tmp[b];
                }
                if (rc != 0) break;
            }
        }
        done += step;
    }

    free(xor_tmp);
    pthread_mutex_unlock(&raid->lock);
    return rc;
}
