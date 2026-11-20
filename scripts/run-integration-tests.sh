#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
MONTSERRAT_BIN="$HERE/dist/bin/montserrat"
MKE2FS_BIN="$HERE/engines/out/sbin/mke2fs"
MKE2FS_CONF="$HERE/engines/conf/mke2fs.conf"
MKNTFS_BIN="$HERE/engines/out/sbin/mkntfs"

echo "=========================================="
echo " Montserrat Disk Image Integration Tests"
echo "=========================================="

if [ ! -x "$MONTSERRAT_BIN" ]; then
    echo "==> Dist binary not found. Building release..."
    "$HERE/scripts/build.sh"
fi

TMP_DIR="$(mktemp -d -t montserrat_e2e)"
IMG_FILE="$TMP_DIR/test_disk.dmg"
DEV_NODE=""

cleanup() {
    local exit_code=$?
    if [ -n "$DEV_NODE" ]; then
        echo "==> Detaching virtual disk node $DEV_NODE..."
        hdiutil detach "$DEV_NODE" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
    if [ $exit_code -eq 0 ]; then
        echo "=========================================="
        echo " All Integration Tests Passed"
        echo "=========================================="
    else
        echo "=========================================="
        echo " Integration Tests Failed (exit code: $exit_code)"
        echo "=========================================="
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

echo "==> Step 1: Creating 32MB raw disk image..."
hdiutil create -size 32m -layout NONE -ov "$IMG_FILE" >/dev/null

echo "==> Step 2: Attaching virtual block device..."
ATTACH_OUT="$(hdiutil attach -nomount "$IMG_FILE")"
DEV_NODE="$(echo "$ATTACH_OUT" | awk '{print $1}')"
echo "    Attached node: $DEV_NODE"

RDEV="${DEV_NODE/disk/rdisk}"

echo "==> Step 3: Formatting as ext4 filesystem (label: E2E_EXT4)..."
MKE2FS_CONFIG="$MKE2FS_CONF" "$MKE2FS_BIN" -t ext4 -F -L "E2E_EXT4" "$RDEV" >/dev/null

echo "==> Step 4: Probing ext4 filesystem with montserrat CLI..."
PROBE_EXT4="$("$MONTSERRAT_BIN" probe "$DEV_NODE")"
echo "$PROBE_EXT4"
echo "$PROBE_EXT4" | grep -q "ext4"
echo "$PROBE_EXT4" | grep -q "E2E_EXT4"
echo "$PROBE_EXT4" | grep -q "Clean"

echo "==> Step 5: Formatting as NTFS filesystem (label: E2E_NTFS)..."
"$MKNTFS_BIN" -F -f -L "E2E_NTFS" "$DEV_NODE" >/dev/null

echo "==> Step 6: Probing NTFS filesystem with montserrat CLI..."
PROBE_NTFS="$("$MONTSERRAT_BIN" probe "$DEV_NODE")"
echo "$PROBE_NTFS"
echo "$PROBE_NTFS" | grep -q "NTFS"

echo "==> Step 7: Testing primary ext4 superblock corruption recovery..."
MKE2FS_CONFIG="$MKE2FS_CONF" "$MKE2FS_BIN" -t ext4 -F -L "BACKUP_REC" "$RDEV" >/dev/null
# Zero out the primary superblock located at byte offset 1024
dd if=/dev/zero of="$RDEV" bs=1024 count=1 seek=1 conv=notrunc >/dev/null 2>&1
PROBE_CORRUPT="$("$MONTSERRAT_BIN" probe "$DEV_NODE")"
echo "$PROBE_CORRUPT"
echo "$PROBE_CORRUPT" | grep -q "ext4"
echo "$PROBE_CORRUPT" | grep -q "BACKUP_REC"

echo "==> Step 8: Verifying safety policy blocks format on internal disk0..."
if "$MONTSERRAT_BIN" format /dev/disk0 --force >/dev/null 2>&1; then
    echo "Error: Safety policy failed to block internal disk format."
    exit 1
else
    echo "    Safety policy correctly rejected operation on /dev/disk0."
fi

echo "==> Step 9: Reconciling active mounts and teardown..."
hdiutil detach "$DEV_NODE" -force >/dev/null
DEV_NODE=""
