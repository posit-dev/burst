#!/bin/bash
#
# BTRFS initialization script for BURST performance tests (root user)
#
# This script creates a BTRFS filesystem with zstd compression enabled,
# and configures the test to run burst-downloader as root.
#
# Running as root allows burst-downloader to use BTRFS_IOC_ENCODED_WRITE,
# which enables zero-copy passthrough of compressed data directly to disk.
#
# When sourced, this script exports:
#   BURST_OUTPUT_DIR   - Directory for burst-downloader output
#   BTRFS_LOOP_DEVICE  - The loop device path
#   BTRFS_LOOP_IMAGE   - Path to the loop device image file
#   BURST_RUN_AS_ROOT  - Flag indicating burst-downloader should run as root
#
# Usage:
#   source setup_btrfs_root.sh
#

set -e

echo "=== BTRFS Setup (root user) ==="

# Configuration
BTRFS_SIZE_GB=100
BTRFS_MOUNT_DIR="/mnt/burst-perf-btrfs-root"
BTRFS_LOOP_IMAGE="/tmp/btrfs-perf-root.img"

# Check if BTRFS is already mounted
if mountpoint -q "$BTRFS_MOUNT_DIR" 2>/dev/null; then
    fstype=$(stat -f -c %T "$BTRFS_MOUNT_DIR" 2>/dev/null || echo "unknown")
    if [ "$fstype" = "btrfs" ]; then
        echo "BTRFS already mounted at $BTRFS_MOUNT_DIR"
        BURST_OUTPUT_DIR="$BTRFS_MOUNT_DIR"
        export BURST_OUTPUT_DIR
        export BURST_RUN_AS_ROOT=1
        return 0 2>/dev/null || exit 0
    fi
fi

# Clean up any previous setup
if [ -f "$BTRFS_LOOP_IMAGE" ]; then
    # Find and detach any loop device using this image
    EXISTING_LOOP=$(losetup -j "$BTRFS_LOOP_IMAGE" | cut -d: -f1 || true)
    if [ -n "$EXISTING_LOOP" ]; then
        echo "Detaching existing loop device: $EXISTING_LOOP"
        sudo umount "$BTRFS_MOUNT_DIR" 2>/dev/null || true
        sudo losetup -d "$EXISTING_LOOP" 2>/dev/null || true
    fi
    rm -f "$BTRFS_LOOP_IMAGE"
fi

# Create sparse file for loop device
echo "Creating ${BTRFS_SIZE_GB} GiB sparse image file..."
dd if=/dev/zero of="$BTRFS_LOOP_IMAGE" bs=1M count=0 seek=$((BTRFS_SIZE_GB * 1024)) 2>/dev/null

# Set up loop device
echo "Setting up loop device..."
BTRFS_LOOP_DEVICE=$(sudo losetup -f --show "$BTRFS_LOOP_IMAGE")
echo "Loop device: $BTRFS_LOOP_DEVICE"

# Create BTRFS filesystem
echo "Creating BTRFS filesystem..."
sudo mkfs.btrfs -f -L "burst-perf-root" "$BTRFS_LOOP_DEVICE" >/dev/null 2>&1

# Create mount point
sudo mkdir -p "$BTRFS_MOUNT_DIR"

# Mount with zstd compression
echo "Mounting BTRFS with zstd compression..."
sudo mount -o compress=zstd "$BTRFS_LOOP_DEVICE" "$BTRFS_MOUNT_DIR"

# Keep ownership as root since burst-downloader will run as root
echo "Note: Directory owned by root (burst-downloader will run as root)"

# Show filesystem info
echo ""
echo "Filesystem information:"
df -h "$BTRFS_MOUNT_DIR"
echo ""
echo "BTRFS mount options:"
mount | grep "$BTRFS_MOUNT_DIR"

BURST_OUTPUT_DIR="$BTRFS_MOUNT_DIR"

echo ""
echo "BTRFS setup complete (root user mode)."
echo "Output directory: $BURST_OUTPUT_DIR"
echo "Loop device: $BTRFS_LOOP_DEVICE"
echo "burst-downloader will run as root (enables BTRFS_IOC_ENCODED_WRITE)"

# Export for use by caller
export BURST_OUTPUT_DIR
export BTRFS_LOOP_DEVICE
export BTRFS_LOOP_IMAGE
export BURST_RUN_AS_ROOT=1
