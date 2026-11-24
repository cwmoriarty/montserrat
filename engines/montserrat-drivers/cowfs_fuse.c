#define FUSE_USE_VERSION 31
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "cowfs_bridge.h"
#include <errno.h>
#include <fuse.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef COWFS_DEFAULT_KIND
#define COWFS_DEFAULT_KIND COWFS_KIND_XFS
#endif

typedef struct {
    cowfs_t *fs;
    int read_only;
    int override_uid;
    uid_t uid;
    int override_gid;
    gid_t gid;
} cowfs_fuse_state_t;

static cowfs_fuse_state_t g_state;

static int split_parent_child(const char *path, uint64_t *out_parent_ino, char *child_name, size_t child_cap) {
    if (!path || path[0] != '/') return -EINVAL;
    const char *last_slash = strrchr(path, '/');
    if (!last_slash) return -EINVAL;
    const char *base = last_slash + 1;
    size_t blen = strlen(base);
    if (blen == 0 || blen >= child_cap) return (blen == 0) ? -EINVAL : -ENAMETOOLONG;
    memcpy(child_name, base, blen + 1U);

    if (last_slash == path) {
        *out_parent_ino = cowfs_root_ino(g_state.fs);
        return 0;
    }
    size_t plen = (size_t)(last_slash - path);
    char *parent = (char *)malloc(plen + 1U);
    if (!parent) return -ENOMEM;
    memcpy(parent, path, plen);
    parent[plen] = '\0';
    int rc = cowfs_lookup_path(g_state.fs, parent, out_parent_ino);
    free(parent);
    return rc;
}

static void attrs_to_stat(const cowfs_item_attrs_t *a, struct stat *st) {
    memset(st, 0, sizeof(*st));
    st->st_ino = (ino_t)a->ino;
    st->st_mode = (mode_t)(g_state.read_only ? (a->mode & ~(uint32_t)0222) : a->mode);
    st->st_nlink = (nlink_t)(a->nlink ? a->nlink : 1U);
    st->st_uid = g_state.override_uid ? g_state.uid : (uid_t)a->uid;
    st->st_gid = g_state.override_gid ? g_state.gid : (gid_t)a->gid;
    st->st_size = (off_t)a->size;
    st->st_blocks = (blkcnt_t)((a->alloc_size + 511ULL) / 512ULL);
    st->st_atime = (time_t)a->atime_sec;
    st->st_mtime = (time_t)a->mtime_sec;
    st->st_ctime = (time_t)a->ctime_sec;
}

static int cf_getattr(const char *path, struct stat *stbuf, struct fuse_file_info *fi) {
    (void)fi;
    uint64_t ino = 0;
    int rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc != 0) return rc;
    cowfs_item_attrs_t attrs;
    rc = cowfs_getattr(g_state.fs, ino, &attrs);
    if (rc == 0) attrs_to_stat(&attrs, stbuf);
    return rc;
}

typedef struct {
    void *buf;
    fuse_fill_dir_t filler;
} cf_dir_pack_t;

static int cf_dir_cb(void *user_ctx, const char *name, uint64_t ino, uint8_t file_type, uint64_t next_cookie) {
    (void)next_cookie;
    cf_dir_pack_t *pk = (cf_dir_pack_t *)user_ctx;
    struct stat st;
    memset(&st, 0, sizeof(st));
    st.st_ino = (ino_t)ino;
    if (file_type == 2U) st.st_mode = S_IFDIR | 0755;
    else if (file_type == 3U) st.st_mode = S_IFLNK | 0777;
    else st.st_mode = S_IFREG | 0644;
    return pk->filler(pk->buf, name, &st, 0, (enum fuse_fill_dir_flags)0);
}

static int cf_readdir(
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
    uint64_t ino = 0;
    int rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc != 0) return rc;
    filler(buf, ".", NULL, 0, (enum fuse_fill_dir_flags)0);
    filler(buf, "..", NULL, 0, (enum fuse_fill_dir_flags)0);
    cf_dir_pack_t pk = { buf, filler };
    return cowfs_readdir(g_state.fs, ino, 0ULL, cf_dir_cb, &pk);
}

static int cf_open(const char *path, struct fuse_file_info *fi) {
    if (g_state.read_only && (fi->flags & O_ACCMODE) != O_RDONLY) return -EROFS;
    uint64_t ino = 0;
    int rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc == 0) fi->fh = ino;
    return rc;
}

static int cf_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
    if (g_state.read_only) return -EROFS;
    uint64_t pino = 0, ino = 0;
    char name[256];
    int rc = split_parent_child(path, &pino, name, sizeof(name));
    if (rc != 0) return rc;
    rc = cowfs_create(g_state.fs, pino, name, (uint32_t)(mode & 07777), &ino);
    if (rc == 0) fi->fh = ino;
    return rc;
}

static int cf_mkdir(const char *path, mode_t mode) {
    if (g_state.read_only) return -EROFS;
    uint64_t pino = 0, ino = 0;
    char name[256];
    int rc = split_parent_child(path, &pino, name, sizeof(name));
    if (rc != 0) return rc;
    return cowfs_mkdir(g_state.fs, pino, name, (uint32_t)(mode & 07777), &ino);
}

static int cf_unlink(const char *path) {
    if (g_state.read_only) return -EROFS;
    uint64_t pino = 0;
    char name[256];
    int rc = split_parent_child(path, &pino, name, sizeof(name));
    if (rc != 0) return rc;
    return cowfs_unlink(g_state.fs, pino, name);
}

static int cf_rmdir(const char *path) {
    if (g_state.read_only) return -EROFS;
    uint64_t pino = 0;
    char name[256];
    int rc = split_parent_child(path, &pino, name, sizeof(name));
    if (rc != 0) return rc;
    return cowfs_rmdir(g_state.fs, pino, name);
}

static int cf_symlink(const char *target, const char *linkpath) {
    if (g_state.read_only) return -EROFS;
    uint64_t pino = 0, ino = 0;
    char name[256];
    int rc = split_parent_child(linkpath, &pino, name, sizeof(name));
    if (rc != 0) return rc;
    return cowfs_symlink(g_state.fs, pino, name, target, &ino);
}

static int cf_readlink(const char *path, char *buf, size_t size) {
    uint64_t ino = 0;
    int rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc != 0) return rc;
    size_t got = 0;
    return cowfs_readlink(g_state.fs, ino, buf, size, &got);
}

static int cf_rename(const char *from, const char *to, unsigned int flags) {
    if (g_state.read_only) return -EROFS;
    if (flags != 0U) return -EINVAL;
    uint64_t old_pino = 0, new_pino = 0;
    char old_name[256], new_name[256];
    int rc = split_parent_child(from, &old_pino, old_name, sizeof(old_name));
    if (rc != 0) return rc;
    rc = split_parent_child(to, &new_pino, new_name, sizeof(new_name));
    if (rc != 0) return rc;
    return cowfs_rename(g_state.fs, old_pino, old_name, new_pino, new_name);
}

static int cf_chmod(const char *path, mode_t mode, struct fuse_file_info *fi) {
    (void)fi;
    if (g_state.read_only) return -EROFS;
    uint64_t ino = 0;
    int rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc != 0) return rc;
    cowfs_item_attrs_t a;
    memset(&a, 0, sizeof(a));
    a.mode = (uint32_t)mode;
    return cowfs_setattr(g_state.fs, ino, COWFS_ATTR_MODE, &a);
}

static int cf_chown(const char *path, uid_t uid, gid_t gid, struct fuse_file_info *fi) {
    (void)fi;
    if (g_state.read_only) return -EROFS;
    uint64_t ino = 0;
    int rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc != 0) return rc;
    cowfs_item_attrs_t a;
    memset(&a, 0, sizeof(a));
    uint32_t mask = 0;
    if (uid != (uid_t)-1) { a.uid = (uint32_t)uid; mask |= COWFS_ATTR_UID; }
    if (gid != (gid_t)-1) { a.gid = (uint32_t)gid; mask |= COWFS_ATTR_GID; }
    return mask ? cowfs_setattr(g_state.fs, ino, mask, &a) : 0;
}

static int cf_truncate(const char *path, off_t size, struct fuse_file_info *fi) {
    (void)fi;
    if (g_state.read_only) return -EROFS;
    if (size < 0) return -EINVAL;
    uint64_t ino = 0;
    int rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc != 0) return rc;
    cowfs_item_attrs_t a;
    memset(&a, 0, sizeof(a));
    a.size = (uint64_t)size;
    return cowfs_setattr(g_state.fs, ino, COWFS_ATTR_SIZE, &a);
}

static int cf_utimens(const char *path, const struct timespec tv[2], struct fuse_file_info *fi) {
    (void)fi;
    if (g_state.read_only) return -EROFS;
    uint64_t ino = 0;
    int rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc != 0) return rc;
    cowfs_item_attrs_t a;
    memset(&a, 0, sizeof(a));
    uint32_t mask = 0;
    time_t now = time(NULL);
    if (!tv) {
        a.atime_sec = (int64_t)now;
        a.mtime_sec = (int64_t)now;
        mask = COWFS_ATTR_ATIME | COWFS_ATTR_MTIME;
    } else {
        if (tv[0].tv_nsec != UTIME_OMIT) {
            a.atime_sec = (tv[0].tv_nsec == UTIME_NOW) ? (int64_t)now : (int64_t)tv[0].tv_sec;
            mask |= COWFS_ATTR_ATIME;
        }
        if (tv[1].tv_nsec != UTIME_OMIT) {
            a.mtime_sec = (tv[1].tv_nsec == UTIME_NOW) ? (int64_t)now : (int64_t)tv[1].tv_sec;
            mask |= COWFS_ATTR_MTIME;
        }
    }
    return mask ? cowfs_setattr(g_state.fs, ino, mask, &a) : 0;
}

static int cf_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    if (offset < 0) return -EINVAL;
    uint64_t ino = (fi && fi->fh != 0) ? fi->fh : 0;
    int rc = 0;
    if (ino == 0) rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc != 0) return rc;
    size_t got = 0;
    rc = cowfs_read(g_state.fs, ino, (uint64_t)offset, size, buf, &got);
    return (rc < 0) ? rc : (int)got;
}

static int cf_write(const char *path, const char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    if (g_state.read_only) return -EROFS;
    if (offset < 0) return -EINVAL;
    uint64_t ino = (fi && fi->fh != 0) ? fi->fh : 0;
    int rc = 0;
    if (ino == 0) rc = cowfs_lookup_path(g_state.fs, path, &ino);
    if (rc != 0) return rc;
    size_t put = 0;
    rc = cowfs_write(g_state.fs, ino, (uint64_t)offset, size, buf, &put);
    return (rc < 0) ? rc : (int)put;
}

static int cf_statfs(const char *path, struct statvfs *stbuf) {
    (void)path;
    memset(stbuf, 0, sizeof(*stbuf));
    uint64_t total_b = 0, free_b = 0;
    uint32_t bsize = 4096U;
    int rc = cowfs_statfs(g_state.fs, &total_b, &free_b, &bsize);
    if (rc == 0 && bsize > 0) {
        stbuf->f_bsize = bsize;
        stbuf->f_frsize = bsize;
        stbuf->f_blocks = (fsblkcnt_t)(total_b / bsize);
        stbuf->f_bfree = (fsblkcnt_t)(free_b / bsize);
        stbuf->f_bavail = (fsblkcnt_t)(free_b / bsize);
        stbuf->f_namemax = 255U;
    }
    return rc;
}

static int cf_flush(const char *path, struct fuse_file_info *fi) {
    (void)path;
    (void)fi;
    return g_state.read_only ? 0 : cowfs_sync(g_state.fs);
}

static int cf_fsync(const char *path, int isdatasync, struct fuse_file_info *fi) {
    (void)path;
    (void)isdatasync;
    (void)fi;
    return g_state.read_only ? 0 : cowfs_sync(g_state.fs);
}

static void cf_destroy(void *priv) {
    (void)priv;
    if (g_state.fs) {
        cowfs_unmount(g_state.fs);
        g_state.fs = NULL;
    }
}

static const struct fuse_operations k_ops = {
    .getattr  = cf_getattr,
    .readlink = cf_readlink,
    .mkdir    = cf_mkdir,
    .unlink   = cf_unlink,
    .rmdir    = cf_rmdir,
    .symlink  = cf_symlink,
    .rename   = cf_rename,
    .chmod    = cf_chmod,
    .chown    = cf_chown,
    .truncate = cf_truncate,
    .open     = cf_open,
    .create   = cf_create,
    .read     = cf_read,
    .write    = cf_write,
    .statfs   = cf_statfs,
    .flush    = cf_flush,
    .fsync    = cf_fsync,
    .readdir  = cf_readdir,
    .utimens  = cf_utimens,
    .destroy  = cf_destroy,
};

static void filter_mount_options(const char *raw_opts, char *out_opts, size_t out_cap) {
    if (!raw_opts || !raw_opts[0]) return;
    char *copy = strdup(raw_opts);
    if (!copy) return;

    char *saveptr = NULL;
    for (char *tok = strtok_r(copy, ",", &saveptr); tok != NULL; tok = strtok_r(NULL, ",", &saveptr)) {
        if (strcmp(tok, "ro") == 0) {
            g_state.read_only = 1;
        } else if (strcmp(tok, "rw") == 0) {
            g_state.read_only = 0;
        } else if (strncmp(tok, "uid=", 4) == 0) {
            g_state.override_uid = 1;
            g_state.uid = (uid_t)strtoul(tok + 4, NULL, 10);
        } else if (strncmp(tok, "gid=", 4) == 0) {
            g_state.override_gid = 1;
            g_state.gid = (gid_t)strtoul(tok + 4, NULL, 10);
        } else if (strcmp(tok, "allow_other") == 0 ||
                   strcmp(tok, "default_permissions") == 0 ||
                   strncmp(tok, "fsname=", 7) == 0 ||
                   strncmp(tok, "subtype=", 8) == 0 ||
                   strncmp(tok, "volname=", 8) == 0) {
#ifndef __APPLE__
            if (strncmp(tok, "volname=", 8) == 0) continue;
#endif
            size_t cur = strlen(out_opts);
            snprintf(out_opts + cur, out_cap - cur, "%s%s", cur ? "," : "", tok);
        }
    }
    free(copy);
}

int main(int argc, char **argv) {
    memset(&g_state, 0, sizeof(g_state));
    cowfs_kind_t kind = COWFS_DEFAULT_KIND;
    const char *device_path = NULL;
    const char *mountpoint = NULL;
    int foreground = 0;
    int debug = 0;
    char extra_opts[512] = "";

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "-f") == 0) foreground = 1;
        else if (strcmp(a, "-d") == 0) { debug = 1; foreground = 1; }
        else if (strcmp(a, "-r") == 0) g_state.read_only = 1;
        else if (strcmp(a, "-s") == 0) { /* accepted */ }
        else if (strcmp(a, "-o") == 0 && i + 1 < argc) {
            filter_mount_options(argv[++i], extra_opts, sizeof(extra_opts));
        } else if (strncmp(a, "-o", 2) == 0 && a[2] != '\0') {
            filter_mount_options(a + 2, extra_opts, sizeof(extra_opts));
        } else if (strcmp(a, "--version") == 0 || strcmp(a, "-V") == 0) {
            printf("%s 1.1.0 (Montserrat CCowFS)\n", argv[0]);
            return 0;
        } else if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
            printf("Usage: %s [-f] [-r] [-o options] <device|image> <mountpoint>\n", argv[0]);
            return 0;
        } else if (a[0] != '-') {
            if (!device_path) device_path = a;
            else if (!mountpoint) mountpoint = a;
        }
    }

    if (!device_path || !mountpoint) {
        fprintf(stderr, "Usage: %s [-f] [-r] [-o options] <device|image> <mountpoint>\n", argv[0]);
        return 1;
    }

    int rc = cowfs_mount_path(kind, device_path, g_state.read_only, &g_state.fs);
    if (rc != 0) {
        fprintf(stderr, "%s: failed to mount %s: %s\n", argv[0], device_path, strerror(-rc));
        return 1;
    }

    char final_opts[600];
    if (extra_opts[0]) {
        snprintf(final_opts, sizeof(final_opts), "%s,%s", g_state.read_only ? "ro" : "rw", extra_opts);
    } else {
        snprintf(final_opts, sizeof(final_opts), "%s", g_state.read_only ? "ro" : "rw");
    }

    char *fuse_argv[8];
    int fuse_argc = 0;
    fuse_argv[fuse_argc++] = argv[0];
    if (foreground) fuse_argv[fuse_argc++] = "-f";
    if (debug) fuse_argv[fuse_argc++] = "-d";
    fuse_argv[fuse_argc++] = "-o";
    fuse_argv[fuse_argc++] = final_opts;
    fuse_argv[fuse_argc++] = (char *)mountpoint;
    fuse_argv[fuse_argc] = NULL;

    return fuse_main(fuse_argc, fuse_argv, &k_ops, NULL);
}
