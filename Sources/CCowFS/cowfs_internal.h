#ifndef MONTSERRAT_COWFS_INTERNAL_H
#define MONTSERRAT_COWFS_INTERNAL_H

#include "include/cowfs_bridge.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#ifndef EUCLEAN
#ifdef EFTYPE
#define EUCLEAN EFTYPE
#else
#define EUCLEAN EIO
#endif
#endif

typedef struct {
    int      fd;
    int      read_only;
    uint32_t align;
    uint64_t size;
} cowfs_fd_backend_t;

typedef struct cowfs_ops {
    int (*mount)(cowfs_t *fs);
    void (*unmount)(cowfs_t *fs);
    int (*sync)(cowfs_t *fs);
    uint64_t (*root_ino)(const cowfs_t *fs);
    int (*statfs)(cowfs_t *fs, uint64_t *total_bytes, uint64_t *free_bytes, uint32_t *block_size);
    int (*getattr)(cowfs_t *fs, uint64_t ino, cowfs_item_attrs_t *out_attrs);
    int (*setattr)(cowfs_t *fs, uint64_t ino, uint32_t mask, const cowfs_item_attrs_t *in_attrs);
    int (*lookup)(cowfs_t *fs, uint64_t dir_ino, const char *name, uint64_t *out_ino);
    int (*readdir)(cowfs_t *fs, uint64_t dir_ino, uint64_t start_cookie, cowfs_dir_cb cb, void *user_ctx);
    int (*read)(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, void *buffer, size_t *out_read);
    int (*write)(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, const void *buffer, size_t *out_written);
    int (*create)(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino);
    int (*mkdir)(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino);
    int (*unlink)(cowfs_t *fs, uint64_t dir_ino, const char *name);
    int (*rmdir)(cowfs_t *fs, uint64_t dir_ino, const char *name);
    int (*rename)(cowfs_t *fs, uint64_t old_dir_ino, const char *old_name, uint64_t new_dir_ino, const char *new_name);
    int (*symlink)(cowfs_t *fs, uint64_t dir_ino, const char *name, const char *target, uint64_t *out_ino);
    int (*readlink)(cowfs_t *fs, uint64_t ino, char *buffer, size_t buffer_cap, size_t *out_len);
} cowfs_ops_t;

struct cowfs_handle {
    cowfs_kind_t       kind;
    uint64_t           total_bytes;
    int                read_only;
    pthread_mutex_t    lock;
    void              *io_ctx;
    cowfs_io_read_fn   read_fn;
    cowfs_io_write_fn  write_fn;
    cowfs_io_flush_fn  flush_fn;
    cowfs_fd_backend_t *owned_fd_backend;
    const cowfs_ops_t *ops;
    void              *priv;
};

int cowfs_open_device_fd(const char *path, int read_only, int *out_fd, uint64_t *out_size, uint32_t *out_align);
int cowfs_io_read(const cowfs_t *fs, uint64_t off, size_t len, void *buf);
int cowfs_io_write(cowfs_t *fs, uint64_t off, size_t len, const void *buf);

int cowfs_xfs_mkfs_impl(cowfs_t *fs, const char *label, uint32_t block_size);
int cowfs_xfs_fsck_impl(cowfs_t *fs, int auto_fix, char *report_buf, size_t report_cap);
extern const cowfs_ops_t g_cowfs_xfs_ops;

int cowfs_btrfs_mkfs_impl(cowfs_t *fs, const char *label, uint32_t node_size);
int cowfs_btrfs_fsck_impl(cowfs_t *fs, int auto_fix, char *report_buf, size_t report_cap);
extern const cowfs_ops_t g_cowfs_btrfs_ops;

static inline uint16_t cfs_le16(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return (uint16_t)b[0] | ((uint16_t)b[1] << 8);
}
static inline uint32_t cfs_le32(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}
static inline uint64_t cfs_le64(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return (uint64_t)cfs_le32(b) | ((uint64_t)cfs_le32(b + 4) << 32);
}
static inline void cfs_put_le16(void *p, uint16_t v) {
    uint8_t *b = (uint8_t *)p;
    b[0] = (uint8_t)(v & 0xFFU);
    b[1] = (uint8_t)(v >> 8);
}
static inline void cfs_put_le32(void *p, uint32_t v) {
    uint8_t *b = (uint8_t *)p;
    b[0] = (uint8_t)(v & 0xFFU);
    b[1] = (uint8_t)((v >> 8) & 0xFFU);
    b[2] = (uint8_t)((v >> 16) & 0xFFU);
    b[3] = (uint8_t)((v >> 24) & 0xFFU);
}
static inline void cfs_put_le64(void *p, uint64_t v) {
    cfs_put_le32(p, (uint32_t)(v & 0xFFFFFFFFULL));
    cfs_put_le32((uint8_t *)p + 4, (uint32_t)(v >> 32));
}

static inline uint16_t cfs_be16(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return ((uint16_t)b[0] << 8) | (uint16_t)b[1];
}
static inline uint32_t cfs_be32(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}
static inline uint64_t cfs_be64(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return ((uint64_t)cfs_be32(b) << 32) | (uint64_t)cfs_be32(b + 4);
}
static inline void cfs_put_be16(void *p, uint16_t v) {
    uint8_t *b = (uint8_t *)p;
    b[0] = (uint8_t)(v >> 8);
    b[1] = (uint8_t)(v & 0xFFU);
}
static inline void cfs_put_be32(void *p, uint32_t v) {
    uint8_t *b = (uint8_t *)p;
    b[0] = (uint8_t)((v >> 24) & 0xFFU);
    b[1] = (uint8_t)((v >> 16) & 0xFFU);
    b[2] = (uint8_t)((v >> 8) & 0xFFU);
    b[3] = (uint8_t)(v & 0xFFU);
}
static inline void cfs_put_be64(void *p, uint64_t v) {
    cfs_put_be32(p, (uint32_t)(v >> 32));
    cfs_put_be32((uint8_t *)p + 4, (uint32_t)(v & 0xFFFFFFFFULL));
}

#endif /* MONTSERRAT_COWFS_INTERNAL_H */
