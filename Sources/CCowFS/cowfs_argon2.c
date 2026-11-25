#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "cowfs_internal.h"

/*
 * Self-contained RFC 9106 Argon2id / Argon2i / Argon2d (v1.3, 0x13) + BLAKE2b
 * implementation for unlocking modern LUKS2 keyslots in Montserrat without
 * external library dependencies.
 */

static inline uint64_t rotr64(uint64_t x, unsigned int n) {
    return (x >> n) | (x << (64U - n));
}

/* ---------------- BLAKE2b (RFC 7693) ---------------- */

static const uint64_t k_blake2b_iv[8] = {
    0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
    0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
    0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
    0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
};

static const uint8_t k_blake2b_sigma[12][16] = {
    {  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 },
    { 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 },
    { 11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4 },
    {  7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8 },
    {  9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13 },
    {  2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9 },
    { 12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11 },
    { 13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10 },
    {  6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5 },
    { 10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0 },
    {  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 },
    { 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 }
};

typedef struct {
    uint64_t h[8];
    uint64_t t[2];
    uint64_t f[2];
    uint8_t  buf[128];
    size_t   buflen;
    size_t   outlen;
} blake2b_ctx_t;

#define B2B_G(r, i, a, b, c, d) do { \
    a = a + b + m[k_blake2b_sigma[r][2 * (i) + 0]]; \
    d = rotr64(d ^ a, 32); \
    c = c + d; \
    b = rotr64(b ^ c, 24); \
    a = a + b + m[k_blake2b_sigma[r][2 * (i) + 1]]; \
    d = rotr64(d ^ a, 16); \
    c = c + d; \
    b = rotr64(b ^ c, 63); \
} while (0)

static void blake2b_compress(blake2b_ctx_t *S, const uint8_t block[128]) {
    uint64_t m[16], v[16];
    for (size_t i = 0; i < 16U; i++) m[i] = cfs_le64(block + i * 8U);
    for (size_t i = 0; i < 8U; i++) {
        v[i] = S->h[i];
        v[i + 8U] = k_blake2b_iv[i];
    }
    v[12] ^= S->t[0];
    v[13] ^= S->t[1];
    v[14] ^= S->f[0];
    v[15] ^= S->f[1];

    for (size_t r = 0; r < 12U; r++) {
        B2B_G(r, 0, v[0], v[4], v[ 8], v[12]);
        B2B_G(r, 1, v[1], v[5], v[ 9], v[13]);
        B2B_G(r, 2, v[2], v[6], v[10], v[14]);
        B2B_G(r, 3, v[3], v[7], v[11], v[15]);
        B2B_G(r, 4, v[0], v[5], v[10], v[15]);
        B2B_G(r, 5, v[1], v[6], v[11], v[12]);
        B2B_G(r, 6, v[2], v[7], v[ 8], v[13]);
        B2B_G(r, 7, v[3], v[4], v[ 9], v[14]);
    }
    for (size_t i = 0; i < 8U; i++) S->h[i] ^= v[i] ^ v[i + 8U];
}

static void blake2b_init(blake2b_ctx_t *S, size_t outlen) {
    memset(S, 0, sizeof(*S));
    for (size_t i = 0; i < 8U; i++) S->h[i] = k_blake2b_iv[i];
    S->h[0] ^= 0x01010000ULL ^ (uint64_t)outlen;
    S->outlen = outlen;
}

static void blake2b_update(blake2b_ctx_t *S, const void *pin, size_t inlen) {
    if (inlen == 0) return;
    const uint8_t *in = (const uint8_t *)pin;
    size_t left = S->buflen;
    size_t fill = 128U - left;
    if (inlen > fill) {
        S->buflen = 0;
        memcpy(S->buf + left, in, fill);
        S->t[0] += 128ULL;
        if (S->t[0] < 128ULL) S->t[1]++;
        blake2b_compress(S, S->buf);
        in += fill;
        inlen -= fill;
        while (inlen > 128U) {
            S->t[0] += 128ULL;
            if (S->t[0] < 128ULL) S->t[1]++;
            blake2b_compress(S, in);
            in += 128U;
            inlen -= 128U;
        }
    }
    memcpy(S->buf + S->buflen, in, inlen);
    S->buflen += inlen;
}

static void blake2b_update_u32(blake2b_ctx_t *S, uint32_t val) {
    uint8_t b[4];
    cfs_put_le32(b, val);
    blake2b_update(S, b, 4U);
}

static void blake2b_final(blake2b_ctx_t *S, uint8_t *out) {
    S->t[0] += (uint64_t)S->buflen;
    if (S->t[0] < (uint64_t)S->buflen) S->t[1]++;
    S->f[0] = ~0ULL;
    memset(S->buf + S->buflen, 0, 128U - S->buflen);
    blake2b_compress(S, S->buf);
    uint8_t full[64];
    for (size_t i = 0; i < 8U; i++) cfs_put_le64(full + i * 8U, S->h[i]);
    memcpy(out, full, S->outlen);
    memset(full, 0, sizeof(full));
}

static void blake2b_one(uint8_t *out, size_t outlen, const void *in, size_t inlen) {
    blake2b_ctx_t S;
    blake2b_init(&S, outlen);
    blake2b_update(&S, in, inlen);
    blake2b_final(&S, out);
}

/* Variable-length hash H'(X, outlen) per RFC 9106 Section 3.2 */
static void blake2b_long(uint8_t *out, size_t outlen, const void *in, size_t inlen) {
    uint8_t outlen_le[4];
    cfs_put_le32(outlen_le, (uint32_t)outlen);

    if (outlen <= 64U) {
        blake2b_ctx_t S;
        blake2b_init(&S, outlen);
        blake2b_update(&S, outlen_le, 4U);
        blake2b_update(&S, in, inlen);
        blake2b_final(&S, out);
        return;
    }

    uint8_t v_in[64], v_out[64];
    blake2b_ctx_t S;
    blake2b_init(&S, 64U);
    blake2b_update(&S, outlen_le, 4U);
    blake2b_update(&S, in, inlen);
    blake2b_final(&S, v_out);

    memcpy(out, v_out, 32U);
    out += 32U;
    size_t to_produce = outlen - 32U;

    while (to_produce > 64U) {
        memcpy(v_in, v_out, 64U);
        blake2b_one(v_out, 64U, v_in, 64U);
        memcpy(out, v_out, 32U);
        out += 32U;
        to_produce -= 32U;
    }
    memcpy(v_in, v_out, 64U);
    blake2b_one(out, to_produce, v_in, 64U);
    memset(v_in, 0, sizeof(v_in));
    memset(v_out, 0, sizeof(v_out));
}

/* ---------------- Argon2 Block Compression G (RFC 9106 Section 3.5) ---------------- */

typedef struct {
    uint64_t v[128];
} argon2_block_t;

static inline uint64_t f_blamka(uint64_t x, uint64_t y) {
    uint64_t m = (uint64_t)(uint32_t)x * (uint64_t)(uint32_t)y;
    return x + y + (m << 1);
}

#define ARGON2_GB(a, b, c, d) do { \
    a = f_blamka(a, b); d = rotr64(d ^ a, 32); \
    c = f_blamka(c, d); b = rotr64(b ^ c, 24); \
    a = f_blamka(a, b); d = rotr64(d ^ a, 16); \
    c = f_blamka(c, d); b = rotr64(b ^ c, 63); \
} while (0)

#define ARGON2_PERMUTE(v0,v1,v2,v3,v4,v5,v6,v7,v8,v9,v10,v11,v12,v13,v14,v15) do { \
    ARGON2_GB(v0, v4,  v8, v12); \
    ARGON2_GB(v1, v5,  v9, v13); \
    ARGON2_GB(v2, v6, v10, v14); \
    ARGON2_GB(v3, v7, v11, v15); \
    ARGON2_GB(v0, v5, v10, v15); \
    ARGON2_GB(v1, v6, v11, v12); \
    ARGON2_GB(v2, v7,  v8, v13); \
    ARGON2_GB(v3, v4,  v9, v14); \
} while (0)

static void argon2_fill_block(
    const argon2_block_t *prev,
    const argon2_block_t *ref,
    argon2_block_t *next,
    int with_xor
) {
    argon2_block_t R, Z;
    for (size_t i = 0; i < 128U; i++) {
        R.v[i] = prev->v[i] ^ ref->v[i];
        Z.v[i] = R.v[i];
    }

    /* Apply P row-wise (8 rows of 16 uint64_t words) */
    for (size_t r = 0; r < 8U; r++) {
        uint64_t *w = &Z.v[r * 16U];
        ARGON2_PERMUTE(
            w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7],
            w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]
        );
    }

    /* Apply P column-wise (8 pairs of columns across 8 rows) */
    for (size_t c = 0; c < 8U; c++) {
        size_t b = c * 2U;
        ARGON2_PERMUTE(
            Z.v[b +   0], Z.v[b +   1], Z.v[b +  16], Z.v[b +  17],
            Z.v[b +  32], Z.v[b +  33], Z.v[b +  48], Z.v[b +  49],
            Z.v[b +  64], Z.v[b +  65], Z.v[b +  80], Z.v[b +  81],
            Z.v[b +  96], Z.v[b +  97], Z.v[b + 112], Z.v[b + 113]
        );
    }

    if (with_xor) {
        for (size_t i = 0; i < 128U; i++) next->v[i] ^= R.v[i] ^ Z.v[i];
    } else {
        for (size_t i = 0; i < 128U; i++) next->v[i] = R.v[i] ^ Z.v[i];
    }
}

static void argon2_next_addresses(
    argon2_block_t *addr_block,
    argon2_block_t *input_block,
    const argon2_block_t *zero_block
) {
    input_block->v[6]++;
    argon2_fill_block(zero_block, input_block, addr_block, 0);
    argon2_fill_block(zero_block, addr_block, addr_block, 0);
}

static void block_from_bytes(argon2_block_t *blk, const uint8_t raw[1024]) {
    for (size_t i = 0; i < 128U; i++) blk->v[i] = cfs_le64(raw + i * 8U);
}

static void block_to_bytes(uint8_t raw[1024], const argon2_block_t *blk) {
    for (size_t i = 0; i < 128U; i++) cfs_put_le64(raw + i * 8U, blk->v[i]);
}

int cowfs_argon2_derive(
    cowfs_argon2_variant_t variant,
    const char *pass,
    size_t pass_len,
    const uint8_t *salt,
    size_t salt_len,
    uint32_t time_cost,
    uint32_t memory_kib,
    uint32_t parallelism,
    uint8_t *out_key,
    size_t out_len
) {
    if (!salt || salt_len < 8U || !out_key || out_len < 4U) return -EINVAL;
    if (time_cost < 1U || parallelism < 1U || parallelism > 64U) return -EINVAL;
    if (memory_kib < 8U * parallelism || memory_kib > (4U * 1024U * 1024U)) return -EINVAL;

    uint32_t type_val = (uint32_t)variant; /* 0 = d, 1 = i, 2 = id */
    if (type_val > 2U) return -EINVAL;

    uint32_t seg_len = memory_kib / (4U * parallelism);
    if (seg_len < 2U) seg_len = 2U;
    uint32_t q = seg_len * 4U;
    uint32_t m_prime = q * parallelism;

    argon2_block_t *mem = (argon2_block_t *)calloc((size_t)m_prime, sizeof(argon2_block_t));
    if (!mem) return -ENOMEM;

    /* Compute H_0 */
    uint8_t h0_plus[72];
    blake2b_ctx_t H0;
    blake2b_init(&H0, 64U);
    blake2b_update_u32(&H0, parallelism);
    blake2b_update_u32(&H0, (uint32_t)out_len);
    blake2b_update_u32(&H0, memory_kib);
    blake2b_update_u32(&H0, time_cost);
    blake2b_update_u32(&H0, 0x13U); /* Argon2 v1.3 */
    blake2b_update_u32(&H0, type_val);
    blake2b_update_u32(&H0, (uint32_t)pass_len);
    if (pass && pass_len > 0U) blake2b_update(&H0, pass, pass_len);
    blake2b_update_u32(&H0, (uint32_t)salt_len);
    blake2b_update(&H0, salt, salt_len);
    blake2b_update_u32(&H0, 0U); /* secret len = 0 */
    blake2b_update_u32(&H0, 0U); /* ad len = 0 */
    blake2b_final(&H0, h0_plus);

    /* Initialize B[lane][0] and B[lane][1] */
    uint8_t tmp_raw[1024];
    for (uint32_t l = 0; l < parallelism; l++) {
        cfs_put_le32(h0_plus + 64U, 0U);
        cfs_put_le32(h0_plus + 68U, l);
        blake2b_long(tmp_raw, 1024U, h0_plus, 72U);
        block_from_bytes(&mem[(size_t)l * q + 0U], tmp_raw);

        cfs_put_le32(h0_plus + 64U, 1U);
        cfs_put_le32(h0_plus + 68U, l);
        blake2b_long(tmp_raw, 1024U, h0_plus, 72U);
        block_from_bytes(&mem[(size_t)l * q + 1U], tmp_raw);
    }

    argon2_block_t zero_block;
    memset(&zero_block, 0, sizeof(zero_block));

    for (uint32_t pass_no = 0; pass_no < time_cost; pass_no++) {
        for (uint32_t slice = 0; slice < 4U; slice++) {
            int data_indep = (type_val == 1U) || (type_val == 2U && pass_no == 0U && slice < 2U);
            for (uint32_t lane = 0; lane < parallelism; lane++) {
                argon2_block_t addr_block, input_block;
                if (data_indep) {
                    memset(&input_block, 0, sizeof(input_block));
                    input_block.v[0] = pass_no;
                    input_block.v[1] = lane;
                    input_block.v[2] = slice;
                    input_block.v[3] = m_prime;
                    input_block.v[4] = time_cost;
                    input_block.v[5] = type_val;
                    input_block.v[6] = 0ULL;
                    argon2_next_addresses(&addr_block, &input_block, &zero_block);
                }

                uint32_t start_idx = (pass_no == 0U && slice == 0U) ? 2U : 0U;
                for (uint32_t idx = start_idx; idx < seg_len; idx++) {
                    if (data_indep && idx > 0U && (idx % 128U) == 0U) {
                        argon2_next_addresses(&addr_block, &input_block, &zero_block);
                    }

                    uint32_t curr_col = slice * seg_len + idx;
                    uint32_t prev_col = (curr_col == 0U) ? (q - 1U) : (curr_col - 1U);
                    const argon2_block_t *prev_blk = &mem[(size_t)lane * q + prev_col];

                    uint64_t pseudo_rand = data_indep ? addr_block.v[idx % 128U] : prev_blk->v[0];
                    uint32_t j1 = (uint32_t)(pseudo_rand & 0xFFFFFFFFULL);
                    uint32_t j2 = (uint32_t)(pseudo_rand >> 32);

                    uint32_t ref_lane = (pass_no == 0U && slice == 0U) ? lane : (j2 % parallelism);
                    uint32_t ref_area_size = 0U;
                    uint32_t index_base = 0U;

                    if (pass_no == 0U) {
                        if (slice == 0U) {
                            ref_area_size = idx - 1U;
                        } else if (ref_lane == lane) {
                            ref_area_size = slice * seg_len + idx - 1U;
                        } else {
                            ref_area_size = slice * seg_len - ((idx == 0U) ? 1U : 0U);
                        }
                    } else {
                        index_base = ((slice + 1U) % 4U) * seg_len;
                        if (ref_lane == lane) {
                            ref_area_size = q - seg_len + idx - 1U;
                        } else {
                            ref_area_size = q - seg_len - ((idx == 0U) ? 1U : 0U);
                        }
                    }

                    uint64_t rel_pos = (uint64_t)j1;
                    rel_pos = (rel_pos * rel_pos) >> 32;
                    rel_pos = (uint64_t)ref_area_size - 1ULL - (((uint64_t)ref_area_size * rel_pos) >> 32);
                    uint32_t ref_col = (index_base + (uint32_t)rel_pos) % q;

                    const argon2_block_t *ref_blk = &mem[(size_t)ref_lane * q + ref_col];
                    argon2_block_t *curr_blk = &mem[(size_t)lane * q + curr_col];
                    argon2_fill_block(prev_blk, ref_blk, curr_blk, pass_no > 0U ? 1 : 0);
                }
            }
        }
    }

    argon2_block_t final_blk = mem[(size_t)0U * q + (q - 1U)];
    for (uint32_t l = 1U; l < parallelism; l++) {
        const argon2_block_t *last = &mem[(size_t)l * q + (q - 1U)];
        for (size_t w = 0; w < 128U; w++) final_blk.v[w] ^= last->v[w];
    }

    block_to_bytes(tmp_raw, &final_blk);
    blake2b_long(out_key, out_len, tmp_raw, 1024U);

    memset(tmp_raw, 0, sizeof(tmp_raw));
    memset(&final_blk, 0, sizeof(final_blk));
    memset(h0_plus, 0, sizeof(h0_plus));
    memset(mem, 0, (size_t)m_prime * sizeof(argon2_block_t));
    free(mem);
    return 0;
}
