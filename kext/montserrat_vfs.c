/*
 * montserrat_vfs.c
 * Experimental Darwin VFS kernel module scaffold.
 * Registers the montserrat_ext4 filesystem table entry with the XNU VFS layer.
 * Mount and root vnode resolution return ENOTSUP (45) until full kernel block I/O is wired.
 */
#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/mount.h>
#include <sys/vnode.h>
#include <sys/vnode_if.h>
#include <mach/mach_types.h>

#define MONTSERRAT_FSNAME "montserrat_ext4"
#define MONTSERRAT_EINVAL  22
#define MONTSERRAT_ENOTSUP 45

static vfstable_t g_vfs_handle = NULL;

/* VFS Operations */
static int montserrat_vfs_mount(struct mount *mp, vnode_t devvp, user_addr_t data, vfs_context_t context) {
    (void)mp;
    (void)data;
    (void)context;
    if (devvp == NULL) {
        return MONTSERRAT_EINVAL;
    }
    return MONTSERRAT_ENOTSUP;
}

static int montserrat_vfs_start(struct mount *mp, int flags, vfs_context_t context) {
    (void)mp;
    (void)flags;
    (void)context;
    return 0;
}

static int montserrat_vfs_unmount(struct mount *mp, int mntflags, vfs_context_t context) {
    (void)mp;
    (void)mntflags;
    (void)context;
    return 0;
}

static int montserrat_vfs_root(struct mount *mp, struct vnode **vpp, vfs_context_t context) {
    (void)mp;
    (void)context;
    if (vpp != NULL) {
        *vpp = NULL;
    }
    return MONTSERRAT_ENOTSUP;
}

static int montserrat_vfs_getattr(struct mount *mp, struct vfs_attr *vfa, vfs_context_t context) {
    (void)mp;
    (void)vfa;
    (void)context;
    return MONTSERRAT_ENOTSUP;
}

static int montserrat_vfs_sync(struct mount *mp, int waitfor, vfs_context_t context) {
    (void)mp;
    (void)waitfor;
    (void)context;
    return 0;
}

static int montserrat_vfs_init(struct vfsconf *vfsc) {
    (void)vfsc;
    return 0;
}

static struct vfsops g_montserrat_vfsops = {
    .vfs_mount   = montserrat_vfs_mount,
    .vfs_start   = montserrat_vfs_start,
    .vfs_unmount = montserrat_vfs_unmount,
    .vfs_root    = montserrat_vfs_root,
    .vfs_getattr = montserrat_vfs_getattr,
    .vfs_sync    = montserrat_vfs_sync,
    .vfs_init    = montserrat_vfs_init,
};

/* Vnode Operations vector */
extern struct vnodeop_desc vnop_default_desc;

static int (**g_montserrat_vnodeop_p)(void *);

static const struct vnodeopv_entry_desc g_montserrat_vnodeop_entries[] = {
    { &vnop_default_desc, NULL },
    { NULL, NULL }
};

static struct vnodeopv_desc g_montserrat_vnodeop_opv_desc = {
    &g_montserrat_vnodeop_p,
    g_montserrat_vnodeop_entries
};

static struct vnodeopv_desc *g_montserrat_vnodeopv_descs[] = {
    &g_montserrat_vnodeop_opv_desc,
    NULL
};

/* Filesystem entry */
static struct vfs_fsentry g_montserrat_fsentry = {
    .vfe_vfsops    = &g_montserrat_vfsops,
    .vfe_vopcnt    = 1,
    .vfe_opvdescs  = g_montserrat_vnodeopv_descs,
    .vfe_fstypenum = 0,
    .vfe_fsname    = MONTSERRAT_FSNAME,
    .vfe_flags     = MNT_LOCAL,
    .vfe_reserv    = { 0, 0 }
};

/* Kernel module lifecycle */
kern_return_t montserrat_kext_start(kmod_info_t *ki, void *d) {
    (void)ki;
    (void)d;
    int error = vfs_fsadd(&g_montserrat_fsentry, &g_vfs_handle);
    if (error != 0) {
        return KERN_FAILURE;
    }
    return KERN_SUCCESS;
}

kern_return_t montserrat_kext_stop(kmod_info_t *ki, void *d) {
    (void)ki;
    (void)d;
    if (g_vfs_handle != NULL) {
        int error = vfs_fsremove(g_vfs_handle);
        if (error != 0) {
            return KERN_FAILURE;
        }
        g_vfs_handle = NULL;
    }
    return KERN_SUCCESS;
}
