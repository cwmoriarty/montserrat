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

struct btrfs_context {
    char *device;
    int dev_fd;
    char label[257];
    char uuid_str[37];
    uint64_t total_bytes;
    uint64_t num_devices;
    uint32_t sectorsize;
    uint32_t nodesize;
    int read_only;
};

static struct btrfs_context g_btrfs_ctx;

static void sigpipe_handler(int sig) {
    (void)sig;
}

static int btrfs_opt_proc(void *data, const char *arg, int key, struct fuse_args *outargs) {
    struct btrfs_context *ctx = (struct btrfs_context *)data;
    if (key == FUSE_OPT_KEY_NONOPT) {
        if (!ctx->device) {
            ctx->device = strdup(arg);
            return 0; // Consumed as device path, do not pass to FUSE
        }
    }
    return 1;
}

static int btrfs_read_superblock(struct btrfs_context *ctx) {
    int fd = open(ctx->device, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "btrfs-fuse: failed to open device %s: %s\n", ctx->device, strerror(errno));
        return -errno;
    }
    ctx->dev_fd = fd;

    unsigned char buf[4096];
    if (pread(fd, buf, sizeof(buf), 65536) != sizeof(buf)) {
        fprintf(stderr, "btrfs-fuse: failed to read superblock at offset 64K\n");
        return -EIO;
    }

    // Magic at offset 64: "_BHRfS_M"
    if (memcmp(buf + 64, "_BHRfS_M", 8) != 0) {
        fprintf(stderr, "btrfs-fuse: invalid Btrfs magic at offset 64K\n");
        return -EINVAL;
    }

    // UUID: 16 bytes at offset 32
    snprintf(ctx->uuid_str, sizeof(ctx->uuid_str),
             "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             buf[32], buf[33], buf[34], buf[35],
             buf[36], buf[37], buf[38], buf[39],
             buf[40], buf[41], buf[42], buf[43],
             buf[44], buf[45], buf[46], buf[47]);

    // Total bytes at offset 112 (uint64)
    uint64_t total_bytes = 0;
    memcpy(&total_bytes, buf + 112, 8);
    ctx->total_bytes = total_bytes;

    // Sector size at offset 144 (uint32)
    uint32_t sectorsize = 4096;
    memcpy(&sectorsize, buf + 144, 4);
    ctx->sectorsize = sectorsize > 0 ? sectorsize : 4096;

    // Label at offset 299 (256 bytes)
    memcpy(ctx->label, buf + 299, 256);
    ctx->label[256] = '\0';

    return 0;
}

static int btrfs_getattr(const char *path, struct stat *stbuf, struct fuse_file_info *fi) {
    (void)fi;
    memset(stbuf, 0, sizeof(struct stat));

    if (strcmp(path, "/") == 0) {
        stbuf->st_mode = S_IFDIR | 0755;
        stbuf->st_nlink = 2;
        stbuf->st_uid = getuid();
        stbuf->st_gid = getgid();
        return 0;
    }

    if (strcmp(path, "/.btrfs_info") == 0) {
        stbuf->st_mode = S_IFREG | 0444;
        stbuf->st_nlink = 1;
        stbuf->st_size = 256;
        stbuf->st_uid = getuid();
        stbuf->st_gid = getgid();
        return 0;
    }

    return -ENOENT;
}

static int btrfs_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                         off_t offset, struct fuse_file_info *fi, enum fuse_readdir_flags flags) {
    (void)offset;
    (void)fi;
    (void)flags;

    if (strcmp(path, "/") != 0) {
        return -ENOENT;
    }

    filler(buf, ".", NULL, 0, 0);
    filler(buf, "..", NULL, 0, 0);
    filler(buf, ".btrfs_info", NULL, 0, 0);
    return 0;
}

static int btrfs_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, "/.btrfs_info") == 0) {
        if ((fi->flags & O_ACCMODE) != O_RDONLY) {
            return -EACCES;
        }
        return 0;
    }
    return -ENOENT;
}

static int btrfs_read(const char *path, char *buf, size_t size, off_t offset,
                      struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, "/.btrfs_info") != 0) {
        return -ENOENT;
    }

    char content[512];
    int len = snprintf(content, sizeof(content),
                       "Filesystem: Btrfs\nLabel: %s\nUUID: %s\nTotal Size: %llu bytes\nSector Size: %u\n",
                       g_btrfs_ctx.label, g_btrfs_ctx.uuid_str,
                       (unsigned long long)g_btrfs_ctx.total_bytes, g_btrfs_ctx.sectorsize);

    if (offset >= len) return 0;
    if (offset + size > (size_t)len) size = len - offset;
    memcpy(buf, content + offset, size);
    return (int)size;
}

static int btrfs_statfs(const char *path, struct statvfs *stbuf) {
    (void)path;
    memset(stbuf, 0, sizeof(struct statvfs));
    stbuf->f_bsize = g_btrfs_ctx.sectorsize;
    stbuf->f_frsize = g_btrfs_ctx.sectorsize;
    if (g_btrfs_ctx.sectorsize > 0) {
        stbuf->f_blocks = g_btrfs_ctx.total_bytes / g_btrfs_ctx.sectorsize;
        stbuf->f_bfree = stbuf->f_blocks / 4;
        stbuf->f_bavail = stbuf->f_bfree;
    }
    stbuf->f_namemax = 255;
    return 0;
}

static struct fuse_operations btrfs_oper = {
    .getattr = btrfs_getattr,
    .readdir = btrfs_readdir,
    .open = btrfs_open,
    .read = btrfs_read,
    .statfs = btrfs_statfs,
};

int main(int argc, char *argv[]) {
    struct sigaction sigpipe_action;
    memset(&sigpipe_action, 0, sizeof(sigpipe_action));
    sigpipe_action.sa_handler = sigpipe_handler;
    sigemptyset(&sigpipe_action.sa_mask);
    sigaction(SIGPIPE, &sigpipe_action, NULL);

    memset(&g_btrfs_ctx, 0, sizeof(g_btrfs_ctx));
    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);

    if (fuse_opt_parse(&args, &g_btrfs_ctx, NULL, btrfs_opt_proc) != 0) {
        return 1;
    }

    if (!g_btrfs_ctx.device) {
        fprintf(stderr, "Usage: btrfs-fuse [options] <device> <mountpoint>\n");
        return 1;
    }

    if (btrfs_read_superblock(&g_btrfs_ctx) != 0) {
        return 1;
    }

    return fuse_main(args.argc, args.argv, &btrfs_oper, &g_btrfs_ctx);
}
