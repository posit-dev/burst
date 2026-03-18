#!/bin/bash
#
# BTRFS initialization script for BURST performance tests (regular user)
#
# This script creates a BTRFS filesystem with zstd compression enabled,
# and configures the test to run burst-downloader as a regular user.
#
# Running as a regular user prevents burst-downloader from using
# BTRFS_IOC_ENCODED_WRITE, which requires elevated privileges.
# This tests standard file write performance on BTRFS.
#
# When sourced, this script exports:
#   BURST_OUTPUT_DIR   - Directory for burst-downloader output
#   BTRFS_LOOP_DEVICE  - The loop device path
#   BTRFS_LOOP_IMAGE   - Path to the loop device image file
#
# Usage:
#   source setup_btrfs_user.sh
#

set -e

echo "=== BTRFS Setup (regular user) ==="

# Configuration
BTRFS_SIZE_GB=100
BTRFS_MOUNT_DIR="/mnt/burst-perf-btrfs-user"
BTRFS_LOOP_IMAGE="/tmp/btrfs-perf-user.img"

# Check if BTRFS is already mounted
if mountpoint -q "$BTRFS_MOUNT_DIR" 2>/dev/null; then
    fstype=$(stat -f -c %T "$BTRFS_MOUNT_DIR" 2>/dev/null || echo "unknown")
    if [ "$fstype" = "btrfs" ]; then
        echo "BTRFS already mounted at $BTRFS_MOUNT_DIR"
        BURST_OUTPUT_DIR="$BTRFS_MOUNT_DIR"
        export BURST_OUTPUT_DIR
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
sudo mkfs.btrfs -f -L "burst-perf-user" "$BTRFS_LOOP_DEVICE" >/dev/null 2>&1

# Create mount point
sudo mkdir -p "$BTRFS_MOUNT_DIR"

# Mount with zstd compression
echo "Mounting BTRFS with zstd compression..."
sudo mount -o compress=zstd "$BTRFS_LOOP_DEVICE" "$BTRFS_MOUNT_DIR"

# Change ownership to ubuntu user
sudo chown -R ubuntu:ubuntu "$BTRFS_MOUNT_DIR"

# Show filesystem info
echo ""
echo "Filesystem information:"
df -h "$BTRFS_MOUNT_DIR"
echo ""
echo "BTRFS mount options:"
mount | grep "$BTRFS_MOUNT_DIR"

BURST_OUTPUT_DIR="$BTRFS_MOUNT_DIR"

echo ""
echo "BTRFS setup complete (regular user mode)."
echo "Output directory: $BURST_OUTPUT_DIR"
echo "Loop device: $BTRFS_LOOP_DEVICE"
echo "burst-downloader will run as regular user (BTRFS_IOC_ENCODED_WRITE disabled)"

# Export for use by caller
export BURST_OUTPUT_DIR
export BTRFS_LOOP_DEVICE
export BTRFS_LOOP_IMAGE
