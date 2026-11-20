#ifndef EXT2FS_BRIDGE_H
#define EXT2FS_BRIDGE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ext4_context ext4_context_t;

typedef struct {
    uint64_t ino;
    uint32_t mode;
    uint32_t uid;
    uint32_t gid;
    uint64_t size;
    uint64_t alloc_size;
    uint32_t link_count;
    uint32_t flags;
    uint64_t atime_sec;
    uint32_t atime_nsec;
    uint64_t mtime_sec;
    uint32_t mtime_nsec;
    uint64_t ctime_sec;
    uint32_t ctime_nsec;
    uint64_t btime_sec;
    uint32_t btime_nsec;
    uint8_t  file_type; // 1 = regular, 2 = dir, 3 = symlink, 0 = other
} ext4_item_attrs_t;

typedef int (*ext4_dir_packer_fn)(void *user_ctx, const char *name, uint64_t ino, uint8_t file_type, uint64_t next_cookie);

int ext4_bridge_mount(const char *device_path, int read_only, ext4_context_t **out_ctx);
void ext4_bridge_unmount(ext4_context_t *ctx);
int ext4_bridge_sync(ext4_context_t *ctx);
int ext4_bridge_statfs(ext4_context_t *ctx, uint64_t *total_bytes, uint64_t *free_bytes, uint32_t *block_size);
int ext4_bridge_lookup(ext4_context_t *ctx, uint64_t parent_ino, const char *name, uint64_t *out_ino);
int ext4_bridge_get_attrs(ext4_context_t *ctx, uint64_t ino, ext4_item_attrs_t *out_attrs);
int ext4_bridge_readdir(ext4_context_t *ctx, uint64_t dir_ino, uint64_t start_cookie, ext4_dir_packer_fn packer, void *user_ctx);
int ext4_bridge_read(ext4_context_t *ctx, uint64_t ino, uint64_t offset, size_t length, void *buffer, size_t *actually_read);
int ext4_bridge_write(ext4_context_t *ctx, uint64_t ino, uint64_t offset, size_t length, const void *buffer, size_t *actually_written);
int ext4_bridge_readlink(ext4_context_t *ctx, uint64_t ino, char *buf, size_t buflen, size_t *out_len);
int ext4_bridge_create(ext4_context_t *ctx, uint64_t parent_ino, const char *name, uint32_t mode, uint64_t *out_ino);
int ext4_bridge_mkdir(ext4_context_t *ctx, uint64_t parent_ino, const char *name, uint32_t mode, uint64_t *out_ino);
int ext4_bridge_unlink(ext4_context_t *ctx, uint64_t parent_ino, const char *name);

#ifdef __cplusplus
}
#endif

#endif /* EXT2FS_BRIDGE_H */
