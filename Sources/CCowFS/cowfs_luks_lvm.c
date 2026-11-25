#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "cowfs_internal.h"
#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <ctype.h>
#include <fcntl.h>
#include <unistd.h>

#define LUKS_MAGIC_LEN 6
static const uint8_t k_luks_magic[LUKS_MAGIC_LEN] = { 'L', 'U', 'K', 'S', 0xBA, 0xBE };
#define LUKS1_KEY_ENABLED 0x00AC71F3U
#define LUKS1_KEY_DISABLED 0x0000DEADU

typedef enum {
    LUKS_HASH_SHA256 = 1,
    LUKS_HASH_SHA512 = 2,
    LUKS_HASH_SHA1   = 3
} luks_hash_id_t;

struct cowfs_luks_ctx {
    cowfs_fd_backend_t fb;
    cowfs_luks_info_t  info;
    uint64_t           iv_offset;
    uint32_t           half_key_len;
    uint8_t            key1[32]; /* AES data-unit key */
    uint8_t            key2[32]; /* AES tweak key */
    pthread_mutex_t    lock;
};

static luks_hash_id_t parse_hash_spec(const char *spec) {
    if (!spec) return LUKS_HASH_SHA256;
    if (strstr(spec, "sha512") || strstr(spec, "SHA512")) return LUKS_HASH_SHA512;
    if (strstr(spec, "sha1") || strstr(spec, "SHA1")) return LUKS_HASH_SHA1;
    return LUKS_HASH_SHA256;
}

static size_t hash_digest_len(luks_hash_id_t h) {
    switch (h) {
        case LUKS_HASH_SHA512: return CC_SHA512_DIGEST_LENGTH;
        case LUKS_HASH_SHA1:   return CC_SHA1_DIGEST_LENGTH;
        default:               return CC_SHA256_DIGEST_LENGTH;
    }
}

static CCPseudoRandomAlgorithm cc_prf_for_hash(luks_hash_id_t h) {
    switch (h) {
        case LUKS_HASH_SHA512: return kCCPRFHmacAlgSHA512;
        case LUKS_HASH_SHA1:   return kCCPRFHmacAlgSHA1;
        default:               return kCCPRFHmacAlgSHA256;
    }
}

static void compute_hash_iv(luks_hash_id_t h, uint32_t iv_be_idx, const uint8_t *in, size_t in_len, uint8_t *digest_out) {
    uint8_t iv[4];
    cfs_put_be32(iv, iv_be_idx);
    if (h == LUKS_HASH_SHA512) {
        CC_SHA512_CTX c;
        CC_SHA512_Init(&c);
        CC_SHA512_Update(&c, iv, 4);
        CC_SHA512_Update(&c, in, (CC_LONG)in_len);
        CC_SHA512_Final(digest_out, &c);
    } else if (h == LUKS_HASH_SHA1) {
        CC_SHA1_CTX c;
        CC_SHA1_Init(&c);
        CC_SHA1_Update(&c, iv, 4);
        CC_SHA1_Update(&c, in, (CC_LONG)in_len);
        CC_SHA1_Final(digest_out, &c);
    } else {
        CC_SHA256_CTX c;
        CC_SHA256_Init(&c);
        CC_SHA256_Update(&c, iv, 4);
        CC_SHA256_Update(&c, in, (CC_LONG)in_len);
        CC_SHA256_Final(digest_out, &c);
    }
}

static void af_diffuse(uint8_t *buf, size_t size, luks_hash_id_t h) {
    size_t dlen = hash_digest_len(h);
    size_t blocks = size / dlen;
    size_t pad = size % dlen;
    uint8_t digest[64];
    uint8_t *tmp = (uint8_t *)malloc(size);
    if (!tmp) return;
    memcpy(tmp, buf, size);

    for (size_t i = 0; i < blocks; i++) {
        compute_hash_iv(h, (uint32_t)i, tmp + i * dlen, dlen, digest);
        memcpy(buf + i * dlen, digest, dlen);
    }
    if (pad > 0) {
        compute_hash_iv(h, (uint32_t)blocks, tmp + blocks * dlen, pad, digest);
        memcpy(buf + blocks * dlen, digest, pad);
    }
    memset(digest, 0, sizeof(digest));
    memset(tmp, 0, size);
    free(tmp);
}

static int af_merge(const uint8_t *src, uint8_t *dst, size_t blocksize, uint32_t stripes, luks_hash_id_t h) {
    if (blocksize == 0 || blocksize > 128U || stripes == 0) return -EINVAL;
    uint8_t bufblock[128];
    memset(bufblock, 0, sizeof(bufblock));
    for (uint32_t i = 0; i + 1U < stripes; i++) {
        const uint8_t *stripe = src + (size_t)i * blocksize;
        for (size_t b = 0; b < blocksize; b++) bufblock[b] ^= stripe[b];
        af_diffuse(bufblock, blocksize, h);
    }
    const uint8_t *last = src + (size_t)(stripes - 1U) * blocksize;
    for (size_t b = 0; b < blocksize; b++) dst[b] = bufblock[b] ^ last[b];
    memset(bufblock, 0, sizeof(bufblock));
    return 0;
}

static int af_split(const uint8_t *src, uint8_t *dst, size_t blocksize, uint32_t stripes, luks_hash_id_t h) {
    if (blocksize == 0 || blocksize > 128U || stripes == 0) return -EINVAL;
    uint8_t bufblock[128];
    memset(bufblock, 0, sizeof(bufblock));
    for (uint32_t i = 0; i + 1U < stripes; i++) {
        uint8_t *stripe = dst + (size_t)i * blocksize;
        arc4random_buf(stripe, blocksize);
        for (size_t b = 0; b < blocksize; b++) bufblock[b] ^= stripe[b];
        af_diffuse(bufblock, blocksize, h);
    }
    uint8_t *last = dst + (size_t)(stripes - 1U) * blocksize;
    for (size_t b = 0; b < blocksize; b++) last[b] = bufblock[b] ^ src[b];
    memset(bufblock, 0, sizeof(bufblock));
    return 0;
}

/* IEEE P1619 AES-XTS-Plain64 sector encryption/decryption */
static int aes_xts_crypt_sector(
    int encrypt,
    const uint8_t *k1,
    const uint8_t *k2,
    size_t half_key_len,
    uint64_t sector_num,
    size_t sector_size,
    const uint8_t *in,
    uint8_t *out
) {
    if ((half_key_len != 16U && half_key_len != 32U) || (sector_size % 16U) != 0 || sector_size == 0) {
        return -EINVAL;
    }

    uint8_t tweak[16];
    memset(tweak, 0, sizeof(tweak));
    cfs_put_le64(tweak, sector_num);

    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(
        kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode,
        k2, half_key_len, NULL,
        tweak, 16U, tweak, 16U, &moved
    );
    if (st != kCCSuccess) return -EIO;

    CCCryptorRef data_cryptor = NULL;
    st = CCCryptorCreate(
        encrypt ? kCCEncrypt : kCCDecrypt,
        kCCAlgorithmAES,
        kCCOptionECBMode,
        k1,
        half_key_len,
        NULL,
        &data_cryptor
    );
    if (st != kCCSuccess || !data_cryptor) return -EIO;

    size_t blocks = sector_size / 16U;
    uint8_t blk[16];
    for (size_t j = 0; j < blocks; j++) {
        const uint8_t *src = in + j * 16U;
        uint8_t *dst = out + j * 16U;
        for (size_t i = 0; i < 16U; i++) blk[i] = src[i] ^ tweak[i];
        st = CCCryptorUpdate(data_cryptor, blk, 16U, blk, 16U, &moved);
        if (st != kCCSuccess) {
            CCCryptorRelease(data_cryptor);
            return -EIO;
        }
        for (size_t i = 0; i < 16U; i++) dst[i] = blk[i] ^ tweak[i];

        uint8_t carry = (uint8_t)((tweak[15] >> 7) & 1U);
        for (int i = 15; i > 0; i--) {
            tweak[i] = (uint8_t)((tweak[i] << 1) | (tweak[i - 1] >> 7));
        }
        tweak[0] = (uint8_t)((tweak[0] << 1) ^ (carry ? 0x87U : 0x00U));
    }

    CCCryptorRelease(data_cryptor);
    memset(tweak, 0, sizeof(tweak));
    memset(blk, 0, sizeof(blk));
    return 0;
}

static int aes_xts_crypt_span(
    int encrypt,
    const uint8_t *full_key,
    size_t key_bytes,
    uint64_t start_sector_iv,
    size_t sector_size,
    const uint8_t *in,
    uint8_t *out,
    size_t total_bytes
) {
    if ((key_bytes != 32U && key_bytes != 64U) || (total_bytes % sector_size) != 0) return -EINVAL;
    size_t half = key_bytes / 2U;
    size_t sectors = total_bytes / sector_size;
    for (size_t s = 0; s < sectors; s++) {
        int rc = aes_xts_crypt_sector(
            encrypt,
            full_key,
            full_key + half,
            half,
            start_sector_iv + (uint64_t)s,
            sector_size,
            in + s * sector_size,
            out + s * sector_size
        );
        if (rc != 0) return rc;
    }
    return 0;
}

static int pbkdf2_derive(
    const char *pass,
    size_t pass_len,
    const uint8_t *salt,
    size_t salt_len,
    luks_hash_id_t hash_id,
    uint32_t iterations,
    uint8_t *out_key,
    size_t out_len
) {
    if (iterations == 0 || out_len == 0) return -EINVAL;
    /* CommonCrypto rejects empty password pointer if pass_len == 0 unless non-NULL */
    const char *safe_pass = pass ? pass : "";
    int rc = CCKeyDerivationPBKDF(
        kCCPBKDF2,
        safe_pass,
        pass_len,
        salt,
        salt_len,
        cc_prf_for_hash(hash_id),
        iterations,
        out_key,
        out_len
    );
    return (rc == kCCSuccess) ? 0 : -EIO;
}

/* Minimal Base64 decoder for LUKS2 salt/digest fields */
static int b64_decode(const char *in, size_t in_len, uint8_t *out, size_t out_cap, size_t *out_len) {
    static const int8_t tbl[256] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
        52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-2,-1,-1,
        -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
        15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
        41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    };
    size_t pos = 0;
    uint32_t val = 0;
    int bits = -8;
    for (size_t i = 0; i < in_len; i++) {
        uint8_t c = (uint8_t)in[i];
        if (c == '\\' && i + 1 < in_len && in[i + 1] == '/') continue;
        if (isspace(c)) continue;
        int8_t d = tbl[c];
        if (d == -2) break;
        if (d < 0) return -EINVAL;
        val = (val << 6) | (uint32_t)d;
        bits += 6;
        if (bits >= 0) {
            if (pos >= out_cap) return -ENOSPC;
            out[pos++] = (uint8_t)((val >> bits) & 0xFFU);
            bits -= 8;
        }
    }
    *out_len = pos;
    return 0;
}

static const char *json_find_key_in_range(const char *start, const char *end, const char *key) {
    char pat[64];
    int n = snprintf(pat, sizeof(pat), "\"%s\"", key);
    if (n <= 0 || (size_t)n >= sizeof(pat)) return NULL;
    const char *p = start;
    while (p < end) {
        const char *hit = strstr(p, pat);
        if (!hit || hit >= end) return NULL;
        const char *q = hit + n;
        while (q < end && isspace((unsigned char)*q)) q++;
        if (q < end && *q == ':') {
            q++;
            while (q < end && isspace((unsigned char)*q)) q++;
            return q;
        }
        p = hit + n;
    }
    return NULL;
}

static const char *json_matching_brace(const char *open_brace, const char *end) {
    if (!open_brace || open_brace >= end || *open_brace != '{') return NULL;
    int depth = 0;
    int in_str = 0;
    for (const char *p = open_brace; p < end; p++) {
        if (*p == '"' && (p == open_brace || p[-1] != '\\')) {
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

static int json_get_str(const char *start, const char *end, const char *key, char *out, size_t cap) {
    const char *v = json_find_key_in_range(start, end, key);
    if (!v || v >= end || *v != '"') return -ENOENT;
    v++;
    size_t i = 0;
    while (v < end && *v != '"') {
        if (*v == '\\' && v + 1 < end) v++;
        if (i + 1 < cap) out[i++] = *v;
        v++;
    }
    out[i] = '\0';
    return 0;
}

static int json_get_u64(const char *start, const char *end, const char *key, uint64_t *out) {
    const char *v = json_find_key_in_range(start, end, key);
    if (!v || v >= end) return -ENOENT;
    if (*v == '"') v++;
    if (!isdigit((unsigned char)*v)) return -EINVAL;
    *out = strtoull(v, NULL, 10);
    return 0;
}

static int raw_pread_exact(int fd, uint64_t off, size_t len, void *buf) {
    uint8_t *dst = (uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t r = pread(fd, dst + done, len - done, (off_t)(off + done));
        if (r <= 0) return -EIO;
        done += (size_t)r;
    }
    return 0;
}

static int raw_pwrite_exact(int fd, uint64_t off, size_t len, const void *buf) {
    const uint8_t *src = (const uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t w = pwrite(fd, src + done, len - done, (off_t)(off + done));
        if (w <= 0) return -EIO;
        done += (size_t)w;
    }
    return 0;
}

static void copy_trimmed_str(char *dst, size_t cap, const uint8_t *src, size_t src_len) {
    size_t n = 0;
    while (n < src_len && n + 1 < cap && src[n] != '\0') {
        dst[n] = (char)src[n];
        n++;
    }
    dst[n] = '\0';
}

static int probe_luks_fd(int fd, uint64_t dev_size, cowfs_luks_info_t *out_info, char **out_json) {
    if (out_json) *out_json = NULL;
    uint8_t hdr[4096];
    if (raw_pread_exact(fd, 0, sizeof(hdr), hdr) != 0) return -EIO;
    if (memcmp(hdr, k_luks_magic, LUKS_MAGIC_LEN) != 0) return -EINVAL;

    memset(out_info, 0, sizeof(*out_info));
    uint16_t ver = cfs_be16(hdr + 6);
    if (ver == 1U) {
        out_info->version = 1;
        copy_trimmed_str(out_info->cipher, sizeof(out_info->cipher), hdr + 8, 32);
        copy_trimmed_str(out_info->cipher_mode, sizeof(out_info->cipher_mode), hdr + 40, 32);
        copy_trimmed_str(out_info->hash_spec, sizeof(out_info->hash_spec), hdr + 72, 32);
        out_info->payload_offset = (uint64_t)cfs_be32(hdr + 104) * 512ULL;
        out_info->key_bytes = cfs_be32(hdr + 108);
        out_info->sector_size = 512U;
        copy_trimmed_str(out_info->uuid, sizeof(out_info->uuid), hdr + 168, 40);
        if (dev_size > out_info->payload_offset) {
            out_info->payload_bytes = dev_size - out_info->payload_offset;
        }
        int active = 0;
        for (int i = 0; i < 8; i++) {
            uint32_t st = cfs_be32(hdr + 208 + i * 48);
            if (st == LUKS1_KEY_ENABLED) active++;
        }
        out_info->active_slots = active;
        return 0;
    } else if (ver == 2U) {
        out_info->version = 2;
        uint64_t hdr_size = cfs_be64(hdr + 8);
        copy_trimmed_str(out_info->label, sizeof(out_info->label), hdr + 24, 48);
        copy_trimmed_str(out_info->hash_spec, sizeof(out_info->hash_spec), hdr + 72, 32);
        copy_trimmed_str(out_info->uuid, sizeof(out_info->uuid), hdr + 168, 40);
        out_info->sector_size = 512U;
        out_info->key_bytes = 64U;
        snprintf(out_info->cipher, sizeof(out_info->cipher), "aes");
        snprintf(out_info->cipher_mode, sizeof(out_info->cipher_mode), "xts-plain64");

        if (hdr_size > 4096ULL && hdr_size <= (4ULL << 20)) {
            size_t jlen = (size_t)(hdr_size - 4096ULL);
            char *jbuf = (char *)calloc(1, jlen + 1U);
            if (jbuf && raw_pread_exact(fd, 4096ULL, jlen, jbuf) == 0) {
                const char *jend = jbuf + strlen(jbuf);
                const char *segs = json_find_key_in_range(jbuf, jend, "segments");
                const char *segs_end = segs ? json_matching_brace(segs, jend) : NULL;
                if (segs && segs_end) {
                    const char *seg0 = json_find_key_in_range(segs, segs_end, "0");
                    const char *seg0_end = seg0 ? json_matching_brace(seg0, segs_end) : NULL;
                    if (seg0 && seg0_end) {
                        uint64_t off = 0, ssz = 512;
                        if (json_get_u64(seg0, seg0_end, "offset", &off) == 0) {
                            out_info->payload_offset = off;
                        }
                        if (json_get_u64(seg0, seg0_end, "sector_size", &ssz) == 0 && (ssz == 512 || ssz == 4096)) {
                            out_info->sector_size = (uint32_t)ssz;
                        }
                        char enc[64];
                        if (json_get_str(seg0, seg0_end, "encryption", enc, sizeof(enc)) == 0) {
                            const char *dash = strchr(enc, '-');
                            if (dash) {
                                size_t clen = (size_t)(dash - enc);
                                if (clen >= sizeof(out_info->cipher)) clen = sizeof(out_info->cipher) - 1;
                                memcpy(out_info->cipher, enc, clen);
                                out_info->cipher[clen] = '\0';
                                snprintf(out_info->cipher_mode, sizeof(out_info->cipher_mode), "%s", dash + 1);
                            }
                        }
                    }
                }
                const char *kslots = json_find_key_in_range(jbuf, jend, "keyslots");
                const char *kslots_end = kslots ? json_matching_brace(kslots, jend) : NULL;
                if (kslots && kslots_end) {
                    int active = 0;
                    for (int s = 0; s < 8; s++) {
                        char kname[8];
                        snprintf(kname, sizeof(kname), "%d", s);
                        const char *ks = json_find_key_in_range(kslots, kslots_end, kname);
                        const char *ks_end = ks ? json_matching_brace(ks, kslots_end) : NULL;
                        if (ks && ks_end) {
                            active++;
                            uint64_t ksz = 0;
                            if (json_get_u64(ks, ks_end, "key_size", &ksz) == 0 && (ksz == 32 || ksz == 64)) {
                                out_info->key_bytes = (uint32_t)ksz;
                            }
                        }
                    }
                    out_info->active_slots = active;
                }
                if (dev_size > out_info->payload_offset && out_info->payload_offset > 0) {
                    out_info->payload_bytes = dev_size - out_info->payload_offset;
                }
                if (out_json) *out_json = jbuf;
                else free(jbuf);
            } else {
                free(jbuf);
            }
        }
        return 0;
    }
    return -EINVAL;
}

int cowfs_luks_probe(const char *path, cowfs_luks_info_t *out_info) {
    if (!path || !out_info) return -EINVAL;
    int fd = -1;
    uint64_t sz = 0;
    uint32_t align = 1U;
    int rc = cowfs_open_device_fd(path, 1, &fd, &sz, &align);
    if (rc != 0) return rc;
    rc = probe_luks_fd(fd, sz, out_info, NULL);
    close(fd);
    return rc;
}

int cowfs_luks_format(
    const char *path,
    const char *passphrase,
    const char *label,
    uint64_t total_bytes_if_file
) {
    if (!path || !passphrase) return -EINVAL;
    (void)label;

    int fd = open(path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) return -errno;

    struct stat st;
    if (fstat(fd, &st) != 0) {
        int err = -errno;
        close(fd);
        return err;
    }
    if (S_ISREG(st.st_mode) && total_bytes_if_file > 0 && (uint64_t)st.st_size < total_bytes_if_file) {
        if (ftruncate(fd, (off_t)total_bytes_if_file) != 0) {
            int err = -errno;
            close(fd);
            return err;
        }
    }
    close(fd);

    uint64_t dev_size = 0;
    uint32_t align = 1U;
    int rc = cowfs_open_device_fd(path, 0, &fd, &dev_size, &align);
    if (rc != 0) return rc;

    /* Require at least 4 MiB (2 MiB LUKS1 header + keyslots, plus payload) */
    const uint32_t payload_offset_sec = 4096U; /* 2 MiB */
    if (dev_size < (uint64_t)payload_offset_sec * 512ULL + 65536ULL) {
        close(fd);
        return -ENOSPC;
    }

    const uint32_t key_bytes = 64U; /* AES-256-XTS (two 256-bit keys) */
    const uint32_t stripes = 4000U;
    const uint32_t mk_iters = 10000U;
    const uint32_t slot_iters = 20000U;
    const uint32_t slot0_offset_sec = 8U; /* 4096 bytes */

    uint8_t master_key[64];
    uint8_t mk_salt[32];
    uint8_t slot_salt[32];
    uint8_t mk_digest[20];
    uint8_t slot_key[64];
    uint8_t uuid_raw[16];

    arc4random_buf(master_key, sizeof(master_key));
    arc4random_buf(mk_salt, sizeof(mk_salt));
    arc4random_buf(slot_salt, sizeof(slot_salt));
    arc4random_buf(uuid_raw, sizeof(uuid_raw));
    uuid_raw[6] = (uint8_t)((uuid_raw[6] & 0x0FU) | 0x40U);
    uuid_raw[8] = (uint8_t)((uuid_raw[8] & 0x3FU) | 0x80U);

    rc = pbkdf2_derive((const char *)master_key, key_bytes, mk_salt, sizeof(mk_salt), LUKS_HASH_SHA256, mk_iters, mk_digest, sizeof(mk_digest));
    if (rc != 0) { close(fd); return rc; }

    rc = pbkdf2_derive(passphrase, strlen(passphrase), slot_salt, sizeof(slot_salt), LUKS_HASH_SHA256, slot_iters, slot_key, key_bytes);
    if (rc != 0) { close(fd); return rc; }

    size_t af_bytes = (size_t)key_bytes * (size_t)stripes;
    size_t af_alloc = ((af_bytes + 511U) / 512U) * 512U;
    uint8_t *af_plain = (uint8_t *)calloc(1, af_alloc);
    uint8_t *af_cipher = (uint8_t *)calloc(1, af_alloc);
    if (!af_plain || !af_cipher) {
        free(af_plain);
        free(af_cipher);
        close(fd);
        return -ENOMEM;
    }

    rc = af_split(master_key, af_plain, key_bytes, stripes, LUKS_HASH_SHA256);
    if (rc == 0) {
        rc = aes_xts_crypt_span(1, slot_key, key_bytes, 0ULL, 512U, af_plain, af_cipher, af_alloc);
    }

    uint8_t hdr[4096];
    memset(hdr, 0, sizeof(hdr));
    memcpy(hdr, k_luks_magic, LUKS_MAGIC_LEN);
    cfs_put_be16(hdr + 6, 1U);
    snprintf((char *)(hdr + 8), 32, "aes");
    snprintf((char *)(hdr + 40), 32, "xts-plain64");
    snprintf((char *)(hdr + 72), 32, "sha256");
    cfs_put_be32(hdr + 104, payload_offset_sec);
    cfs_put_be32(hdr + 108, key_bytes);
    memcpy(hdr + 112, mk_digest, 20);
    memcpy(hdr + 132, mk_salt, 32);
    cfs_put_be32(hdr + 164, mk_iters);
    snprintf((char *)(hdr + 168), 40,
             "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             uuid_raw[0], uuid_raw[1], uuid_raw[2], uuid_raw[3],
             uuid_raw[4], uuid_raw[5], uuid_raw[6], uuid_raw[7],
             uuid_raw[8], uuid_raw[9], uuid_raw[10], uuid_raw[11],
             uuid_raw[12], uuid_raw[13], uuid_raw[14], uuid_raw[15]);

    /* Keyslot 0 active, slots 1..7 disabled */
    for (int i = 0; i < 8; i++) {
        uint8_t *ks = hdr + 208 + i * 48;
        if (i == 0) {
            cfs_put_be32(ks + 0, LUKS1_KEY_ENABLED);
            cfs_put_be32(ks + 4, slot_iters);
            memcpy(ks + 8, slot_salt, 32);
            cfs_put_be32(ks + 40, slot0_offset_sec);
            cfs_put_be32(ks + 44, stripes);
        } else {
            cfs_put_be32(ks + 0, LUKS1_KEY_DISABLED);
            cfs_put_be32(ks + 40, slot0_offset_sec + (uint32_t)((af_alloc / 512U) * (size_t)i));
            cfs_put_be32(ks + 44, stripes);
        }
    }

    if (rc == 0) rc = raw_pwrite_exact(fd, 0ULL, sizeof(hdr), hdr);
    if (rc == 0) rc = raw_pwrite_exact(fd, (uint64_t)slot0_offset_sec * 512ULL, af_alloc, af_cipher);
    (void)fsync(fd);

    memset(master_key, 0, sizeof(master_key));
    memset(slot_key, 0, sizeof(slot_key));
    memset(af_plain, 0, af_alloc);
    free(af_plain);
    free(af_cipher);
    close(fd);
    return rc;
}

static int unlock_luks1(int fd, const cowfs_luks_info_t *info, const char *passphrase, uint8_t *out_master_key) {
    uint8_t hdr[1024];
    int rc = raw_pread_exact(fd, 0, sizeof(hdr), hdr);
    if (rc != 0) return rc;

    if (strncmp(info->cipher, "aes", 3) != 0 || strncmp(info->cipher_mode, "xts-plain", 9) != 0) {
        return -ENOTSUP;
    }
    if (info->key_bytes != 32U && info->key_bytes != 64U) {
        return -ENOTSUP;
    }

    luks_hash_id_t hash_id = parse_hash_spec(info->hash_spec);
    const uint8_t *mk_digest = hdr + 112;
    const uint8_t *mk_salt = hdr + 132;
    uint32_t mk_iters = cfs_be32(hdr + 164);

    for (int i = 0; i < 8; i++) {
        const uint8_t *ks = hdr + 208 + i * 48;
        uint32_t active = cfs_be32(ks + 0);
        if (active != LUKS1_KEY_ENABLED) continue;

        uint32_t iters = cfs_be32(ks + 4);
        const uint8_t *salt = ks + 8;
        uint32_t km_sec = cfs_be32(ks + 40);
        uint32_t stripes = cfs_be32(ks + 44);
        if (iters == 0 || stripes == 0 || stripes > 65536U) continue;

        size_t af_bytes = (size_t)info->key_bytes * (size_t)stripes;
        size_t af_alloc = ((af_bytes + 511U) / 512U) * 512U;
        uint8_t *af_cipher = (uint8_t *)malloc(af_alloc);
        uint8_t *af_plain = (uint8_t *)malloc(af_alloc);
        if (!af_cipher || !af_plain) {
            free(af_cipher);
            free(af_plain);
            return -ENOMEM;
        }

        if (raw_pread_exact(fd, (uint64_t)km_sec * 512ULL, af_alloc, af_cipher) != 0) {
            free(af_cipher);
            free(af_plain);
            continue;
        }

        uint8_t slot_key[64];
        uint8_t candidate_mk[64];
        uint8_t check_digest[20];
        if (pbkdf2_derive(passphrase, strlen(passphrase), salt, 32U, hash_id, iters, slot_key, info->key_bytes) == 0 &&
            aes_xts_crypt_span(0, slot_key, info->key_bytes, 0ULL, 512U, af_cipher, af_plain, af_alloc) == 0 &&
            af_merge(af_plain, candidate_mk, info->key_bytes, stripes, hash_id) == 0 &&
            pbkdf2_derive((const char *)candidate_mk, info->key_bytes, mk_salt, 32U, hash_id, mk_iters, check_digest, 20U) == 0 &&
            memcmp(check_digest, mk_digest, 20U) == 0) {
            memcpy(out_master_key, candidate_mk, info->key_bytes);
            memset(slot_key, 0, sizeof(slot_key));
            memset(candidate_mk, 0, sizeof(candidate_mk));
            memset(af_plain, 0, af_alloc);
            free(af_cipher);
            free(af_plain);
            return 0;
        }

        memset(slot_key, 0, sizeof(slot_key));
        memset(candidate_mk, 0, sizeof(candidate_mk));
        memset(af_plain, 0, af_alloc);
        free(af_cipher);
        free(af_plain);
    }
    return -EACCES;
}

static int unlock_luks2(int fd, const cowfs_luks_info_t *info, const char *json_str, const char *passphrase, uint8_t *out_master_key, uint64_t *out_iv_offset) {
    if (!json_str) return -EINVAL;
    *out_iv_offset = 0;
    const char *jend = json_str + strlen(json_str);

    const char *segs = json_find_key_in_range(json_str, jend, "segments");
    const char *segs_end = segs ? json_matching_brace(segs, jend) : NULL;
    if (segs && segs_end) {
        const char *seg0 = json_find_key_in_range(segs, segs_end, "0");
        const char *seg0_end = seg0 ? json_matching_brace(seg0, segs_end) : NULL;
        if (seg0 && seg0_end) {
            uint64_t ivt = 0;
            if (json_get_u64(seg0, seg0_end, "iv_tweak", &ivt) == 0) *out_iv_offset = ivt;
        }
    }

    /* Parse digest 0 */
    const char *digs = json_find_key_in_range(json_str, jend, "digests");
    const char *digs_end = digs ? json_matching_brace(digs, jend) : NULL;
    const char *dig0 = digs ? json_find_key_in_range(digs, digs_end, "0") : NULL;
    const char *dig0_end = dig0 ? json_matching_brace(dig0, digs_end) : NULL;
    if (!dig0 || !dig0_end) return -EINVAL;

    char dig_hash[32] = "sha256", dig_salt_b64[128] = "", dig_val_b64[128] = "";
    uint64_t dig_iters = 0;
    if (json_get_str(dig0, dig0_end, "hash", dig_hash, sizeof(dig_hash)) != 0 ||
        json_get_u64(dig0, dig0_end, "iterations", &dig_iters) != 0 ||
        json_get_str(dig0, dig0_end, "salt", dig_salt_b64, sizeof(dig_salt_b64)) != 0 ||
        json_get_str(dig0, dig0_end, "digest", dig_val_b64, sizeof(dig_val_b64)) != 0) {
        return -ENOTSUP;
    }
    uint8_t dig_salt[64], dig_expected[64];
    size_t dig_salt_len = 0, dig_expected_len = 0;
    if (b64_decode(dig_salt_b64, strlen(dig_salt_b64), dig_salt, sizeof(dig_salt), &dig_salt_len) != 0 ||
        b64_decode(dig_val_b64, strlen(dig_val_b64), dig_expected, sizeof(dig_expected), &dig_expected_len) != 0 ||
        dig_expected_len == 0) {
        return -EINVAL;
    }

    const char *kslots = json_find_key_in_range(json_str, jend, "keyslots");
    const char *kslots_end = kslots ? json_matching_brace(kslots, jend) : NULL;
    if (!kslots || !kslots_end) return -EINVAL;

    int saw_unsupported_kdf = 0;
    for (int s = 0; s < 8; s++) {
        char kname[8];
        snprintf(kname, sizeof(kname), "%d", s);
        const char *ks = json_find_key_in_range(kslots, kslots_end, kname);
        const char *ks_end = ks ? json_matching_brace(ks, kslots_end) : NULL;
        if (!ks || !ks_end) continue;

        const char *kdf = json_find_key_in_range(ks, ks_end, "kdf");
        const char *kdf_end = kdf ? json_matching_brace(kdf, ks_end) : NULL;
        const char *af = json_find_key_in_range(ks, ks_end, "af");
        const char *af_end = af ? json_matching_brace(af, ks_end) : NULL;
        const char *area = json_find_key_in_range(ks, ks_end, "area");
        const char *area_end = area ? json_matching_brace(area, ks_end) : NULL;
        if (!kdf || !kdf_end || !af || !af_end || !area || !area_end) continue;

        char kdf_type[32] = "";
        if (json_get_str(kdf, kdf_end, "type", kdf_type, sizeof(kdf_type)) != 0) continue;
        int is_pbkdf2 = (strcmp(kdf_type, "pbkdf2") == 0);
        int is_argon2id = (strcmp(kdf_type, "argon2id") == 0);
        int is_argon2i = (strcmp(kdf_type, "argon2i") == 0);
        if (!is_pbkdf2 && !is_argon2id && !is_argon2i) {
            saw_unsupported_kdf = 1;
            continue;
        }

        char kdf_hash[32] = "sha256", kdf_salt_b64[128] = "", af_hash[32] = "sha256";
        uint64_t kdf_iters = 0, argon_time = 4, argon_mem = 65536, argon_cpus = 1;
        uint64_t stripes = 4000, area_off = 0, area_key_size = info->key_bytes;
        if (json_get_str(kdf, kdf_end, "salt", kdf_salt_b64, sizeof(kdf_salt_b64)) != 0 ||
            json_get_u64(area, area_end, "offset", &area_off) != 0) {
            continue;
        }
        if (is_pbkdf2) {
            if (json_get_str(kdf, kdf_end, "hash", kdf_hash, sizeof(kdf_hash)) != 0 ||
                json_get_u64(kdf, kdf_end, "iterations", &kdf_iters) != 0) {
                continue;
            }
        } else {
            if (json_get_u64(kdf, kdf_end, "time", &argon_time) != 0 ||
                json_get_u64(kdf, kdf_end, "memory", &argon_mem) != 0 ||
                json_get_u64(kdf, kdf_end, "cpus", &argon_cpus) != 0) {
                continue;
            }
        }
        (void)json_get_str(af, af_end, "hash", af_hash, sizeof(af_hash));
        (void)json_get_u64(af, af_end, "stripes", &stripes);
        (void)json_get_u64(area, area_end, "key_size", &area_key_size);
        if ((area_key_size != 32 && area_key_size != 64) || stripes == 0 || stripes > 65536) continue;

        uint8_t slot_salt[64];
        size_t slot_salt_len = 0;
        if (b64_decode(kdf_salt_b64, strlen(kdf_salt_b64), slot_salt, sizeof(slot_salt), &slot_salt_len) != 0) continue;

        size_t af_bytes = (size_t)info->key_bytes * (size_t)stripes;
        size_t af_alloc = ((af_bytes + 511U) / 512U) * 512U;
        uint8_t *af_cipher = (uint8_t *)malloc(af_alloc);
        uint8_t *af_plain = (uint8_t *)malloc(af_alloc);
        if (!af_cipher || !af_plain) {
            free(af_cipher);
            free(af_plain);
            return -ENOMEM;
        }

        if (raw_pread_exact(fd, area_off, af_alloc, af_cipher) == 0) {
            uint8_t slot_key[64], candidate_mk[64], check_dig[64];
            int kdf_rc = is_pbkdf2
                ? pbkdf2_derive(passphrase, strlen(passphrase), slot_salt, slot_salt_len, parse_hash_spec(kdf_hash), (uint32_t)kdf_iters, slot_key, (size_t)area_key_size)
                : cowfs_argon2_derive(
                    is_argon2id ? COWFS_ARGON2_ID : COWFS_ARGON2_I,
                    passphrase,
                    strlen(passphrase),
                    slot_salt,
                    slot_salt_len,
                    (uint32_t)argon_time,
                    (uint32_t)argon_mem,
                    (uint32_t)argon_cpus,
                    slot_key,
                    (size_t)area_key_size
                );
            if (kdf_rc == 0 &&
                aes_xts_crypt_span(0, slot_key, (size_t)area_key_size, 0ULL, 512U, af_cipher, af_plain, af_alloc) == 0 &&
                af_merge(af_plain, candidate_mk, info->key_bytes, (uint32_t)stripes, parse_hash_spec(af_hash)) == 0 &&
                pbkdf2_derive((const char *)candidate_mk, info->key_bytes, dig_salt, dig_salt_len, parse_hash_spec(dig_hash), (uint32_t)dig_iters, check_dig, dig_expected_len) == 0 &&
                memcmp(check_dig, dig_expected, dig_expected_len) == 0) {
                memcpy(out_master_key, candidate_mk, info->key_bytes);
                memset(slot_key, 0, sizeof(slot_key));
                memset(candidate_mk, 0, sizeof(candidate_mk));
                memset(af_plain, 0, af_alloc);
                free(af_cipher);
                free(af_plain);
                return 0;
            }
            memset(slot_key, 0, sizeof(slot_key));
            memset(candidate_mk, 0, sizeof(candidate_mk));
        }
        memset(af_plain, 0, af_alloc);
        free(af_cipher);
        free(af_plain);
    }
    return saw_unsupported_kdf ? -ENOTSUP : -EACCES;
}

int cowfs_luks_unlock(
    const char *path,
    const char *passphrase,
    int read_only,
    cowfs_luks_t **out_ctx
) {
    if (!path || !passphrase || !out_ctx) return -EINVAL;
    *out_ctx = NULL;

    int fd = -1;
    uint64_t dev_size = 0;
    uint32_t align = 1U;
    int rc = cowfs_open_device_fd(path, read_only, &fd, &dev_size, &align);
    if (rc != 0) return rc;

    cowfs_luks_info_t info;
    char *json_str = NULL;
    rc = probe_luks_fd(fd, dev_size, &info, &json_str);
    if (rc != 0) {
        free(json_str);
        close(fd);
        return rc;
    }

    uint8_t master_key[64];
    memset(master_key, 0, sizeof(master_key));
    uint64_t iv_offset = 0;
    if (info.version == 1) {
        rc = unlock_luks1(fd, &info, passphrase, master_key);
    } else if (info.version == 2) {
        rc = unlock_luks2(fd, &info, json_str, passphrase, master_key, &iv_offset);
    } else {
        rc = -ENOTSUP;
    }
    free(json_str);

    if (rc != 0) {
        memset(master_key, 0, sizeof(master_key));
        close(fd);
        return rc;
    }

    cowfs_luks_t *ctx = (cowfs_luks_t *)calloc(1, sizeof(cowfs_luks_t));
    if (!ctx) {
        memset(master_key, 0, sizeof(master_key));
        close(fd);
        return -ENOMEM;
    }
    ctx->fb.fd = fd;
    ctx->fb.read_only = read_only ? 1 : 0;
    ctx->fb.align = align;
    ctx->fb.size = dev_size;
    ctx->info = info;
    ctx->iv_offset = iv_offset;
    ctx->half_key_len = info.key_bytes / 2U;
    memcpy(ctx->key1, master_key, ctx->half_key_len);
    memcpy(ctx->key2, master_key + ctx->half_key_len, ctx->half_key_len);
    pthread_mutex_init(&ctx->lock, NULL);
    memset(master_key, 0, sizeof(master_key));

    *out_ctx = ctx;
    return 0;
}

void cowfs_luks_close(cowfs_luks_t *ctx) {
    if (!ctx) return;
    pthread_mutex_lock(&ctx->lock);
    if (!ctx->fb.read_only && ctx->fb.fd >= 0) {
        (void)fsync(ctx->fb.fd);
    }
    if (ctx->fb.fd >= 0) {
        close(ctx->fb.fd);
        ctx->fb.fd = -1;
    }
    memset(ctx->key1, 0, sizeof(ctx->key1));
    memset(ctx->key2, 0, sizeof(ctx->key2));
    pthread_mutex_unlock(&ctx->lock);
    pthread_mutex_destroy(&ctx->lock);
    free(ctx);
}

uint64_t cowfs_luks_size(const cowfs_luks_t *ctx) {
    return ctx ? ctx->info.payload_bytes : 0ULL;
}

int cowfs_luks_pread(cowfs_luks_t *ctx, uint64_t offset, size_t length, void *buffer) {
    if (!ctx || (!buffer && length > 0)) return -EINVAL;
    if (length == 0) return 0;
    if (offset + length > ctx->info.payload_bytes) return -EIO;

    uint32_t ssz = ctx->info.sector_size ? ctx->info.sector_size : 512U;
    uint64_t first_sec = offset / ssz;
    uint64_t last_sec = (offset + length - 1ULL) / ssz;
    size_t sec_count = (size_t)(last_sec - first_sec + 1ULL);
    size_t span_bytes = sec_count * (size_t)ssz;

    uint8_t *cipher = (uint8_t *)malloc(span_bytes);
    uint8_t *plain = (uint8_t *)malloc(span_bytes);
    if (!cipher || !plain) {
        free(cipher);
        free(plain);
        return -ENOMEM;
    }

    pthread_mutex_lock(&ctx->lock);
    int rc = raw_pread_exact(ctx->fb.fd, ctx->info.payload_offset + first_sec * ssz, span_bytes, cipher);
    if (rc == 0) {
        uint64_t iv_mul = (ctx->info.version == 1) ? (ssz / 512U) : 1ULL;
        for (size_t s = 0; s < sec_count; s++) {
            uint64_t sec_iv = ctx->iv_offset + (first_sec + (uint64_t)s) * iv_mul;
            rc = aes_xts_crypt_sector(0, ctx->key1, ctx->key2, ctx->half_key_len, sec_iv, ssz, cipher + s * ssz, plain + s * ssz);
            if (rc != 0) break;
        }
    }
    pthread_mutex_unlock(&ctx->lock);

    if (rc == 0) {
        memcpy(buffer, plain + (size_t)(offset - first_sec * ssz), length);
    }
    memset(plain, 0, span_bytes);
    free(cipher);
    free(plain);
    return rc;
}

int cowfs_luks_pwrite(cowfs_luks_t *ctx, uint64_t offset, size_t length, const void *buffer) {
    if (!ctx || (!buffer && length > 0)) return -EINVAL;
    if (ctx->fb.read_only) return -EROFS;
    if (length == 0) return 0;
    if (offset + length > ctx->info.payload_bytes) return -ENOSPC;

    uint32_t ssz = ctx->info.sector_size ? ctx->info.sector_size : 512U;
    uint64_t first_sec = offset / ssz;
    uint64_t last_sec = (offset + length - 1ULL) / ssz;
    size_t sec_count = (size_t)(last_sec - first_sec + 1ULL);
    size_t span_bytes = sec_count * (size_t)ssz;

    uint8_t *cipher = (uint8_t *)malloc(span_bytes);
    uint8_t *plain = (uint8_t *)malloc(span_bytes);
    if (!cipher || !plain) {
        free(cipher);
        free(plain);
        return -ENOMEM;
    }

    pthread_mutex_lock(&ctx->lock);
    int rc = 0;
    uint64_t iv_mul = (ctx->info.version == 1) ? (ssz / 512U) : 1ULL;

    /* Read-modify-write if unaligned at head or tail */
    if ((offset % ssz) != 0 || ((offset + length) % ssz) != 0) {
        rc = raw_pread_exact(ctx->fb.fd, ctx->info.payload_offset + first_sec * ssz, span_bytes, cipher);
        if (rc == 0) {
            for (size_t s = 0; s < sec_count; s++) {
                uint64_t sec_iv = ctx->iv_offset + (first_sec + (uint64_t)s) * iv_mul;
                rc = aes_xts_crypt_sector(0, ctx->key1, ctx->key2, ctx->half_key_len, sec_iv, ssz, cipher + s * ssz, plain + s * ssz);
                if (rc != 0) break;
            }
        }
    }
    if (rc == 0) {
        memcpy(plain + (size_t)(offset - first_sec * ssz), buffer, length);
        for (size_t s = 0; s < sec_count; s++) {
            uint64_t sec_iv = ctx->iv_offset + (first_sec + (uint64_t)s) * iv_mul;
            rc = aes_xts_crypt_sector(1, ctx->key1, ctx->key2, ctx->half_key_len, sec_iv, ssz, plain + s * ssz, cipher + s * ssz);
            if (rc != 0) break;
        }
        if (rc == 0) {
            rc = raw_pwrite_exact(ctx->fb.fd, ctx->info.payload_offset + first_sec * ssz, span_bytes, cipher);
        }
    }
    pthread_mutex_unlock(&ctx->lock);

    memset(plain, 0, span_bytes);
    free(cipher);
    free(plain);
    return rc;
}

/* ---------------- LVM2 Physical Volume & Linear LV Metadata Scanner ---------------- */

static const char *skip_ws_comments(const char *p, const char *end) {
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

static int read_lvm_ident(const char **pp, const char *end, char *out, size_t cap) {
    const char *p = skip_ws_comments(*pp, end);
    if (p >= end) return -1;
    size_t i = 0;
    if (*p == '"') {
        p++;
        while (p < end && *p != '"') {
            if (i + 1 < cap) out[i++] = *p;
            p++;
        }
        if (p < end && *p == '"') p++;
    } else {
        while (p < end && (isalnum((unsigned char)*p) || *p == '_' || *p == '-' || *p == '.')) {
            if (i + 1 < cap) out[i++] = *p;
            p++;
        }
    }
    if (i == 0) return -1;
    out[i] = '\0';
    *pp = p;
    return 0;
}

static const char *lvm_matching_brace(const char *open_brace, const char *end) {
    if (!open_brace || open_brace >= end || *open_brace != '{') return NULL;
    int depth = 0;
    int in_str = 0;
    for (const char *p = open_brace; p < end; p++) {
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

static int lvm_find_u64_prop(const char *start, const char *end, const char *prop_name, uint64_t *out_val) {
    size_t plen = strlen(prop_name);
    for (const char *p = start; p + plen < end; p++) {
        if (memcmp(p, prop_name, plen) == 0 &&
            (p == start || !isalnum((unsigned char)p[-1])) &&
            !isalnum((unsigned char)p[plen]) && p[plen] != '_') {
            const char *q = skip_ws_comments(p + plen, end);
            if (q < end && *q == '=') {
                q = skip_ws_comments(q + 1, end);
                if (q < end && isdigit((unsigned char)*q)) {
                    *out_val = strtoull(q, NULL, 10);
                    return 0;
                }
            }
        }
    }
    return -ENOENT;
}

int cowfs_lvm_scan(const char *path, cowfs_lvm_vg_info_t *out_vg) {
    if (!path || !out_vg) return -EINVAL;
    memset(out_vg, 0, sizeof(*out_vg));

    int fd = -1;
    uint64_t dev_size = 0;
    uint32_t align = 1U;
    int rc = cowfs_open_device_fd(path, 1, &fd, &dev_size, &align);
    if (rc != 0) return rc;

    /* Scan sectors 0..3 for LABELONE */
    uint8_t sec[512];
    int found_label = 0;
    for (uint64_t s = 0; s < 4ULL; s++) {
        if (raw_pread_exact(fd, s * 512ULL, sizeof(sec), sec) == 0 &&
            memcmp(sec, "LABELONE", 8) == 0 &&
            memcmp(sec + 24, "LVM2 001", 8) == 0) {
            found_label = 1;
            break;
        }
    }
    if (!found_label) {
        close(fd);
        return -EINVAL;
    }

    uint32_t pv_hdr_rel = cfs_le32(sec + 20);
    if (pv_hdr_rel < 32U || pv_hdr_rel + 80U > 512U) {
        close(fd);
        return -EINVAL;
    }

    const uint8_t *pvh = sec + pv_hdr_rel;
    /* Format 32-char LVM PV UUID as 6-4-4-4-4-4-6 */
    char raw_uuid[33];
    memcpy(raw_uuid, pvh, 32);
    raw_uuid[32] = '\0';
    snprintf(out_vg->pv_uuid, sizeof(out_vg->pv_uuid),
             "%.6s-%.4s-%.4s-%.4s-%.4s-%.4s-%.6s",
             raw_uuid, raw_uuid + 6, raw_uuid + 10, raw_uuid + 14,
             raw_uuid + 18, raw_uuid + 22, raw_uuid + 26);

    /* Parse Data Area disk_locn list followed by Metadata Area disk_locn list */
    uint64_t pe_start = 1048576ULL; /* default 1 MiB if unspecified */
    uint64_t mda_offset = 4096ULL;
    uint64_t mda_size = 0ULL;

    size_t pos = pv_hdr_rel + 40U;
    int first_da = 1;
    while (pos + 16U <= 512U) {
        uint64_t da_off = cfs_le64(sec + pos);
        uint64_t da_sz = cfs_le64(sec + pos + 8);
        pos += 16U;
        if (da_off == 0 && da_sz == 0) break;
        if (first_da) {
            pe_start = da_off;
            first_da = 0;
        }
    }
    while (pos + 16U <= 512U) {
        uint64_t mo = cfs_le64(sec + pos);
        uint64_t ms = cfs_le64(sec + pos + 8);
        pos += 16U;
        if (mo == 0 && ms == 0) break;
        mda_offset = mo;
        mda_size = ms;
        break;
    }

    /* Read MDA header (512 bytes) */
    uint8_t mdah[512];
    static const uint8_t k_fmtt_magic[16] = {
        ' ', 'L', 'V', 'M', '2', ' ', 'x', '[', '5', 'A', '%', 'r', '0', 'N', '*', '>'
    };
    if (raw_pread_exact(fd, mda_offset, sizeof(mdah), mdah) != 0 ||
        memcmp(mdah + 4, k_fmtt_magic, 16) != 0) {
        close(fd);
        /* Valid PV without MDA text yet */
        snprintf(out_vg->vg_name, sizeof(out_vg->vg_name), "unassigned_pv");
        return 0;
    }

    if (mda_size == 0) mda_size = cfs_le64(mdah + 32);
    uint64_t rlocn_off = cfs_le64(mdah + 40);
    uint64_t rlocn_size = cfs_le64(mdah + 48);
    if (rlocn_off == 0 || rlocn_size == 0 || rlocn_size > (2ULL << 20)) {
        close(fd);
        snprintf(out_vg->vg_name, sizeof(out_vg->vg_name), "empty_vg");
        return 0;
    }

    char *meta = (char *)calloc(1, (size_t)rlocn_size + 1U);
    if (!meta) {
        close(fd);
        return -ENOMEM;
    }

    /* Handle circular wrap inside MDA if needed */
    if (mda_size > 512ULL && rlocn_off + rlocn_size > mda_size) {
        size_t first_part = (size_t)(mda_size - rlocn_off);
        rc = raw_pread_exact(fd, mda_offset + rlocn_off, first_part, meta);
        if (rc == 0) {
            rc = raw_pread_exact(fd, mda_offset + 512ULL, (size_t)rlocn_size - first_part, meta + first_part);
        }
    } else {
        rc = raw_pread_exact(fd, mda_offset + rlocn_off, (size_t)rlocn_size, meta);
    }
    close(fd);

    if (rc != 0) {
        free(meta);
        return rc;
    }

    const char *mend = meta + strlen(meta);
    const char *p = meta;
    char vg_name[64];
    if (read_lvm_ident(&p, mend, vg_name, sizeof(vg_name)) != 0) {
        free(meta);
        return -EINVAL;
    }
    p = skip_ws_comments(p, mend);
    const char *vg_end = lvm_matching_brace(p, mend);
    if (!vg_end) {
        free(meta);
        return -EINVAL;
    }

    snprintf(out_vg->vg_name, sizeof(out_vg->vg_name), "%s", vg_name);
    uint64_t extent_sectors = 8192ULL; /* default 4 MiB = 8192 * 512B */
    (void)lvm_find_u64_prop(p + 1, vg_end, "extent_size", &extent_sectors);
    out_vg->extent_bytes = extent_sectors * 512ULL;

    /* Locate logical_volumes { ... } block */
    const char *lv_kw = strstr(p + 1, "logical_volumes");
    if (lv_kw && lv_kw < vg_end) {
        const char *lb = skip_ws_comments(lv_kw + strlen("logical_volumes"), vg_end);
        const char *lb_end = lvm_matching_brace(lb, vg_end);
        if (lb && lb_end) {
            const char *cur = lb + 1;
            while (cur < lb_end - 1 && out_vg->lv_count < 16U) {
                char lv_name[64];
                if (read_lvm_ident(&cur, lb_end - 1, lv_name, sizeof(lv_name)) != 0) break;
                cur = skip_ws_comments(cur, lb_end - 1);
                if (cur >= lb_end - 1 || *cur != '{') break;
                const char *lv_close = lvm_matching_brace(cur, lb_end);
                if (!lv_close) break;

                /* Sum extent_count across segments and extract first stripe start PE */
                uint64_t total_extents = 0;
                uint64_t first_pe = 0;
                const char *seg_p = cur + 1;
                int first_seg = 1;
                while (seg_p < lv_close - 1) {
                    char seg_name[64];
                    if (read_lvm_ident(&seg_p, lv_close - 1, seg_name, sizeof(seg_name)) != 0) break;
                    seg_p = skip_ws_comments(seg_p, lv_close - 1);
                    if (seg_p < lv_close - 1 && *seg_p == '=') {
                        /* Skip scalar property assignment */
                        while (seg_p < lv_close - 1 && *seg_p != '\n') seg_p++;
                        continue;
                    }
                    if (seg_p >= lv_close - 1 || *seg_p != '{') break;
                    const char *seg_close = lvm_matching_brace(seg_p, lv_close);
                    if (!seg_close) break;

                    uint64_t ec = 0;
                    if (lvm_find_u64_prop(seg_p + 1, seg_close, "extent_count", &ec) == 0) {
                        total_extents += ec;
                    }
                    if (first_seg) {
                        const char *stripes = strstr(seg_p + 1, "stripes");
                        if (stripes && stripes < seg_close) {
                            const char *br = memchr(stripes, '[', (size_t)(seg_close - stripes));
                            const char *comma = br ? memchr(br, ',', (size_t)(seg_close - br)) : NULL;
                            if (comma) {
                                const char *num = skip_ws_comments(comma + 1, seg_close);
                                if (num < seg_close && isdigit((unsigned char)*num)) {
                                    first_pe = strtoull(num, NULL, 10);
                                }
                            }
                        }
                        first_seg = 0;
                    }
                    seg_p = seg_close;
                }

                if (total_extents > 0) {
                    cowfs_lvm_lv_t *dst = &out_vg->lvs[out_vg->lv_count++];
                    snprintf(dst->name, sizeof(dst->name), "%s", lv_name);
                    dst->size_bytes = total_extents * out_vg->extent_bytes;
                    dst->pv_byte_offset = pe_start + first_pe * out_vg->extent_bytes;
                }
                cur = lv_close;
            }
        }
    }

    free(meta);
    return 0;
}
