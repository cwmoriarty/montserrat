#ifndef MONTSERRAT_COWFS_BRIDGE_H
#define MONTSERRAT_COWFS_BRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    COWFS_KIND_XFS = 1,
    COWFS_KIND_BTRFS = 2
} cowfs_kind_t;

typedef struct {
    uint64_t ino;
    uint32_t mode;
    uint32_t uid;
    uint32_t gid;
    uint32_t nlink;
    uint64_t size;
    uint64_t alloc_size;
    int64_t  atime_sec;
    int64_t  mtime_sec;
    int64_t  ctime_sec;
    uint8_t  file_type; /* 1 = reg, 2 = dir, 3 = symlink */
} cowfs_item_attrs_t;

/* Attribute update mask bits */
#define COWFS_ATTR_MODE   0x01U
#define COWFS_ATTR_UID    0x02U
#define COWFS_ATTR_GID    0x04U
#define COWFS_ATTR_MTIME  0x08U
#define COWFS_ATTR_ATIME  0x10U
#define COWFS_ATTR_SIZE   0x20U

typedef int (*cowfs_dir_cb)(
    void *user_ctx,
    const char *name,
    uint64_t ino,
    uint8_t file_type,
    uint64_t next_cookie
);

typedef int (*cowfs_io_read_fn)(void *io_ctx, uint64_t offset, size_t length, void *buffer);
typedef int (*cowfs_io_write_fn)(void *io_ctx, uint64_t offset, size_t length, const void *buffer);
typedef int (*cowfs_io_flush_fn)(void *io_ctx);

typedef struct cowfs_handle cowfs_t;

/* Castagnoli CRC32c helper */
uint32_t cowfs_crc32c(uint32_t crc, const void *buf, size_t len);

/* Format and Check/Repair */
int cowfs_mkfs(cowfs_kind_t kind, const char *path, const char *label, uint32_t block_size);
int cowfs_fsck(cowfs_kind_t kind, const char *path, int auto_fix, char *report_buf, size_t report_cap);

/* Mount / Unmount (path-based or callback-based for Apple FSKit FSBlockDeviceResource) */
int cowfs_mount_path(cowfs_kind_t kind, const char *path, int read_only, cowfs_t **out_fs);
int cowfs_mount_io(
    cowfs_kind_t kind,
    uint64_t total_bytes,
    int read_only,
    void *io_ctx,
    cowfs_io_read_fn read_fn,
    cowfs_io_write_fn write_fn,
    cowfs_io_flush_fn flush_fn,
    cowfs_t **out_fs
);
void cowfs_unmount(cowfs_t *fs);
int cowfs_sync(cowfs_t *fs);

uint64_t cowfs_root_ino(const cowfs_t *fs);
int cowfs_statfs(cowfs_t *fs, uint64_t *total_bytes, uint64_t *free_bytes, uint32_t *block_size);
int cowfs_getattr(cowfs_t *fs, uint64_t ino, cowfs_item_attrs_t *out_attrs);
int cowfs_setattr(cowfs_t *fs, uint64_t ino, uint32_t mask, const cowfs_item_attrs_t *in_attrs);
int cowfs_lookup(cowfs_t *fs, uint64_t dir_ino, const char *name, uint64_t *out_ino);
int cowfs_lookup_path(cowfs_t *fs, const char *path, uint64_t *out_ino);
int cowfs_readdir(cowfs_t *fs, uint64_t dir_ino, uint64_t start_cookie, cowfs_dir_cb cb, void *user_ctx);
int cowfs_read(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, void *buffer, size_t *out_read);
int cowfs_write(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, const void *buffer, size_t *out_written);
int cowfs_create(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino);
int cowfs_mkdir(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino);
int cowfs_unlink(cowfs_t *fs, uint64_t dir_ino, const char *name);
int cowfs_rmdir(cowfs_t *fs, uint64_t dir_ino, const char *name);
int cowfs_rename(cowfs_t *fs, uint64_t old_dir_ino, const char *old_name, uint64_t new_dir_ino, const char *new_name);
int cowfs_symlink(cowfs_t *fs, uint64_t dir_ino, const char *name, const char *target, uint64_t *out_ino);
int cowfs_readlink(cowfs_t *fs, uint64_t ino, char *buffer, size_t buffer_cap, size_t *out_len);

/* LUKS1 / LUKS2 Encrypted Volume Support (AES-XTS-Plain64 + PBKDF2 + AF-Split) */
typedef struct {
    int      version;           /* 1 or 2 */
    uint64_t payload_offset;    /* byte offset where encrypted sectors start */
    uint64_t payload_bytes;     /* 0 if open-ended until end of partition */
    uint32_t sector_size;       /* 512 or 4096 */
    uint32_t key_bytes;         /* 32 (AES-128-XTS) or 64 (AES-256-XTS) */
    int      active_slots;
    char     cipher[32];
    char     cipher_mode[32];
    char     hash_spec[32];
    char     uuid[64];
    char     label[64];
} cowfs_luks_info_t;

typedef struct cowfs_luks_ctx cowfs_luks_t;

int cowfs_luks_probe(const char *path, cowfs_luks_info_t *out_info);
int cowfs_luks_format(
    const char *path,
    const char *passphrase,
    const char *label,
    uint64_t total_bytes_if_file
);
int cowfs_luks_unlock(
    const char *path,
    const char *passphrase,
    int read_only,
    cowfs_luks_t **out_ctx
);
void cowfs_luks_close(cowfs_luks_t *ctx);
uint64_t cowfs_luks_size(const cowfs_luks_t *ctx);
int cowfs_luks_pread(cowfs_luks_t *ctx, uint64_t offset, size_t length, void *buffer);
int cowfs_luks_pwrite(cowfs_luks_t *ctx, uint64_t offset, size_t length, const void *buffer);

/* LVM2 Physical Volume & Linear Logical Volume Mapper */
typedef struct {
    char     name[64];
    uint64_t size_bytes;
    uint64_t pv_byte_offset;
} cowfs_lvm_lv_t;

typedef struct {
    char           vg_name[64];
    char           pv_uuid[64];
    uint64_t       extent_bytes;
    uint32_t       lv_count;
    cowfs_lvm_lv_t lvs[16];
} cowfs_lvm_vg_info_t;

int cowfs_lvm_scan(const char *path, cowfs_lvm_vg_info_t *out_vg);

#ifdef __cplusplus
}
#endif

#endif /* MONTSERRAT_COWFS_BRIDGE_H */
