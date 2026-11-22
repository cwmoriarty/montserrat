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

struct ext4_context {
    ext2_filsys fs;
    int read_only;
    pthread_mutex_t lock;
};

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

    if (!ctx->read_only) {
        errcode_t bmerr = ext2fs_read_inode_bitmap(ctx->fs);
        if (!bmerr) {
            bmerr = ext2fs_read_block_bitmap(ctx->fs);
        }
        if (bmerr) {
            // Bitmap reading failed, demote to read-only
            ctx->read_only = 1;
        }
    }

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

    err = ext2fs_link(ctx->fs, (ext2_ino_t)parent_ino, name, new_ino, EXT2_FT_REG_FILE);
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

    err = ext2fs_unlink(ctx->fs, (ext2_ino_t)parent_ino, name, target_ino, 0);
    if (err) {
        pthread_mutex_unlock(&ctx->lock);
        return -EIO;
    }

    struct ext2_inode inode;
    if (!ext2fs_read_inode(ctx->fs, target_ino, &inode)) {
        if (inode.i_links_count > 0) {
            inode.i_links_count--;
            inode.i_dtime = (inode.i_links_count == 0) ? (uint32_t)time(NULL) : 0;
            ext2fs_write_inode(ctx->fs, target_ino, &inode);
            if (inode.i_links_count == 0) {
                ext2fs_inode_alloc_stats2(ctx->fs, target_ino, -1, LINUX_S_ISDIR(inode.i_mode));
            }
        }
    }

    ext2fs_flush2(ctx->fs, 0);
    pthread_mutex_unlock(&ctx->lock);
    return 0;
}
