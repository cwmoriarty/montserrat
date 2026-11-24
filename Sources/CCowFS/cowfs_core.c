#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "cowfs_internal.h"
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __APPLE__
#include <sys/disk.h>
#endif

static uint32_t g_crc32c_table[256];
static pthread_once_t g_crc32c_once = PTHREAD_ONCE_INIT;

static void init_crc32c_table(void) {
    for (uint32_t i = 0; i < 256U; i++) {
        uint32_t crc = i;
        for (int b = 0; b < 8; b++) {
            crc = (crc & 1U) ? ((crc >> 1) ^ 0x82F63B78U) : (crc >> 1);
        }
        g_crc32c_table[i] = crc;
    }
}

uint32_t cowfs_crc32c(uint32_t crc, const void *buf, size_t len) {
    pthread_once(&g_crc32c_once, init_crc32c_table);
    const uint8_t *p = (const uint8_t *)buf;
    for (size_t i = 0; i < len; i++) {
        crc = g_crc32c_table[(crc ^ p[i]) & 0xFFU] ^ (crc >> 8);
    }
    return crc;
}

int cowfs_open_device_fd(const char *path, int read_only, int *out_fd, uint64_t *out_size, uint32_t *out_align) {
    int flags = read_only ? O_RDONLY : O_RDWR;
    int fd = open(path, flags);
    if (fd < 0) return -errno;

    struct stat st;
    if (fstat(fd, &st) != 0) {
        int err = -errno;
        close(fd);
        return err;
    }

    uint64_t sz = 0;
    uint32_t align = 1U;
    if (S_ISREG(st.st_mode)) {
        sz = (uint64_t)st.st_size;
    } else {
        align = 4096U;
#ifdef __APPLE__
        uint32_t bsz = 0;
        uint64_t bcnt = 0;
        if (ioctl(fd, DKIOCGETBLOCKSIZE, &bsz) == 0 && bsz >= 512U) {
            align = (bsz < 4096U) ? 4096U : bsz;
            if (ioctl(fd, DKIOCGETBLOCKCOUNT, &bcnt) == 0) {
                sz = bcnt * (uint64_t)bsz;
            }
        }
#endif
        if (sz == 0) {
            off_t end = lseek(fd, 0, SEEK_END);
            if (end > 0) sz = (uint64_t)end;
        }
    }

    *out_fd = fd;
    *out_size = sz;
    *out_align = align;
    return 0;
}

static int fd_io_read(void *io_ctx, uint64_t offset, size_t length, void *buffer) {
    const cowfs_fd_backend_t *b = (const cowfs_fd_backend_t *)io_ctx;
    if (length == 0) return 0;
    if (b->align <= 1U || ((offset % b->align) == 0 && (length % b->align) == 0)) {
        uint8_t *dst = (uint8_t *)buffer;
        size_t done = 0;
        while (done < length) {
            ssize_t r = pread(b->fd, dst + done, length - done, (off_t)(offset + done));
            if (r <= 0) return -EIO;
            done += (size_t)r;
        }
        return 0;
    }
    uint64_t a_start = (offset / b->align) * b->align;
    uint64_t a_end = ((offset + length + b->align - 1ULL) / b->align) * b->align;
    size_t a_len = (size_t)(a_end - a_start);
    uint8_t *tmp = (uint8_t *)malloc(a_len);
    if (!tmp) return -ENOMEM;
    size_t done = 0;
    while (done < a_len) {
        ssize_t r = pread(b->fd, tmp + done, a_len - done, (off_t)(a_start + done));
        if (r <= 0) {
            free(tmp);
            return -EIO;
        }
        done += (size_t)r;
    }
    memcpy(buffer, tmp + (size_t)(offset - a_start), length);
    free(tmp);
    return 0;
}

static int fd_io_write(void *io_ctx, uint64_t offset, size_t length, const void *buffer) {
    const cowfs_fd_backend_t *b = (const cowfs_fd_backend_t *)io_ctx;
    if (b->read_only) return -EROFS;
    if (length == 0) return 0;
    if (b->align <= 1U || ((offset % b->align) == 0 && (length % b->align) == 0)) {
        const uint8_t *src = (const uint8_t *)buffer;
        size_t done = 0;
        while (done < length) {
            ssize_t w = pwrite(b->fd, src + done, length - done, (off_t)(offset + done));
            if (w <= 0) return -EIO;
            done += (size_t)w;
        }
        return 0;
    }
    uint64_t a_start = (offset / b->align) * b->align;
    uint64_t a_end = ((offset + length + b->align - 1ULL) / b->align) * b->align;
    size_t a_len = (size_t)(a_end - a_start);
    uint8_t *tmp = (uint8_t *)malloc(a_len);
    if (!tmp) return -ENOMEM;
    if (fd_io_read(io_ctx, a_start, a_len, tmp) != 0) {
        free(tmp);
        return -EIO;
    }
    memcpy(tmp + (size_t)(offset - a_start), buffer, length);
    size_t done = 0;
    while (done < a_len) {
        ssize_t w = pwrite(b->fd, tmp + done, a_len - done, (off_t)(a_start + done));
        if (w <= 0) {
            free(tmp);
            return -EIO;
        }
        done += (size_t)w;
    }
    free(tmp);
    return 0;
}

static int fd_io_flush(void *io_ctx) {
    const cowfs_fd_backend_t *b = (const cowfs_fd_backend_t *)io_ctx;
    if (b->read_only) return 0;
#ifdef F_FULLFSYNC
    if (fcntl(b->fd, F_FULLFSYNC) == 0) return 0;
#endif
    return (fsync(b->fd) == 0) ? 0 : -errno;
}

int cowfs_io_read(const cowfs_t *fs, uint64_t off, size_t len, void *buf) {
    return fs->read_fn(fs->io_ctx, off, len, buf);
}

int cowfs_io_write(cowfs_t *fs, uint64_t off, size_t len, const void *buf) {
    if (fs->read_only || !fs->write_fn) return -EROFS;
    return fs->write_fn(fs->io_ctx, off, len, buf);
}

int cowfs_mkfs(cowfs_kind_t kind, const char *path, const char *label, uint32_t block_size) {
    if (!path) return -EINVAL;
    int fd = -1;
    uint64_t sz = 0;
    uint32_t align = 1U;
    int rc = cowfs_open_device_fd(path, 0, &fd, &sz, &align);
    if (rc != 0) return rc;
    if (sz < (4ULL << 20)) {
        close(fd);
        return -ENOSPC;
    }

    cowfs_fd_backend_t fb = { fd, 0, align, sz };
    cowfs_t tmp_fs;
    memset(&tmp_fs, 0, sizeof(tmp_fs));
    tmp_fs.kind = kind;
    tmp_fs.total_bytes = sz;
    tmp_fs.read_only = 0;
    tmp_fs.io_ctx = &fb;
    tmp_fs.read_fn = fd_io_read;
    tmp_fs.write_fn = fd_io_write;
    tmp_fs.flush_fn = fd_io_flush;

    /* Wipe first 256 KiB so prior filesystem signatures cannot linger */
    uint8_t *zeros = (uint8_t *)calloc(1, 262144U);
    if (zeros) {
        (void)fd_io_write(&fb, 0, 262144U, zeros);
        free(zeros);
    }

    if (kind == COWFS_KIND_XFS) {
        rc = cowfs_xfs_mkfs_impl(&tmp_fs, label ? label : "MontserratXFS", block_size ? block_size : 4096U);
    } else if (kind == COWFS_KIND_BTRFS) {
        rc = cowfs_btrfs_mkfs_impl(&tmp_fs, label ? label : "MontserratBtrfs", block_size ? block_size : 16384U);
    } else {
        rc = -EINVAL;
    }
    (void)fd_io_flush(&fb);
    close(fd);
    return rc;
}

int cowfs_fsck(cowfs_kind_t kind, const char *path, int auto_fix, char *report_buf, size_t report_cap) {
    if (!path) return -EINVAL;
    int fd = -1;
    uint64_t sz = 0;
    uint32_t align = 1U;
    int rc = cowfs_open_device_fd(path, auto_fix ? 0 : 1, &fd, &sz, &align);
    if (rc != 0) return rc;

    cowfs_fd_backend_t fb = { fd, auto_fix ? 0 : 1, align, sz };
    cowfs_t tmp_fs;
    memset(&tmp_fs, 0, sizeof(tmp_fs));
    tmp_fs.kind = kind;
    tmp_fs.total_bytes = sz;
    tmp_fs.read_only = auto_fix ? 0 : 1;
    tmp_fs.io_ctx = &fb;
    tmp_fs.read_fn = fd_io_read;
    tmp_fs.write_fn = auto_fix ? fd_io_write : NULL;
    tmp_fs.flush_fn = fd_io_flush;

    if (kind == COWFS_KIND_XFS) {
        rc = cowfs_xfs_fsck_impl(&tmp_fs, auto_fix, report_buf, report_cap);
    } else if (kind == COWFS_KIND_BTRFS) {
        rc = cowfs_btrfs_fsck_impl(&tmp_fs, auto_fix, report_buf, report_cap);
    } else {
        rc = -EINVAL;
    }
    if (auto_fix) (void)fd_io_flush(&fb);
    close(fd);
    return rc;
}

int cowfs_mount_io(
    cowfs_kind_t kind,
    uint64_t total_bytes,
    int read_only,
    void *io_ctx,
    cowfs_io_read_fn read_fn,
    cowfs_io_write_fn write_fn,
    cowfs_io_flush_fn flush_fn,
    cowfs_t **out_fs
) {
    if (!read_fn || !out_fs) return -EINVAL;
    *out_fs = NULL;

    cowfs_t *fs = (cowfs_t *)calloc(1, sizeof(cowfs_t));
    if (!fs) return -ENOMEM;
    pthread_mutex_init(&fs->lock, NULL);
    fs->kind = kind;
    fs->total_bytes = total_bytes;
    fs->read_only = read_only ? 1 : 0;
    fs->io_ctx = io_ctx;
    fs->read_fn = read_fn;
    fs->write_fn = read_only ? NULL : write_fn;
    fs->flush_fn = flush_fn;
    fs->ops = (kind == COWFS_KIND_XFS) ? &g_cowfs_xfs_ops : &g_cowfs_btrfs_ops;

    int rc = fs->ops->mount(fs);
    if (rc != 0) {
        pthread_mutex_destroy(&fs->lock);
        free(fs);
        return rc;
    }
    *out_fs = fs;
    return 0;
}

int cowfs_mount_path(cowfs_kind_t kind, const char *path, int read_only, cowfs_t **out_fs) {
    if (!path || !out_fs) return -EINVAL;
    int fd = -1;
    uint64_t sz = 0;
    uint32_t align = 1U;
    int rc = cowfs_open_device_fd(path, read_only, &fd, &sz, &align);
    if (rc != 0) return rc;

    cowfs_fd_backend_t *fb = (cowfs_fd_backend_t *)calloc(1, sizeof(cowfs_fd_backend_t));
    if (!fb) {
        close(fd);
        return -ENOMEM;
    }
    fb->fd = fd;
    fb->read_only = read_only ? 1 : 0;
    fb->align = align;
    fb->size = sz;

    cowfs_t *fs = NULL;
    rc = cowfs_mount_io(kind, sz, read_only, fb, fd_io_read, fd_io_write, fd_io_flush, &fs);
    if (rc != 0) {
        close(fd);
        free(fb);
        return rc;
    }
    fs->owned_fd_backend = fb;
    *out_fs = fs;
    return 0;
}

void cowfs_unmount(cowfs_t *fs) {
    if (!fs) return;
    pthread_mutex_lock(&fs->lock);
    if (!fs->read_only && fs->ops->sync) {
        (void)fs->ops->sync(fs);
    }
    if (fs->flush_fn) {
        (void)fs->flush_fn(fs->io_ctx);
    }
    if (fs->ops->unmount) {
        fs->ops->unmount(fs);
    }
    if (fs->owned_fd_backend) {
        close(fs->owned_fd_backend->fd);
        free(fs->owned_fd_backend);
        fs->owned_fd_backend = NULL;
    }
    pthread_mutex_unlock(&fs->lock);
    pthread_mutex_destroy(&fs->lock);
    free(fs);
}

int cowfs_sync(cowfs_t *fs) {
    if (!fs) return -EINVAL;
    pthread_mutex_lock(&fs->lock);
    int rc = (!fs->read_only && fs->ops->sync) ? fs->ops->sync(fs) : 0;
    if (rc == 0 && fs->flush_fn) rc = fs->flush_fn(fs->io_ctx);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

uint64_t cowfs_root_ino(const cowfs_t *fs) {
    return fs ? fs->ops->root_ino(fs) : 0ULL;
}

int cowfs_statfs(cowfs_t *fs, uint64_t *total_bytes, uint64_t *free_bytes, uint32_t *block_size) {
    if (!fs) return -EINVAL;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->statfs(fs, total_bytes, free_bytes, block_size);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_getattr(cowfs_t *fs, uint64_t ino, cowfs_item_attrs_t *out_attrs) {
    if (!fs || !out_attrs) return -EINVAL;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->getattr(fs, ino, out_attrs);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_setattr(cowfs_t *fs, uint64_t ino, uint32_t mask, const cowfs_item_attrs_t *in_attrs) {
    if (!fs || !in_attrs) return -EINVAL;
    if (fs->read_only) return -EROFS;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->setattr(fs, ino, mask, in_attrs);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_lookup(cowfs_t *fs, uint64_t dir_ino, const char *name, uint64_t *out_ino) {
    if (!fs || !name || !out_ino) return -EINVAL;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->lookup(fs, dir_ino, name, out_ino);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_lookup_path(cowfs_t *fs, const char *path, uint64_t *out_ino) {
    if (!fs || !path || !out_ino) return -EINVAL;
    pthread_mutex_lock(&fs->lock);
    uint64_t cur = fs->ops->root_ino(fs);
    const char *p = path;
    while (*p == '/') p++;
    int rc = 0;
    while (*p != '\0') {
        const char *slash = strchr(p, '/');
        size_t len = slash ? (size_t)(slash - p) : strlen(p);
        if (len > 255U) { rc = -ENAMETOOLONG; break; }
        char seg[256];
        memcpy(seg, p, len);
        seg[len] = '\0';
        if (strcmp(seg, ".") != 0) {
            uint64_t next = 0;
            rc = fs->ops->lookup(fs, cur, seg, &next);
            if (rc != 0) break;
            cur = next;
        }
        if (!slash) break;
        p = slash + 1;
        while (*p == '/') p++;
    }
    if (rc == 0) *out_ino = cur;
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_readdir(cowfs_t *fs, uint64_t dir_ino, uint64_t start_cookie, cowfs_dir_cb cb, void *user_ctx) {
    if (!fs || !cb) return -EINVAL;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->readdir(fs, dir_ino, start_cookie, cb, user_ctx);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_read(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, void *buffer, size_t *out_read) {
    if (!fs || (!buffer && length > 0) || !out_read) return -EINVAL;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->read(fs, ino, offset, length, buffer, out_read);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_write(cowfs_t *fs, uint64_t ino, uint64_t offset, size_t length, const void *buffer, size_t *out_written) {
    if (!fs || (!buffer && length > 0) || !out_written) return -EINVAL;
    if (fs->read_only) return -EROFS;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->write(fs, ino, offset, length, buffer, out_written);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_create(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino) {
    if (!fs || !name || !out_ino) return -EINVAL;
    if (fs->read_only) return -EROFS;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->create(fs, dir_ino, name, mode, out_ino);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_mkdir(cowfs_t *fs, uint64_t dir_ino, const char *name, uint32_t mode, uint64_t *out_ino) {
    if (!fs || !name || !out_ino) return -EINVAL;
    if (fs->read_only) return -EROFS;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->mkdir(fs, dir_ino, name, mode, out_ino);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_unlink(cowfs_t *fs, uint64_t dir_ino, const char *name) {
    if (!fs || !name) return -EINVAL;
    if (fs->read_only) return -EROFS;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->unlink(fs, dir_ino, name);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_rmdir(cowfs_t *fs, uint64_t dir_ino, const char *name) {
    if (!fs || !name) return -EINVAL;
    if (fs->read_only) return -EROFS;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->rmdir(fs, dir_ino, name);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_rename(cowfs_t *fs, uint64_t old_dir_ino, const char *old_name, uint64_t new_dir_ino, const char *new_name) {
    if (!fs || !old_name || !new_name) return -EINVAL;
    if (fs->read_only) return -EROFS;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->rename(fs, old_dir_ino, old_name, new_dir_ino, new_name);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_symlink(cowfs_t *fs, uint64_t dir_ino, const char *name, const char *target, uint64_t *out_ino) {
    if (!fs || !name || !target || !out_ino) return -EINVAL;
    if (fs->read_only) return -EROFS;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->symlink(fs, dir_ino, name, target, out_ino);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}

int cowfs_readlink(cowfs_t *fs, uint64_t ino, char *buffer, size_t buffer_cap, size_t *out_len) {
    if (!fs || !buffer || buffer_cap == 0) return -EINVAL;
    pthread_mutex_lock(&fs->lock);
    int rc = fs->ops->readlink(fs, ino, buffer, buffer_cap, out_len);
    pthread_mutex_unlock(&fs->lock);
    return rc;
}
