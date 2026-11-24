#define FUSE_USE_VERSION 31
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "cowfs_bridge.h"
#include <errno.h>
#include <fcntl.h>
#include <fuse.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

typedef enum {
    MAP_MODE_NONE = 0,
    MAP_MODE_LUKS = 1,
    MAP_MODE_LVM  = 2
} map_mode_t;

typedef struct {
    map_mode_t    mode;
    int           read_only;
    uid_t         uid;
    gid_t         gid;
    time_t        mount_time;
    char          file_name[128];
    cowfs_luks_t *luks_ctx;
    int           lvm_fd;
    uint64_t      lvm_offset;
    uint64_t      virtual_size;
} mapper_state_t;

static mapper_state_t g_map;

static int is_mapped_file(const char *path) {
    if (!path || path[0] != '/') return 0;
    return strcmp(path + 1, g_map.file_name) == 0;
}

static int mp_getattr(const char *path, struct stat *st, struct fuse_file_info *fi) {
    (void)fi;
    memset(st, 0, sizeof(*st));
    st->st_uid = g_map.uid;
    st->st_gid = g_map.gid;
    st->st_atime = g_map.mount_time;
    st->st_mtime = g_map.mount_time;
    st->st_ctime = g_map.mount_time;

    if (strcmp(path, "/") == 0) {
        st->st_ino = 1;
        st->st_mode = S_IFDIR | 0755;
        st->st_nlink = 2;
        return 0;
    }
    if (is_mapped_file(path)) {
        st->st_ino = 2;
        st->st_mode = S_IFREG | (g_map.read_only ? 0400 : 0600);
        st->st_nlink = 1;
        st->st_size = (off_t)g_map.virtual_size;
        st->st_blocks = (blkcnt_t)((g_map.virtual_size + 511ULL) / 512ULL);
        return 0;
    }
    return -ENOENT;
}

static int mp_readdir(
    const char *path,
    void *buf,
    fuse_fill_dir_t filler,
    off_t offset,
    struct fuse_file_info *fi,
    enum fuse_readdir_flags flags
) {
    (void)offset;
    (void)fi;
    (void)flags;
    if (strcmp(path, "/") != 0) return -ENOENT;
    filler(buf, ".", NULL, 0, (enum fuse_fill_dir_flags)0);
    filler(buf, "..", NULL, 0, (enum fuse_fill_dir_flags)0);
    filler(buf, g_map.file_name, NULL, 0, (enum fuse_fill_dir_flags)0);
    return 0;
}

static int mp_open(const char *path, struct fuse_file_info *fi) {
    if (!is_mapped_file(path)) return -ENOENT;
    if (g_map.read_only && (fi->flags & O_ACCMODE) != O_RDONLY) return -EROFS;
    return 0;
}

static int mp_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    (void)fi;
    if (!is_mapped_file(path)) return -ENOENT;
    if (offset < 0) return -EINVAL;
    uint64_t uoff = (uint64_t)offset;
    if (uoff >= g_map.virtual_size) return 0;
    if (uoff + size > g_map.virtual_size) {
        size = (size_t)(g_map.virtual_size - uoff);
    }
    if (size == 0) return 0;

    if (g_map.mode == MAP_MODE_LUKS) {
        int rc = cowfs_luks_pread(g_map.luks_ctx, uoff, size, buf);
        return (rc < 0) ? rc : (int)size;
    } else if (g_map.mode == MAP_MODE_LVM) {
        size_t done = 0;
        while (done < size) {
            ssize_t r = pread(g_map.lvm_fd, buf + done, size - done, (off_t)(g_map.lvm_offset + uoff + done));
            if (r <= 0) return -EIO;
            done += (size_t)r;
        }
        return (int)done;
    }
    return -EIO;
}

static int mp_write(const char *path, const char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    (void)fi;
    if (!is_mapped_file(path)) return -ENOENT;
    if (g_map.read_only) return -EROFS;
    if (offset < 0) return -EINVAL;
    uint64_t uoff = (uint64_t)offset;
    if (uoff + size > g_map.virtual_size) return -ENOSPC;
    if (size == 0) return 0;

    if (g_map.mode == MAP_MODE_LUKS) {
        int rc = cowfs_luks_pwrite(g_map.luks_ctx, uoff, size, buf);
        return (rc < 0) ? rc : (int)size;
    } else if (g_map.mode == MAP_MODE_LVM) {
        size_t done = 0;
        while (done < size) {
            ssize_t w = pwrite(g_map.lvm_fd, buf + done, size - done, (off_t)(g_map.lvm_offset + uoff + done));
            if (w <= 0) return -EIO;
            done += (size_t)w;
        }
        return (int)done;
    }
    return -EIO;
}

static int mp_fsync(const char *path, int isdatasync, struct fuse_file_info *fi) {
    (void)path;
    (void)isdatasync;
    (void)fi;
    if (g_map.read_only) return 0;
    if (g_map.mode == MAP_MODE_LVM && g_map.lvm_fd >= 0) {
        return (fsync(g_map.lvm_fd) == 0) ? 0 : -errno;
    }
    return 0;
}

static void mp_destroy(void *priv) {
    (void)priv;
    if (g_map.luks_ctx) {
        cowfs_luks_close(g_map.luks_ctx);
        g_map.luks_ctx = NULL;
    }
    if (g_map.lvm_fd >= 0) {
        close(g_map.lvm_fd);
        g_map.lvm_fd = -1;
    }
}

static const struct fuse_operations k_map_ops = {
    .getattr = mp_getattr,
    .readdir = mp_readdir,
    .open    = mp_open,
    .read    = mp_read,
    .write   = mp_write,
    .fsync   = mp_fsync,
    .destroy = mp_destroy,
};

static int read_passphrase_stdin(char *buf, size_t cap) {
    if (!fgets(buf, (int)cap, stdin)) {
        buf[0] = '\0';
        return -EINVAL;
    }
    size_t len = strlen(buf);
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
        buf[--len] = '\0';
    }
    return 0;
}

int main(int argc, char **argv) {
    memset(&g_map, 0, sizeof(g_map));
    g_map.lvm_fd = -1;
    g_map.uid = getuid();
    g_map.gid = getgid();
    g_map.mount_time = time(NULL);
    snprintf(g_map.file_name, sizeof(g_map.file_name), "volume.raw");

    int foreground = 1;
    const char *source_path = NULL;
    const char *mountpoint = NULL;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--mode") == 0 && i + 1 < argc) {
            const char *m = argv[++i];
            if (strcmp(m, "luks") == 0) g_map.mode = MAP_MODE_LUKS;
            else if (strcmp(m, "lvm") == 0) g_map.mode = MAP_MODE_LVM;
        } else if (strcmp(a, "--ro") == 0 || strcmp(a, "-r") == 0) {
            g_map.read_only = 1;
        } else if (strcmp(a, "-f") == 0) {
            foreground = 1;
        } else if (strcmp(a, "--offset") == 0 && i + 1 < argc) {
            g_map.lvm_offset = strtoull(argv[++i], NULL, 10);
        } else if (strcmp(a, "--size") == 0 && i + 1 < argc) {
            g_map.virtual_size = strtoull(argv[++i], NULL, 10);
        } else if (strcmp(a, "--name") == 0 && i + 1 < argc) {
            snprintf(g_map.file_name, sizeof(g_map.file_name), "%s", argv[++i]);
        } else if (strcmp(a, "--uid") == 0 && i + 1 < argc) {
            g_map.uid = (uid_t)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(a, "--gid") == 0 && i + 1 < argc) {
            g_map.gid = (gid_t)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(a, "--version") == 0 || strcmp(a, "-V") == 0) {
            printf("montserrat-mapper 1.1.0\n");
            return 0;
        } else if (a[0] != '-') {
            if (!source_path) source_path = a;
            else if (!mountpoint) mountpoint = a;
        }
    }

    if (g_map.mode == MAP_MODE_NONE || !source_path || !mountpoint) {
        fprintf(stderr, "Usage: %s --mode <luks|lvm> [--ro] [--offset B --size B] [--name file.raw] <source> <mountpoint>\n", argv[0]);
        return 1;
    }

    if (g_map.mode == MAP_MODE_LUKS) {
        char pass[512];
        if (read_passphrase_stdin(pass, sizeof(pass)) != 0) {
            fprintf(stderr, "montserrat-mapper: expected passphrase on stdin\n");
            return 1;
        }
        int rc = cowfs_luks_unlock(source_path, pass, g_map.read_only, &g_map.luks_ctx);
        memset(pass, 0, sizeof(pass));
        if (rc != 0) {
            fprintf(stderr, "montserrat-mapper: LUKS unlock failed on %s: %s\n", source_path, strerror(-rc));
            return (rc == -EACCES) ? 2 : 1;
        }
        g_map.virtual_size = cowfs_luks_size(g_map.luks_ctx);
    } else {
        if (g_map.virtual_size == 0) {
            fprintf(stderr, "montserrat-mapper: --size is required for LVM mode\n");
            return 1;
        }
        int fd = open(source_path, g_map.read_only ? O_RDONLY : O_RDWR);
        if (fd < 0) {
            fprintf(stderr, "montserrat-mapper: failed to open %s: %s\n", source_path, strerror(errno));
            return 1;
        }
        g_map.lvm_fd = fd;
    }

    char opts[128];
    snprintf(opts, sizeof(opts), "%s,default_permissions", g_map.read_only ? "ro" : "rw");

    char *fuse_argv[8];
    int fuse_argc = 0;
    fuse_argv[fuse_argc++] = argv[0];
    if (foreground) fuse_argv[fuse_argc++] = "-f";
    fuse_argv[fuse_argc++] = "-o";
    fuse_argv[fuse_argc++] = opts;
    fuse_argv[fuse_argc++] = (char *)mountpoint;
    fuse_argv[fuse_argc] = NULL;

    return fuse_main(fuse_argc, fuse_argv, &k_map_ops, NULL);
}
