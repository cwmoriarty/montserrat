#define FUSE_USE_VERSION 31
#include <fuse3/fuse.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>

struct xfs_context {
    char *device;
    int dev_fd;
    char label[13];
    char uuid_str[37];
    uint64_t total_blocks;
    uint32_t blocksize;
    int read_only;
};

static struct xfs_context g_xfs_ctx;

static void sigpipe_handler(int sig) {
    (void)sig;
}

static int xfs_opt_proc(void *data, const char *arg, int key, struct fuse_args *outargs) {
    struct xfs_context *ctx = (struct xfs_context *)data;
    if (key == FUSE_OPT_KEY_NONOPT) {
        if (!ctx->device) {
            ctx->device = strdup(arg);
            return 0;
        }
    }
    return 1;
}

static int xfs_read_superblock(struct xfs_context *ctx) {
    int fd = open(ctx->device, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "xfs-fuse: failed to open device %s: %s\n", ctx->device, strerror(errno));
        return -errno;
    }
    ctx->dev_fd = fd;

    unsigned char buf[512];
    if (pread(fd, buf, sizeof(buf), 0) != sizeof(buf)) {
        fprintf(stderr, "xfs-fuse: failed to read superblock at offset 0\n");
        return -EIO;
    }

    // Magic at offset 0: "XFSB" (0x58465342)
    if (memcmp(buf, "XFSB", 4) != 0) {
        fprintf(stderr, "xfs-fuse: invalid XFS magic at offset 0\n");
        return -EINVAL;
    }

    // Block size at offset 4 (big endian uint32)
    uint32_t bsize = ((uint32_t)buf[4] << 24) | ((uint32_t)buf[5] << 16) |
                     ((uint32_t)buf[6] << 8) | (uint32_t)buf[7];
    ctx->blocksize = bsize > 0 ? bsize : 4096;

    // Total data blocks at offset 8 (big endian uint64)
    uint64_t dblocks = 0;
    for (int i = 0; i < 8; i++) {
        dblocks = (dblocks << 8) | buf[8 + i];
    }
    ctx->total_blocks = dblocks;

    // UUID: 16 bytes at offset 32
    snprintf(ctx->uuid_str, sizeof(ctx->uuid_str),
             "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             buf[32], buf[33], buf[34], buf[35],
             buf[36], buf[37], buf[38], buf[39],
             buf[40], buf[41], buf[42], buf[43],
             buf[44], buf[45], buf[46], buf[47]);

    // Label at offset 108 (12 bytes)
    memcpy(ctx->label, buf + 108, 12);
    ctx->label[12] = '\0';

    return 0;
}

static int xfs_getattr(const char *path, struct stat *stbuf, struct fuse_file_info *fi) {
    (void)fi;
    memset(stbuf, 0, sizeof(struct stat));

    if (strcmp(path, "/") == 0) {
        stbuf->st_mode = S_IFDIR | 0755;
        stbuf->st_nlink = 2;
        stbuf->st_uid = getuid();
        stbuf->st_gid = getgid();
        return 0;
    }

    if (strcmp(path, "/.xfs_info") == 0) {
        stbuf->st_mode = S_IFREG | 0444;
        stbuf->st_nlink = 1;
        stbuf->st_size = 256;
        stbuf->st_uid = getuid();
        stbuf->st_gid = getgid();
        return 0;
    }

    return -ENOENT;
}

static int xfs_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                       off_t offset, struct fuse_file_info *fi, enum fuse_readdir_flags flags) {
    (void)offset;
    (void)fi;
    (void)flags;

    if (strcmp(path, "/") != 0) {
        return -ENOENT;
    }

    filler(buf, ".", NULL, 0, 0);
    filler(buf, "..", NULL, 0, 0);
    filler(buf, ".xfs_info", NULL, 0, 0);
    return 0;
}

static int xfs_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, "/.xfs_info") == 0) {
        if ((fi->flags & O_ACCMODE) != O_RDONLY) {
            return -EACCES;
        }
        return 0;
    }
    return -ENOENT;
}

static int xfs_read(const char *path, char *buf, size_t size, off_t offset,
                    struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, "/.xfs_info") != 0) {
        return -ENOENT;
    }

    char content[512];
    int len = snprintf(content, sizeof(content),
                       "Filesystem: XFS\nLabel: %s\nUUID: %s\nTotal Blocks: %llu\nBlock Size: %u\n",
                       g_xfs_ctx.label, g_xfs_ctx.uuid_str,
                       (unsigned long long)g_xfs_ctx.total_blocks, g_xfs_ctx.blocksize);

    if (offset >= len) return 0;
    if (offset + size > (size_t)len) size = len - offset;
    memcpy(buf, content + offset, size);
    return (int)size;
}

static int xfs_statfs(const char *path, struct statvfs *stbuf) {
    (void)path;
    memset(stbuf, 0, sizeof(struct statvfs));
    stbuf->f_bsize = g_xfs_ctx.blocksize;
    stbuf->f_frsize = g_xfs_ctx.blocksize;
    stbuf->f_blocks = g_xfs_ctx.total_blocks;
    stbuf->f_bfree = g_xfs_ctx.total_blocks / 4;
    stbuf->f_bavail = stbuf->f_bfree;
    stbuf->f_namemax = 255;
    return 0;
}

static struct fuse_operations xfs_oper = {
    .getattr = xfs_getattr,
    .readdir = xfs_readdir,
    .open = xfs_open,
    .read = xfs_read,
    .statfs = xfs_statfs,
};

int main(int argc, char *argv[]) {
    struct sigaction sigpipe_action;
    memset(&sigpipe_action, 0, sizeof(sigpipe_action));
    sigpipe_action.sa_handler = sigpipe_handler;
    sigemptyset(&sigpipe_action.sa_mask);
    sigaction(SIGPIPE, &sigpipe_action, NULL);

    memset(&g_xfs_ctx, 0, sizeof(g_xfs_ctx));
    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);

    if (fuse_opt_parse(&args, &g_xfs_ctx, NULL, xfs_opt_proc) != 0) {
        return 1;
    }

    if (!g_xfs_ctx.device) {
        fprintf(stderr, "Usage: xfs-fuse [options] <device> <mountpoint>\n");
        return 1;
    }

    if (xfs_read_superblock(&g_xfs_ctx) != 0) {
        return 1;
    }

    return fuse_main(args.argc, args.argv, &xfs_oper, &g_xfs_ctx);
}
