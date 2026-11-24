#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "cowfs_bridge.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef COWFS_CLI_KIND
#define COWFS_CLI_KIND COWFS_KIND_XFS
#endif

#ifndef COWFS_CLI_IS_MKFS
#define COWFS_CLI_IS_MKFS 1
#endif

int main(int argc, char **argv) {
    cowfs_kind_t kind = COWFS_CLI_KIND;
    const char *fs_name = (kind == COWFS_KIND_XFS) ? "XFS" : "Btrfs";

#if COWFS_CLI_IS_MKFS
    const char *label = (kind == COWFS_KIND_XFS) ? "MontserratXFS" : "MontserratBtrfs";
    uint32_t block_size = (kind == COWFS_KIND_XFS) ? 4096U : 16384U;
    const char *target = NULL;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if ((strcmp(a, "-L") == 0 || strcmp(a, "--label") == 0) && i + 1 < argc) {
            label = argv[++i];
        } else if ((strcmp(a, "-b") == 0 || strcmp(a, "-n") == 0 || strcmp(a, "--nodesize") == 0) && i + 1 < argc) {
            const char *val = argv[++i];
            if (strncmp(val, "size=", 5) == 0) val += 5;
            uint32_t parsed = (uint32_t)strtoul(val, NULL, 10);
            if (parsed >= 512U) block_size = parsed;
        } else if (strcmp(a, "-f") == 0 || strcmp(a, "-F") == 0 || strcmp(a, "-q") == 0) {
            /* Force / quiet flags accepted */
        } else if (strcmp(a, "--version") == 0 || strcmp(a, "-V") == 0) {
            printf("%s (%s formatter, Montserrat 1.1.0)\n", argv[0], fs_name);
            return 0;
        } else if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
            printf("Usage: %s [-f] [-L label] [-b size] <device|image>\n", argv[0]);
            return 0;
        } else if (a[0] != '-') {
            target = a;
        }
    }

    if (!target) {
        fprintf(stderr, "Usage: %s [-f] [-L label] [-b size] <device|image>\n", argv[0]);
        return 1;
    }

    int rc = cowfs_mkfs(kind, target, label, block_size);
    if (rc != 0) {
        fprintf(stderr, "%s: failed to format %s as %s: %s\n", argv[0], target, fs_name, strerror(-rc));
        return 1;
    }
    printf("Formatted %s as %s (label: \"%s\", size unit: %u bytes)\n", target, fs_name, label, block_size);
    return 0;
#else
    int auto_fix = 0;
    const char *target = NULL;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "-n") == 0 || strcmp(a, "--readonly") == 0) {
            auto_fix = 0;
        } else if (strcmp(a, "-p") == 0 || strcmp(a, "-y") == 0 || strcmp(a, "--repair") == 0) {
            auto_fix = 1;
        } else if (strcmp(a, "-f") == 0 || strcmp(a, "--force") == 0) {
            /* Force check even when clean */
        } else if (strcmp(a, "--version") == 0 || strcmp(a, "-V") == 0) {
            printf("%s (%s consistency checker, Montserrat 1.1.0)\n", argv[0], fs_name);
            return 0;
        } else if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
            printf("Usage: %s [-n | -p] [-f] <device|image>\n", argv[0]);
            return 0;
        } else if (a[0] != '-') {
            target = a;
        }
    }

    if (!target) {
        fprintf(stderr, "Usage: %s [-n | -p] [-f] <device|image>\n", argv[0]);
        return 1;
    }

    char report[1024];
    report[0] = '\0';
    int rc = cowfs_fsck(kind, target, auto_fix, report, sizeof(report));
    if (report[0]) {
        printf("%s\n", report);
    }
    if (rc < 0) {
        fprintf(stderr, "%s: %s check failed on %s: %s\n", argv[0], fs_name, target, strerror(-rc));
        return 4;
    }
    /* Exit code convention matching e2fsck: 0 = clean, 1 = errors corrected, 4 = uncorrected errors */
    return rc;
#endif
}
