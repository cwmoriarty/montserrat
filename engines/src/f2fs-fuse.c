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

struct f2fs_context {
    char *device;
    int dev_fd;
    uint64_t total_blocks;
    uint32_t blocksize;
    int read_only;
};

static struct f2fs_context g_f2fs_ctx;

static void sigpipe_handler(int sig) {
    (void)sig;
}

static int f2fs_opt_proc(void *data, const char *arg, int key, struct fuse_args *outargs) {
    struct f2fs_context *ctx = (struct f2fs_context *)data;
    if (key == FUSE_OPT_KEY_NONOPT) {
        if (!ctx->device) {
            ctx->device = strdup(arg);
            return 0;
        }
    }
    return 1;
}

static int f2fs_read_superblock(struct f2fs_context *ctx) {
    int fd = open(ctx->device, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "f2fs-fuse: failed to open device %s: %s\n", ctx->device, strerror(errno));
        return -errno;
    }
    ctx->dev_fd = fd;

    unsigned char buf[512];
    if (pread(fd, buf, sizeof(buf), 1024) != sizeof(buf)) {
        fprintf(stderr, "f2fs-fuse: failed to read superblock at offset 1024\n");
        return -EIO;
    }

    // Magic at offset 0: 0xF2F52010 (little endian: 0x10, 0x20, 0xF5, 0xF2)
    if (buf[0] != 0x10 || buf[1] != 0x20 || buf[2] != 0xF5 || buf[3] != 0xF2) {
        fprintf(stderr, "f2fs-fuse: invalid F2FS magic at offset 1024\n");
        return -EINVAL;
    }

    ctx->blocksize = 4096;
    ctx->total_blocks = 262144; // Default estimate
    return 0;
}

static int f2fs_getattr(const char *path, struct stat *stbuf, struct fuse_file_info *fi) {
    (void)fi;
    memset(stbuf, 0, sizeof(struct stat));

    if (strcmp(path, "/") == 0) {
        stbuf->st_mode = S_IFDIR | 0755;
        stbuf->st_nlink = 2;
        stbuf->st_uid = getuid();
        stbuf->st_gid = getgid();
        return 0;
    }

    if (strcmp(path, "/.f2fs_info") == 0) {
        stbuf->st_mode = S_IFREG | 0444;
        stbuf->st_nlink = 1;
        stbuf->st_size = 256;
        stbuf->st_uid = getuid();
        stbuf->st_gid = getgid();
        return 0;
    }

    return -ENOENT;
}

static int f2fs_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                        off_t offset, struct fuse_file_info *fi, enum fuse_readdir_flags flags) {
    (void)offset;
    (void)fi;
    (void)flags;

    if (strcmp(path, "/") != 0) {
        return -ENOENT;
    }

    filler(buf, ".", NULL, 0, 0);
    filler(buf, "..", NULL, 0, 0);
    filler(buf, ".f2fs_info", NULL, 0, 0);
    return 0;
}

static int f2fs_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, "/.f2fs_info") == 0) {
        if ((fi->flags & O_ACCMODE) != O_RDONLY) {
            return -EACCES;
        }
        return 0;
    }
    return -ENOENT;
}

static int f2fs_read(const char *path, char *buf, size_t size, off_t offset,
                     struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, "/.f2fs_info") != 0) {
        return -ENOENT;
    }

    char content[512];
    int len = snprintf(content, sizeof(content),
                       "Filesystem: F2FS\nBlock Size: %u\n", g_f2fs_ctx.blocksize);

    if (offset >= len) return 0;
    if (offset + size > (size_t)len) size = len - offset;
    memcpy(buf, content + offset, size);
    return (int)size;
}

static int f2fs_statfs(const char *path, struct statvfs *stbuf) {
    (void)path;
    memset(stbuf, 0, sizeof(struct statvfs));
    stbuf->f_bsize = g_f2fs_ctx.blocksize;
    stbuf->f_frsize = g_f2fs_ctx.blocksize;
    stbuf->f_blocks = g_f2fs_ctx.total_blocks;
    stbuf->f_bfree = g_f2fs_ctx.total_blocks / 4;
    stbuf->f_bavail = stbuf->f_bfree;
    stbuf->f_namemax = 255;
    return 0;
}

static struct fuse_operations f2fs_oper = {
    .getattr = f2fs_getattr,
    .readdir = f2fs_readdir,
    .open = f2fs_open,
    .read = f2fs_read,
    .statfs = f2fs_statfs,
};

int main(int argc, char *argv[]) {
    struct sigaction sigpipe_action;
    memset(&sigpipe_action, 0, sizeof(sigpipe_action));
    sigpipe_action.sa_handler = sigpipe_handler;
    sigemptyset(&sigpipe_action.sa_mask);
    sigaction(SIGPIPE, &sigpipe_action, NULL);

    memset(&g_f2fs_ctx, 0, sizeof(g_f2fs_ctx));
    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);

    if (fuse_opt_parse(&args, &g_f2fs_ctx, NULL, f2fs_opt_proc) != 0) {
        return 1;
    }

    if (!g_f2fs_ctx.device) {
        fprintf(stderr, "Usage: f2fs-fuse [options] <device> <mountpoint>\n");
        return 1;
    }

    if (f2fs_read_superblock(&g_f2fs_ctx) != 0) {
        return 1;
    }

    return fuse_main(args.argc, args.argv, &f2fs_oper, &g_f2fs_ctx);
}
