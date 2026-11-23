#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>

#include <ext2fs/ext2fs.h>
#include <ext2fs/ext2_io.h>
#include "ext2fs_bridge.h"

typedef struct {
    void *io_ctx;
    uint32_t phys_block_size;
    ext4_io_read_fn read_fn;
    ext4_io_write_fn write_fn;
    ext4_io_flush_fn flush_fn;
} ext4_io_backend_t;

struct ext4_context {
    ext2_filsys fs;
    int read_only;
    pthread_mutex_t lock;
    ext4_io_backend_t *io_backend;
};

static pthread_mutex_t g_pending_io_lock = PTHREAD_MUTEX_INITIALIZER;
static ext4_io_backend_t *g_pending_io_backend = NULL;
static struct struct_io_manager g_callback_io_manager;

static errcode_t cb_io_open(const char *name, int flags, io_channel *channel) {
    (void)flags;
    if (!channel || !g_pending_io_backend) {
        return EINVAL;
    }
    io_channel io = (io_channel)calloc(1, sizeof(struct struct_io_channel));
    if (!io) {
        return ENOMEM;
    }
    io->magic = EXT2_ET_MAGIC_IO_CHANNEL;
    io->manager = &g_callback_io_manager;
    io->name = strdup(name ? name : "fskit-resource");
    io->block_size = 1024;
    io->refcount = 1;
    io->private_data = g_pending_io_backend;
    *channel = io;
    return 0;
}

static errcode_t cb_io_close(io_channel channel) {
    if (!channel) return 0;
    if (--channel->refcount > 0) return 0;
    free(channel->name);
    free(channel);
    return 0;
}

static errcode_t cb_io_set_blksize(io_channel channel, int blksize) {
    if (!channel || blksize <= 0) return EINVAL;
    channel->block_size = blksize;
    return 0;
}

static errcode_t cb_io_rw_bytes(ext4_io_backend_t *backend, uint64_t offset, size_t bytes, void *data, int is_write) {
    if (!backend || (!is_write && !backend->read_fn) || (is_write && !backend->write_fn)) {
        return EIO;
    }
    if (bytes == 0) return 0;

    uint32_t pbs = backend->phys_block_size > 1 ? backend->phys_block_size : 1;
    if (pbs == 1 || ((offset % pbs) == 0 && (bytes % pbs) == 0)) {
        size_t done = 0;
        int rc = is_write
            ? backend->write_fn(backend->io_ctx, offset, bytes, data, &done)
            : backend->read_fn(backend->io_ctx, offset, bytes, data, &done);
        return (rc == 0 && done == bytes) ? 0 : EIO;
    }

    uint64_t aligned_start = (offset / pbs) * pbs;
    uint64_t end = offset + bytes;
    uint64_t aligned_end = ((end + pbs - 1) / pbs) * pbs;
    size_t aligned_len = (size_t)(aligned_end - aligned_start);
    uint8_t *bounce = (uint8_t *)malloc(aligned_len);
    if (!bounce) return ENOMEM;

    size_t got = 0;
    int rc = backend->read_fn(backend->io_ctx, aligned_start, aligned_len, bounce, &got);
    if (rc != 0 || got < (size_t)(end - aligned_start)) {
        free(bounce);
        return EIO;
    }

    size_t inner_off = (size_t)(offset - aligned_start);
    if (!is_write) {
        memcpy(data, bounce + inner_off, bytes);
    } else {
        memcpy(bounce + inner_off, data, bytes);
        size_t put = 0;
        rc = backend->write_fn(backend->io_ctx, aligned_start, aligned_len, bounce, &put);
        if (rc != 0 || put != aligned_len) {
            free(bounce);
            return EIO;
        }
    }
    free(bounce);
    return 0;
}

static errcode_t cb_io_read_blk64(io_channel channel, unsigned long long block, int count, void *data) {
    if (!channel || !channel->private_data || !data) return EINVAL;
    size_t bytes = (count < 0) ? (size_t)(-count) : (size_t)count * (size_t)channel->block_size;
    uint64_t offset = (uint64_t)block * (uint64_t)channel->block_size;
    return cb_io_rw_bytes((ext4_io_backend_t *)channel->private_data, offset, bytes, data, 0);
}

static errcode_t cb_io_write_blk64(io_channel channel, unsigned long long block, int count, const void *data) {
    if (!channel || !channel->private_data || !data) return EINVAL;
    size_t bytes = (count < 0) ? (size_t)(-count) : (size_t)count * (size_t)channel->block_size;
    uint64_t offset = (uint64_t)block * (uint64_t)channel->block_size;
    return cb_io_rw_bytes((ext4_io_backend_t *)channel->private_data, offset, bytes, (void *)data, 1);
}

static errcode_t cb_io_read_blk(io_channel channel, unsigned long block, int count, void *data) {
    return cb_io_read_blk64(channel, (unsigned long long)block, count, data);
}

static errcode_t cb_io_write_blk(io_channel channel, unsigned long block, int count, const void *data) {
    return cb_io_write_blk64(channel, (unsigned long long)block, count, data);
}

static errcode_t cb_io_flush(io_channel channel) {
    if (!channel || !channel->private_data) return 0;
    ext4_io_backend_t *backend = (ext4_io_backend_t *)channel->private_data;
    if (backend->flush_fn) {
        return backend->flush_fn(backend->io_ctx) == 0 ? 0 : EIO;
    }
    return 0;
}

static struct struct_io_manager g_callback_io_manager = {
    .magic = EXT2_ET_MAGIC_IO_MANAGER,
    .name = "Montserrat Callback I/O Manager",
    .open = cb_io_open,
    .close = cb_io_close,
    .set_blksize = cb_io_set_blksize,
    .read_blk = cb_io_read_blk,
    .write_blk = cb_io_write_blk,
    .flush = cb_io_flush,
    .read_blk64 = cb_io_read_blk64,
    .write_blk64 = cb_io_write_blk64
};

static int finish_mount_setup(ext4_context_t *ctx) {
    if (!ctx->read_only) {
        errcode_t bmerr = ext2fs_read_inode_bitmap(ctx->fs);
        if (!bmerr) {
            bmerr = ext2fs_read_block_bitmap(ctx->fs);
        }
        if (bmerr) {
            ctx->read_only = 1;
        }
    }
    return 0;
}

int ext4_bridge_mount(const char *device_path, int read_only, ext4_context_t **out_ctx) {
    if (!device_path || !out_ctx) {
        return -EINVAL;
    }

    ext4_context_t *ctx = (ext4_context_t *)calloc(1, sizeof(ext4_context_t));
    if (!ctx) {
        return -ENOMEM;
    }

    pthread_mutex_init(&ctx->lock, NULL);
    ctx->read_only = read_only;

    int flags = EXT2_FLAG_64BITS;
    if (!read_only) {
        flags |= EXT2_FLAG_RW;
    }

    errcode_t err = ext2fs_open2(device_path, NULL, flags, 0, 0, unix_io_manager, &ctx->fs);
    if ((err == EPERM || err == EACCES) && !read_only) {
        // Fallback to read-only mount
        flags &= ~EXT2_FLAG_RW;
        ctx->read_only = 1;
        err = ext2fs_open2(device_path, NULL, flags, 0, 0, unix_io_manager, &ctx->fs);
    }

    if (err) {
        pthread_mutex_destroy(&ctx->lock);
        free(ctx);
        return -EIO;
    }

    finish_mount_setup(ctx);
    *out_ctx = ctx;
    return 0;
}

int ext4_bridge_mount_io(
    const char *name,
    int read_only,
    uint32_t phys_block_size,
    void *io_ctx,
    ext4_io_read_fn read_fn,
    ext4_io_write_fn write_fn,
    ext4_io_flush_fn flush_fn,
    ext4_context_t **out_ctx
) {
    if (!out_ctx || !read_fn) {
        return -EINVAL;
    }

    ext4_io_backend_t *backend = (ext4_io_backend_t *)calloc(1, sizeof(ext4_io_backend_t));
    ext4_context_t *ctx = (ext4_context_t *)calloc(1, sizeof(ext4_context_t));
    if (!backend || !ctx) {
        free(backend);
        free(ctx);
        return -ENOMEM;
    }

    backend->io_ctx = io_ctx;
    backend->phys_block_size = phys_block_size > 0 ? phys_block_size : 1;
    backend->read_fn = read_fn;
    backend->write_fn = write_fn;
    backend->flush_fn = flush_fn;

    pthread_mutex_init(&ctx->lock, NULL);
    ctx->read_only = read_only || !write_fn;
    ctx->io_backend = backend;

    int flags = EXT2_FLAG_64BITS;
    if (!ctx->read_only) {
        flags |= EXT2_FLAG_RW;
    }

    pthread_mutex_lock(&g_pending_io_lock);
    g_pending_io_backend = backend;
    errcode_t err = ext2fs_open2(name ? name : "fskit-resource", NULL, flags, 0, 0, &g_callback_io_manager, &ctx->fs);
    g_pending_io_backend = NULL;
    pthread_mutex_unlock(&g_pending_io_lock);

    if (err) {
        pthread_mutex_destroy(&ctx->lock);
        free(backend);
        free(ctx);
        return -EIO;
    }

    finish_mount_setup(ctx);
    *out_ctx = ctx;
    return 0;
}

void ext4_bridge_unmount(ext4_context_t *ctx) {
    if (!ctx) return;

    pthread_mutex_lock(&ctx->lock);
    if (ctx->fs) {
        if (!ctx->read_only) {
            ext2fs_flush2(ctx->fs, 0);
        }
        ext2fs_close2(ctx->fs, 0);
        ctx->fs = NULL;
    }
    pthread_mutex_unlock(&ctx->lock);
    pthread_mutex_destroy(&ctx->lock);
    free(ctx->io_backend);
    free(ctx);
}

int ext4_bridge_sync(ext4_context_t *ctx) {
    if (!ctx || !ctx->fs) return -EINVAL;
    if (ctx->read_only) return 0;

    pthread_mutex_lock(&ctx->lock);
    errcode_t err = ext2fs_flush2(ctx->fs, 0);
    pthread_mutex_unlock(&ctx->lock);

    return err ? -EIO : 0;
}

int ext4_bridge_statfs(ext4_context_t *ctx, uint64_t *total_bytes, uint64_t *free_bytes, uint32_t *block_size) {
    if (!ctx || !ctx->fs) return -EINVAL;

    pthread_mutex_lock(&ctx->lock);
    uint32_t bsize = ctx->fs->blocksize;
    uint64_t total_blocks = ext2fs_blocks_count(ctx->fs->super);
    uint64_t free_blocks = ext2fs_free_blocks_count(ctx->fs->super);
    pthread_mutex_unlock(&ctx->lock);

    if (total_bytes) *total_bytes = total_blocks * (uint64_t)bsize;
    if (free_bytes) *free_bytes = free_blocks * (uint64_t)bsize;
    if (block_size) *block_size = bsize;

    return 0;
}

int ext4_bridge_lookup(ext4_context_t *ctx, uint64_t parent_ino, const char *name, uint64_t *out_ino) {
    if (!ctx || !ctx->fs || !name || !out_ino) return -EINVAL;

    pthread_mutex_lock(&ctx->lock);
    ext2_ino_t ino = 0;
    errcode_t err = ext2fs_lookup(ctx->fs, (ext2_ino_t)parent_ino, name, (int)strlen(name), NULL, &ino);
    pthread_mutex_unlock(&ctx->lock);

    if (err == EXT2_ET_FILE_NOT_FOUND) {
        return -ENOENT;
    }
    if (err) {
        return -EIO;
    }

    *out_ino = (uint64_t)ino;
    return 0;
}

int ext4_bridge_get_attrs(ext4_context_t *ctx, uint64_t ino, ext4_item_attrs_t *out_attrs) {
    if (!ctx || !ctx->fs || !out_attrs) return -EINVAL;

    pthread_mutex_lock(&ctx->lock);
    struct ext2_inode_large inode;
    memset(&inode, 0, sizeof(inode));
    errcode_t err = ext2fs_read_inode_full(ctx->fs, (ext2_ino_t)ino, (struct ext2_inode *)&inode, sizeof(inode));
    pthread_mutex_unlock(&ctx->lock);

    if (err) {
        return -ENOENT;
    }

    memset(out_attrs, 0, sizeof(ext4_item_attrs_t));
    out_attrs->ino = ino;
    out_attrs->mode = inode.i_mode;
    out_attrs->link_count = inode.i_links_count;
    out_attrs->uid = inode.i_uid | ((uint32_t)inode.osd2.linux2.l_i_uid_high << 16);
    out_attrs->gid = inode.i_gid | ((uint32_t)inode.osd2.linux2.l_i_gid_high << 16);

    uint64_t size = inode.i_size;
    if (LINUX_S_ISREG(inode.i_mode) && (ctx->fs->super->s_feature_ro_compat & EXT4_FEATURE_RO_COMPAT_HUGE_FILE)) {
        size |= ((uint64_t)inode.i_size_high << 32);
    }
    out_attrs->size = size;
    out_attrs->alloc_size = (uint64_t)inode.i_blocks * 512;
    out_attrs->flags = inode.i_flags;

    out_attrs->atime_sec = inode.i_atime;
    out_attrs->mtime_sec = inode.i_mtime;
    out_attrs->ctime_sec = inode.i_ctime;
    out_attrs->btime_sec = inode.i_ctime; // fallback birth time

    if (inode.i_extra_isize >= 32) {
        out_attrs->btime_sec = inode.i_crtime;
        out_attrs->btime_nsec = inode.i_crtime_extra >> 2;
    }

    if (LINUX_S_ISDIR(inode.i_mode)) {
        out_attrs->file_type = 2; // Directory
    } else if (LINUX_S_ISREG(inode.i_mode)) {
        out_attrs->file_type = 1; // Regular file
    } else if (LINUX_S_ISLNK(inode.i_mode)) {
        out_attrs->file_type = 3; // Symlink
    } else {
        out_attrs->file_type = 0; // Other
    }

    return 0;
}

int ext4_bridge_set_attrs(ext4_context_t *ctx, uint64_t ino, uint32_t mask, const ext4_item_attrs_t *in_attrs) {
    if (!ctx || !ctx->fs || !in_attrs) return -EINVAL;
    if (ctx->read_only) return -EROFS;

    pthread_mutex_lock(&ctx->lock);
    struct ext2_inode inode;
    memset(&inode, 0, sizeof(inode));
    errcode_t err = ext2fs_read_inode(ctx->fs, (ext2_ino_t)ino, &inode);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -ENOENT;
    }

    if (mask & 0x01) { // mode
        inode.i_mode = (inode.i_mode & ~07777) | (in_attrs->mode & 07777);
    }
    if (mask & 0x02) { // uid
        inode.i_uid = (uint16_t)(in_attrs->uid & 0xFFFF);
        inode.osd2.linux2.l_i_uid_high = (uint16_t)((in_attrs->uid >> 16) & 0xFFFF);
    }
    if (mask & 0x04) { // gid
        inode.i_gid = (uint16_t)(in_attrs->gid & 0xFFFF);
        inode.osd2.linux2.l_i_gid_high = (uint16_t)((in_attrs->gid >> 16) & 0xFFFF);
    }
    if (mask & 0x08) { // mtime
        inode.i_mtime = (uint32_t)in_attrs->mtime_sec;
    }
    if (mask & 0x10) { // atime
        inode.i_atime = (uint32_t)in_attrs->atime_sec;
    }
    inode.i_ctime = (uint32_t)time(NULL);

    err = ext2fs_write_inode(ctx->fs, (ext2_ino_t)ino, &inode);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    if (mask & 0x20) { // size / truncate
        ext2_file_t file;
        if (ext2fs_file_open(ctx->fs, (ext2_ino_t)ino, EXT2_FILE_WRITE, &file) == 0) {
            ext2fs_file_set_size2(file, (ext2_off64_t)in_attrs->size);
            ext2fs_file_close(file);
        }
    }

    ext2fs_flush2(ctx->fs, 0);
    pthread_mutex_unlock(&ctx->lock);
    return 0;
}

struct readdir_context {
    ext4_dir_packer_fn packer;
    void *user_ctx;
    uint64_t count;
    uint64_t start_cookie;
};

static int readdir_iterator(ext2_ino_t dir, int entry, struct ext2_dir_entry *dirent,
                            int offset, int blocksize, char *buf, void *data) {
    struct readdir_context *rctx = (struct readdir_context *)data;
    if (!dirent || dirent->inode == 0) return 0;

    rctx->count++;
    if (rctx->count <= rctx->start_cookie) {
        return 0;
    }

    char name[EXT2_NAME_LEN + 1];
    int len = ext2fs_dirent_name_len(dirent);
    memcpy(name, dirent->name, len);
    name[len] = '\0';

    uint8_t file_type = 0;
    switch (ext2fs_dirent_file_type(dirent) & 0x07) {
        case EXT2_FT_REG_FILE: file_type = 1; break;
        case EXT2_FT_DIR:      file_type = 2; break;
        case EXT2_FT_SYMLINK:  file_type = 3; break;
        default:               file_type = 0; break;
    }

    int keep_going = rctx->packer(rctx->user_ctx, name, (uint64_t)dirent->inode, file_type, rctx->count);
    if (!keep_going) {
        return DIRENT_ABORT;
    }
    return 0;
}

int ext4_bridge_readdir(ext4_context_t *ctx, uint64_t dir_ino, uint64_t start_cookie, ext4_dir_packer_fn packer, void *user_ctx) {
    if (!ctx || !ctx->fs || !packer) return -EINVAL;

    struct readdir_context rctx;
    rctx.packer = packer;
    rctx.user_ctx = user_ctx;
    rctx.count = 0;
    rctx.start_cookie = start_cookie;

    pthread_mutex_lock(&ctx->lock);
    errcode_t err = ext2fs_dir_iterate2(ctx->fs, (ext2_ino_t)dir_ino, 0, NULL, readdir_iterator, &rctx);
    pthread_mutex_unlock(&ctx->lock);

    return (err && err != DIRENT_ABORT) ? -EIO : 0;
}

int ext4_bridge_read(ext4_context_t *ctx, uint64_t ino, uint64_t offset, size_t length, void *buffer, size_t *actually_read) {
    if (!ctx || !ctx->fs || !buffer) return -EINVAL;

    pthread_mutex_lock(&ctx->lock);
    ext2_file_t file;
    errcode_t err = ext2fs_file_open(ctx->fs, (ext2_ino_t)ino, 0, &file);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    err = ext2fs_file_llseek(file, offset, SEEK_SET, NULL);
    if (err) {
        ext2fs_file_close(file);
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    unsigned int got = 0;
    err = ext2fs_file_read(file, buffer, (unsigned int)length, &got);
    ext2fs_file_close(file);
    pthread_mutex_unlock(&ctx->lock);

    if (actually_read) {
        *actually_read = got;
    }
    return err ? -EIO : 0;
}

int ext4_bridge_write(ext4_context_t *ctx, uint64_t ino, uint64_t offset, size_t length, const void *buffer, size_t *actually_written) {
    if (!ctx || !ctx->fs || !buffer) return -EINVAL;
    if (ctx->read_only) return -EROFS;

    pthread_mutex_lock(&ctx->lock);
    ext2_file_t file;
    errcode_t err = ext2fs_file_open(ctx->fs, (ext2_ino_t)ino, EXT2_FILE_WRITE, &file);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    err = ext2fs_file_llseek(file, offset, SEEK_SET, NULL);
    if (err) {
        ext2fs_file_close(file);
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    unsigned int written = 0;
    err = ext2fs_file_write(file, buffer, (unsigned int)length, &written);
    if (!err && written > 0) {
        __u64 cur_size = 0;
        if (ext2fs_file_get_lsize(file, &cur_size) == 0) {
            __u64 end_pos = (__u64)(offset + written);
            if (end_pos > cur_size) {
                ext2fs_file_set_size2(file, (ext2_off64_t)end_pos);
            }
        }
    }
    ext2fs_file_close(file);

    if (!err && written > 0) {
        ext2fs_flush2(ctx->fs, 0);
    }
    pthread_mutex_unlock(&ctx->lock);

    if (actually_written) {
        *actually_written = written;
    }
    return err ? -EIO : 0;
}

int ext4_bridge_readlink(ext4_context_t *ctx, uint64_t ino, char *buf, size_t buflen, size_t *out_len) {
    if (!ctx || !ctx->fs || !buf || buflen == 0) return -EINVAL;

    pthread_mutex_lock(&ctx->lock);
    struct ext2_inode inode;
    errcode_t err = ext2fs_read_inode(ctx->fs, (ext2_ino_t)ino, &inode);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -ENOENT;
    }

    if (!LINUX_S_ISLNK(inode.i_mode)) {
        pthread_mutex_unlock(&ctx->lock);
        return -EINVAL;
    }

    size_t len = inode.i_size;
    if (len >= buflen) len = buflen - 1;

    if (ext2fs_inode_data_blocks2(ctx->fs, &inode) == 0) {
        // Fast symlink: target is directly in i_block
        memcpy(buf, (char *)inode.i_block, len);
        buf[len] = '\0';
        pthread_mutex_unlock(&ctx->lock);
        if (out_len) *out_len = len;
        return 0;
    }

    // Slow symlink: read block
    ext2_file_t file;
    err = ext2fs_file_open(ctx->fs, (ext2_ino_t)ino, 0, &file);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    unsigned int got = 0;
    err = ext2fs_file_read(file, buf, (unsigned int)len, &got);
    ext2fs_file_close(file);
    pthread_mutex_unlock(&ctx->lock);

    buf[got] = '\0';
    if (out_len) *out_len = got;
    return err ? -EIO : 0;
}

static int dir_empty_check_cb(ext2_ino_t dir, int entry, struct ext2_dir_entry *dirent,
                                int offset, int blocksize, char *buf, void *data) {
    (void)dir; (void)entry; (void)offset; (void)blocksize; (void)buf;
    if (!dirent || dirent->inode == 0) return 0;
    int len = ext2fs_dirent_name_len(dirent);
    if (len == 1 && dirent->name[0] == '.') return 0;
    if (len == 2 && dirent->name[0] == '.' && dirent->name[1] == '.') return 0;
    int *has_entries = (int *)data;
    *has_entries = 1;
    return DIRENT_ABORT;
}

static int is_dir_empty_locked(ext2_filsys fs, ext2_ino_t dir_ino) {
    int has_entries = 0;
    errcode_t err = ext2fs_dir_iterate2(fs, dir_ino, 0, NULL, dir_empty_check_cb, &has_entries);
    if (err && err != DIRENT_ABORT) return -1;
    return has_entries ? 0 : 1;
}

static int file_type_for_mode(uint16_t mode) {
    if (LINUX_S_ISDIR(mode)) return EXT2_FT_DIR;
    if (LINUX_S_ISLNK(mode)) return EXT2_FT_SYMLINK;
    return EXT2_FT_REG_FILE;
}

static void decrement_inode_links_locked(ext2_filsys fs, ext2_ino_t target_ino, int force_zero_dir) {
    struct ext2_inode inode;
    if (ext2fs_read_inode(fs, target_ino, &inode)) return;
    int is_dir = LINUX_S_ISDIR(inode.i_mode);
    if (force_zero_dir && is_dir) {
        inode.i_links_count = 0;
    } else if (inode.i_links_count > 0) {
        inode.i_links_count--;
    }
    inode.i_dtime = (inode.i_links_count == 0) ? (uint32_t)time(NULL) : 0;
    if (inode.i_links_count == 0 && !(is_dir == 0 && LINUX_S_ISLNK(inode.i_mode) && ext2fs_inode_data_blocks2(fs, &inode) == 0)) {
        (void)ext2fs_punch(fs, target_ino, &inode, NULL, 0, ~0ULL);
        inode.i_size = 0;
    }
    ext2fs_write_inode(fs, target_ino, &inode);
    if (inode.i_links_count == 0) {
        ext2fs_inode_alloc_stats2(fs, target_ino, -1, is_dir);
    }
}

int ext4_bridge_symlink(ext4_context_t *ctx, uint64_t parent_ino, const char *name, const char *target, uint64_t *out_ino) {
    if (!ctx || !ctx->fs || !name || !target || !out_ino) return -EINVAL;
    if (ctx->read_only) return -EROFS;

    pthread_mutex_lock(&ctx->lock);
    errcode_t err = ext2fs_symlink(ctx->fs, (ext2_ino_t)parent_ino, 0, name, target);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return (err == EXT2_ET_INVALID_ARGUMENT) ? -ENAMETOOLONG : -EIO;
    }

    ext2_ino_t new_ino = 0;
    err = ext2fs_lookup(ctx->fs, (ext2_ino_t)parent_ino, name, (int)strlen(name), NULL, &new_ino);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    ext2fs_flush2(ctx->fs, 0);
    pthread_mutex_unlock(&ctx->lock);

    *out_ino = (uint64_t)new_ino;
    return 0;
}

int ext4_bridge_link(ext4_context_t *ctx, uint64_t target_ino, uint64_t parent_ino, const char *name) {
    if (!ctx || !ctx->fs || !name) return -EINVAL;
    if (ctx->read_only) return -EROFS;

    pthread_mutex_lock(&ctx->lock);
    struct ext2_inode inode;
    errcode_t err = ext2fs_read_inode(ctx->fs, (ext2_ino_t)target_ino, &inode);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -ENOENT;
    }
    if (LINUX_S_ISDIR(inode.i_mode)) {
        pthread_mutex_unlock(&ctx->lock);
        return -EPERM;
    }

    ext2_ino_t existing = 0;
    if (ext2fs_lookup(ctx->fs, (ext2_ino_t)parent_ino, name, (int)strlen(name), NULL, &existing) == 0) {
        pthread_mutex_unlock(&ctx->lock);
        return -EEXIST;
    }

    int ft = file_type_for_mode(inode.i_mode);
    err = ext2fs_link(ctx->fs, (ext2_ino_t)parent_ino, name, (ext2_ino_t)target_ino, EXT2FS_LINK_EXPAND | ft);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    inode.i_links_count++;
    inode.i_ctime = (uint32_t)time(NULL);
    ext2fs_write_inode(ctx->fs, (ext2_ino_t)target_ino, &inode);
    ext2fs_flush2(ctx->fs, 0);
    pthread_mutex_unlock(&ctx->lock);
    return 0;
}

int ext4_bridge_rename(ext4_context_t *ctx, uint64_t old_parent_ino, const char *old_name, uint64_t new_parent_ino, const char *new_name) {
    if (!ctx || !ctx->fs || !old_name || !new_name) return -EINVAL;
    if (ctx->read_only) return -EROFS;

    pthread_mutex_lock(&ctx->lock);
    ext2_ino_t src_ino = 0;
    errcode_t err = ext2fs_lookup(ctx->fs, (ext2_ino_t)old_parent_ino, old_name, (int)strlen(old_name), NULL, &src_ino);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -ENOENT;
    }

    if (old_parent_ino == new_parent_ino && strcmp(old_name, new_name) == 0) {
        pthread_mutex_unlock(&ctx->lock);
        return 0;
    }

    struct ext2_inode src_inode;
    if (ext2fs_read_inode(ctx->fs, src_ino, &src_inode)) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }
    int src_is_dir = LINUX_S_ISDIR(src_inode.i_mode);

    ext2_ino_t dst_ino = 0;
    if (ext2fs_lookup(ctx->fs, (ext2_ino_t)new_parent_ino, new_name, (int)strlen(new_name), NULL, &dst_ino) == 0) {
        if (dst_ino == src_ino) {
            pthread_mutex_unlock(&ctx->lock);
            return 0;
        }
        struct ext2_inode dst_inode;
        if (ext2fs_read_inode(ctx->fs, dst_ino, &dst_inode)) {
            pthread_mutex_unlock(&ctx->lock);
            return -EIO;
        }
        int dst_is_dir = LINUX_S_ISDIR(dst_inode.i_mode);
        if (src_is_dir && !dst_is_dir) {
            pthread_mutex_unlock(&ctx->lock);
            return -ENOTDIR;
        }
        if (!src_is_dir && dst_is_dir) {
            pthread_mutex_unlock(&ctx->lock);
            return -EISDIR;
        }
        if (dst_is_dir && is_dir_empty_locked(ctx->fs, dst_ino) != 1) {
            pthread_mutex_unlock(&ctx->lock);
            return -ENOTEMPTY;
        }

        if (ext2fs_unlink(ctx->fs, (ext2_ino_t)new_parent_ino, new_name, dst_ino, 0)) {
            pthread_mutex_unlock(&ctx->lock);
            return -EIO;
        }
        decrement_inode_links_locked(ctx->fs, dst_ino, 1);
        if (dst_is_dir) {
            struct ext2_inode np_inode;
            if (!ext2fs_read_inode(ctx->fs, (ext2_ino_t)new_parent_ino, &np_inode) && np_inode.i_links_count > 0) {
                np_inode.i_links_count--;
                ext2fs_write_inode(ctx->fs, (ext2_ino_t)new_parent_ino, &np_inode);
            }
        }
    }

    int ft = file_type_for_mode(src_inode.i_mode);
    if (ext2fs_link(ctx->fs, (ext2_ino_t)new_parent_ino, new_name, src_ino, EXT2FS_LINK_EXPAND | ft)) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    if (ext2fs_unlink(ctx->fs, (ext2_ino_t)old_parent_ino, old_name, src_ino, 0)) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    if (src_is_dir && old_parent_ino != new_parent_ino) {
        (void)ext2fs_unlink(ctx->fs, src_ino, "..", 0, EXT2FS_UNLINK_FORCE);
        (void)ext2fs_link(ctx->fs, src_ino, "..", (ext2_ino_t)new_parent_ino, EXT2FS_LINK_EXPAND | EXT2_FT_DIR);

        struct ext2_inode p_inode;
        if (!ext2fs_read_inode(ctx->fs, (ext2_ino_t)old_parent_ino, &p_inode) && p_inode.i_links_count > 0) {
            p_inode.i_links_count--;
            ext2fs_write_inode(ctx->fs, (ext2_ino_t)old_parent_ino, &p_inode);
        }
        if (!ext2fs_read_inode(ctx->fs, (ext2_ino_t)new_parent_ino, &p_inode)) {
            p_inode.i_links_count++;
            ext2fs_write_inode(ctx->fs, (ext2_ino_t)new_parent_ino, &p_inode);
        }
    }

    ext2fs_flush2(ctx->fs, 0);
    pthread_mutex_unlock(&ctx->lock);
    return 0;
}

int ext4_bridge_create(ext4_context_t *ctx, uint64_t parent_ino, const char *name, uint32_t mode, uint64_t *out_ino) {
    if (!ctx || !ctx->fs || !name || !out_ino) return -EINVAL;
    if (ctx->read_only) return -EROFS;

    pthread_mutex_lock(&ctx->lock);
    ext2_ino_t new_ino = 0;
    errcode_t err = ext2fs_new_inode(ctx->fs, (ext2_ino_t)parent_ino, LINUX_S_IFREG | mode, NULL, &new_ino);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -ENOSPC;
    }

    struct ext2_inode inode;
    memset(&inode, 0, sizeof(inode));
    inode.i_mode = LINUX_S_IFREG | (mode & 07777);
    inode.i_links_count = 1;
    inode.i_atime = inode.i_ctime = inode.i_mtime = (uint32_t)time(NULL);

    err = ext2fs_write_new_inode(ctx->fs, new_ino, &inode);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    ext2fs_inode_alloc_stats2(ctx->fs, new_ino, +1, 0);

    err = ext2fs_link(ctx->fs, (ext2_ino_t)parent_ino, name, new_ino, EXT2FS_LINK_EXPAND | EXT2_FT_REG_FILE);
    if (err) {
        ext2fs_inode_alloc_stats2(ctx->fs, new_ino, -1, 0);
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    ext2fs_flush2(ctx->fs, 0);
    pthread_mutex_unlock(&ctx->lock);

    *out_ino = (uint64_t)new_ino;
    return 0;
}

int ext4_bridge_mkdir(ext4_context_t *ctx, uint64_t parent_ino, const char *name, uint32_t mode, uint64_t *out_ino) {
    if (!ctx || !ctx->fs || !name || !out_ino) return -EINVAL;
    if (ctx->read_only) return -EROFS;

    pthread_mutex_lock(&ctx->lock);
    ext2_ino_t new_ino = 0;
    errcode_t err = ext2fs_mkdir(ctx->fs, (ext2_ino_t)parent_ino, 0, name);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    err = ext2fs_lookup(ctx->fs, (ext2_ino_t)parent_ino, name, (int)strlen(name), NULL, &new_ino);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    (void)mode;
    ext2fs_flush2(ctx->fs, 0);
    pthread_mutex_unlock(&ctx->lock);

    *out_ino = (uint64_t)new_ino;
    return 0;
}

int ext4_bridge_unlink(ext4_context_t *ctx, uint64_t parent_ino, const char *name) {
    if (!ctx || !ctx->fs || !name) return -EINVAL;
    if (ctx->read_only) return -EROFS;

    pthread_mutex_lock(&ctx->lock);
    ext2_ino_t target_ino = 0;
    errcode_t err = ext2fs_lookup(ctx->fs, (ext2_ino_t)parent_ino, name, (int)strlen(name), NULL, &target_ino);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -ENOENT;
    }

    struct ext2_inode target_inode;
    int is_dir = 0;
    if (!ext2fs_read_inode(ctx->fs, target_ino, &target_inode) && LINUX_S_ISDIR(target_inode.i_mode)) {
        is_dir = 1;
        if (is_dir_empty_locked(ctx->fs, target_ino) != 1) {
            pthread_mutex_unlock(&ctx->lock);
            return -ENOTEMPTY;
        }
    }

    err = ext2fs_unlink(ctx->fs, (ext2_ino_t)parent_ino, name, target_ino, 0);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    decrement_inode_links_locked(ctx->fs, target_ino, 1);
    if (is_dir) {
        struct ext2_inode p_inode;
        if (!ext2fs_read_inode(ctx->fs, (ext2_ino_t)parent_ino, &p_inode) && p_inode.i_links_count > 0) {
            p_inode.i_links_count--;
            ext2fs_write_inode(ctx->fs, (ext2_ino_t)parent_ino, &p_inode);
        }
    }

    ext2fs_flush2(ctx->fs, 0);
    pthread_mutex_unlock(&ctx->lock);
    return 0;
}
