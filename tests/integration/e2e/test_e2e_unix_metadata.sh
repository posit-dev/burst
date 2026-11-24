#!/bin/bash
#
# End-to-End Test: Unix File Metadata (Permissions, Owner/Group, Symlinks, xattrs, mtimes)
#
# Tests:
#   - File permissions preservation through round-trip, including setuid/setgid on non-root-owned files
#   - uid/gid preservation (requires sudo for downloader)
#   - Symlink target preservation
#   - Extended attributes, including a file capability on a file spanning several parts
#   - mtimes of files and symlinks
#
# Requirements:
#   - sudo access (for BTRFS setup and running downloader with root privileges)
#   - AWS credentials configured
#   - S3 bucket available
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

# Source BTRFS setup
# shellcheck source=setup_btrfs.sh
source "$SCRIPT_DIR/setup_btrfs.sh"

# Test configuration
TEST_NAME="E2E Unix Metadata (permissions, uid/gid, symlinks, xattrs, mtimes)"
TEST_ID="unix-meta-$(date +%s)"
TEST_WORK_DIR="$E2E_TMP_DIR/test_unix_meta_$TEST_ID"
S3_KEY="${BURST_TEST_KEY_PREFIX}${TEST_ID}.zip"

# Tracking variables
S3_UPLOADED=""
TEST_EXIT_CODE=0

# Find a different uid/gid for testing ownership
# Use nobody:nogroup if available, otherwise use uid 65534
get_test_ownership() {
    if id nobody >/dev/null 2>&1; then
        TEST_UID=$(id -u nobody)
        TEST_GID=$(id -g nobody 2>/dev/null || echo "$TEST_UID")
    else
        TEST_UID=65534
        TEST_GID=65534
    fi
    export TEST_UID TEST_GID
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        TEST_EXIT_CODE=$exit_code
    fi

    echo ""
    echo "Cleaning up..."

    # Remove test files (may need sudo if owned by different user)
    if [ -d "$TEST_WORK_DIR" ]; then
        sudo rm -rf "$TEST_WORK_DIR" 2>/dev/null || rm -rf "$TEST_WORK_DIR"
        echo -e "${GREEN}OK${NC} Removed test directory"
    fi

    # Remove extracted files from BTRFS (may need sudo)
    if [ -d "$BTRFS_MOUNT_DIR/extracted_$TEST_ID" ]; then
        sudo rm -rf "$BTRFS_MOUNT_DIR/extracted_$TEST_ID" 2>/dev/null || rm -rf "$BTRFS_MOUNT_DIR/extracted_$TEST_ID"
        echo -e "${GREEN}OK${NC} Removed extracted files"
    fi

    # Only delete S3 object on success (leave for debugging on failure)
    if [ $TEST_EXIT_CODE -eq 0 ] && [ -n "$S3_UPLOADED" ]; then
        delete_from_s3 "$S3_KEY"
        echo -e "${GREEN}OK${NC} Removed S3 object"
    elif [ -n "$S3_UPLOADED" ]; then
        echo -e "${YELLOW}Note:${NC} Leaving S3 object for debugging: s3://$BURST_TEST_BUCKET/$S3_KEY"
    fi
}

trap cleanup EXIT

# Store original metadata for a file (permissions, uid, gid)
# Output format: "perms uid gid"
store_file_metadata() {
    local file="$1"
    stat -c "%a %u %g" "$file"
}

# Store symlink target
store_symlink_target() {
    local file="$1"
    readlink "$file"
}

# Verify file metadata matches expected
verify_file_metadata() {
    local file="$1"
    local expected="$2"  # "perms uid gid"

    local actual
    actual=$(store_file_metadata "$file")

    if [ "$actual" != "$expected" ]; then
        echo -e "${RED}FAIL${NC} Metadata mismatch for $file"
        echo "  Expected: $expected"
        echo "  Got:      $actual"
        return 1
    fi
    return 0
}

# Verify symlink target matches expected
verify_symlink_target() {
    local file="$1"
    local expected="$2"

    if [ ! -L "$file" ]; then
        echo -e "${RED}FAIL${NC} $file is not a symlink"
        return 1
    fi

    local actual
    actual=$(readlink "$file")

    if [ "$actual" != "$expected" ]; then
        echo -e "${RED}FAIL${NC} Symlink target mismatch for $file"
        echo "  Expected: $expected"
        echo "  Got:      $actual"
        return 1
    fi
    return 0
}

# Main test
print_test_header "$TEST_NAME"

# Check prerequisites
if ! check_prerequisites; then
    exit 1
fi

# Get test ownership values
get_test_ownership

echo "Test configuration:"
echo "  S3 Bucket:   $BURST_TEST_BUCKET"
echo "  S3 Key:      $S3_KEY"
echo "  AWS Region:  $AWS_REGION"
echo "  BTRFS Mount: $BTRFS_MOUNT_DIR"
echo "  Test UID:    $TEST_UID (for ownership test)"
echo "  Test GID:    $TEST_GID"
echo ""

# Create test workspace
mkdir -p "$TEST_WORK_DIR"
cd "$TEST_WORK_DIR"

# Step 1: Create test files with specific metadata
echo "Step 1: Creating test files with specific metadata..."
mkdir -p input

# Files with different permissions
echo "executable content" > input/exec_file.bin
chmod 0755 input/exec_file.bin

echo "secret content" > input/secret_file.txt
chmod 0600 input/secret_file.txt

echo "normal content" > input/normal_file.txt
chmod 0644 input/normal_file.txt

# File with different ownership (requires sudo)
echo "owned content" > input/owned_file.txt
chmod 0644 input/owned_file.txt
sudo chown "$TEST_UID:$TEST_GID" input/owned_file.txt

# Symlinks
echo "target content" > input/target.txt
chmod 0644 input/target.txt
ln -s target.txt input/relative_link.txt
ln -s ../input/target.txt input/path_link.txt

# setuid/setgid on files owned by a non-root user: chown after chmod would clear these bits
echo "setuid content" > input/setuid_file.bin
echo "setgid content" > input/setgid_file.bin
sudo chown "$TEST_UID:$TEST_GID" input/setuid_file.bin input/setgid_file.bin
sudo chmod 4755 input/setuid_file.bin
sudo chmod 2755 input/setgid_file.bin

# A file capability on a file spanning several 8 MiB parts: any write after setcap would clear it
head -c $((20 * 1024 * 1024)) /dev/urandom > input/large_cap.bin
sudo setcap 'cap_net_raw=ep' input/large_cap.bin
python3 -c 'import os, sys; os.setxattr(sys.argv[1], "user.burst_test", b"hello")' input/normal_file.txt

# Fixed mtimes, applied last so nothing above moves them
touch -d '2001-02-03 04:05:06 UTC' input/exec_file.bin
touch -h -d '2002-03-04 05:06:07 UTC' input/relative_link.txt

echo -e "${GREEN}OK${NC} Created test files with metadata"

# Step 2: Store original metadata
echo ""
echo "Step 2: Storing original metadata..."

# Store permissions and ownership
META_EXEC=$(store_file_metadata input/exec_file.bin)
META_SECRET=$(store_file_metadata input/secret_file.txt)
META_NORMAL=$(store_file_metadata input/normal_file.txt)
META_OWNED=$(store_file_metadata input/owned_file.txt)
META_TARGET=$(store_file_metadata input/target.txt)
META_SETUID=$(store_file_metadata input/setuid_file.bin)
META_SETGID=$(store_file_metadata input/setgid_file.bin)
CAPS_LARGE=$(getcap input/large_cap.bin | awk '{print $2}')
XATTR_NORMAL=$(python3 -c 'import os, sys; print(os.getxattr(sys.argv[1], "user.burst_test").decode())' input/normal_file.txt)
MTIME_EXEC=$(stat -c %Y input/exec_file.bin)
MTIME_LINK=$(stat -c %Y input/relative_link.txt)

# Store symlink targets
LINK_REL=$(store_symlink_target input/relative_link.txt)
LINK_PATH=$(store_symlink_target input/path_link.txt)

echo "  exec_file.bin:    $META_EXEC"
echo "  secret_file.txt:  $META_SECRET"
echo "  normal_file.txt:  $META_NORMAL"
echo "  owned_file.txt:   $META_OWNED"
echo "  relative_link.txt -> $LINK_REL"
echo "  path_link.txt -> $LINK_PATH"
echo "  setuid_file.bin:  $META_SETUID"
echo "  setgid_file.bin:  $META_SETGID"
echo "  large_cap.bin caps: $CAPS_LARGE"

# Also store checksums for content verification
store_checksums "input" "checksums_original.txt"
echo -e "${GREEN}OK${NC} Stored original metadata and checksums"

# Step 3: Create BURST archive
echo ""
echo "Step 3: Creating BURST archive..."
# Note: burst-writer needs to handle symlinks and preserve permissions
"$BURST_WRITER" -l 3 -o test.zip input/exec_file.bin input/secret_file.txt input/normal_file.txt input/owned_file.txt input/target.txt input/relative_link.txt input/path_link.txt input/setuid_file.bin input/setgid_file.bin input/large_cap.bin
archive_size=$(stat -c%s "test.zip")
echo -e "${GREEN}OK${NC} Created archive: test.zip ($archive_size bytes)"

# Verify archive is valid
if ! verify_archive "test.zip"; then
    echo -e "${RED}FAIL${NC} Archive validation failed"
    exit 1
fi
echo -e "${GREEN}OK${NC} Archive validation passed (7zz t)"

# Step 4: Upload to S3
echo ""
echo "Step 4: Uploading to S3..."
if ! upload_to_s3 "test.zip" "$S3_KEY"; then
    exit 1
fi
S3_UPLOADED="yes"

# Step 5: Download and extract with burst-downloader (as root to restore ownership)
echo ""
echo "Step 5: Downloading and extracting with burst-downloader (sudo)..."
EXTRACT_DIR="$BTRFS_MOUNT_DIR/extracted_$TEST_ID"
sudo mkdir -p "$EXTRACT_DIR"

# sudo-rs (Ubuntu 26.04+) ignores a bare -E, so list the variables the AWS credential chain reads.
# The config file paths are set explicitly because root's HOME is not the invoking user's.
AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-$HOME/.aws/config}" \
AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}" \
sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_SESSION_TOKEN,AWS_PROFILE,AWS_REGION,AWS_DEFAULT_REGION,AWS_CONFIG_FILE,AWS_SHARED_CREDENTIALS_FILE \
    "$BURST_DOWNLOADER" \
    --bucket "$BURST_TEST_BUCKET" \
    --key "$S3_KEY" \
    --region "$AWS_REGION" \
    ${BURST_TEST_ENDPOINT:+--endpoint "$BURST_TEST_ENDPOINT"} \
    --output-dir "$EXTRACT_DIR"

if [ $? -ne 0 ]; then
    echo -e "${RED}FAIL${NC} Download/extraction failed"
    exit 1
fi
echo -e "${GREEN}OK${NC} Download and extraction completed"

# Step 6: Verify file contents (checksums)
echo ""
echo "Step 6: Verifying file contents (checksums)..."
# Need to filter out symlinks from checksum verification since they aren't regular files
grep -v "link.txt" checksums_original.txt > checksums_files.txt
if ! verify_checksums "$EXTRACT_DIR" "checksums_files.txt"; then
    echo -e "${RED}FAIL${NC} Checksum verification failed"
    exit 1
fi
echo -e "${GREEN}OK${NC} All file checksums match"

# Step 7: Verify permissions
echo ""
echo "Step 7: Verifying file permissions..."
verify_file_metadata "$EXTRACT_DIR/exec_file.bin" "$META_EXEC" || exit 1
echo -e "  ${GREEN}OK${NC} exec_file.bin: $META_EXEC"

verify_file_metadata "$EXTRACT_DIR/secret_file.txt" "$META_SECRET" || exit 1
echo -e "  ${GREEN}OK${NC} secret_file.txt: $META_SECRET"

verify_file_metadata "$EXTRACT_DIR/normal_file.txt" "$META_NORMAL" || exit 1
echo -e "  ${GREEN}OK${NC} normal_file.txt: $META_NORMAL"

echo -e "${GREEN}OK${NC} All permissions preserved"

# Step 8: Verify ownership (uid/gid)
echo ""
echo "Step 8: Verifying file ownership (uid/gid)..."
verify_file_metadata "$EXTRACT_DIR/owned_file.txt" "$META_OWNED" || exit 1
echo -e "  ${GREEN}OK${NC} owned_file.txt: $META_OWNED"
echo -e "${GREEN}OK${NC} Ownership preserved"

# Step 9: Verify symlinks
echo ""
echo "Step 9: Verifying symlinks..."
verify_symlink_target "$EXTRACT_DIR/relative_link.txt" "$LINK_REL" || exit 1
echo -e "  ${GREEN}OK${NC} relative_link.txt -> $LINK_REL"

verify_symlink_target "$EXTRACT_DIR/path_link.txt" "$LINK_PATH" || exit 1
echo -e "  ${GREEN}OK${NC} path_link.txt -> $LINK_PATH"

echo -e "${GREEN}OK${NC} All symlinks preserved"

# Step 10: Verify setuid/setgid, xattrs and mtimes
echo ""
echo "Step 10: Verifying setuid/setgid, extended attributes and mtimes..."
verify_file_metadata "$EXTRACT_DIR/setuid_file.bin" "$META_SETUID" || exit 1
verify_file_metadata "$EXTRACT_DIR/setgid_file.bin" "$META_SETGID" || exit 1
echo -e "  ${GREEN}OK${NC} setuid_file.bin: $META_SETUID, setgid_file.bin: $META_SETGID"

actual_caps=$(getcap "$EXTRACT_DIR/large_cap.bin" | awk '{print $2}')
if [ "$actual_caps" != "$CAPS_LARGE" ]; then
    echo -e "${RED}FAIL${NC} large_cap.bin capabilities: expected '$CAPS_LARGE', got '$actual_caps'"
    exit 1
fi
echo -e "  ${GREEN}OK${NC} large_cap.bin caps: $actual_caps"

actual_xattr=$(sudo python3 -c 'import os, sys; print(os.getxattr(sys.argv[1], "user.burst_test").decode())' "$EXTRACT_DIR/normal_file.txt")
if [ "$actual_xattr" != "$XATTR_NORMAL" ]; then
    echo -e "${RED}FAIL${NC} normal_file.txt user.burst_test: expected '$XATTR_NORMAL', got '$actual_xattr'"
    exit 1
fi
echo -e "  ${GREEN}OK${NC} normal_file.txt user.burst_test=$actual_xattr"

for pair in "exec_file.bin:$MTIME_EXEC" "relative_link.txt:$MTIME_LINK"; do
    name=${pair%%:*}
    expected=${pair#*:}
    actual=$(stat -c %Y "$EXTRACT_DIR/$name")
    if [ "$actual" != "$expected" ]; then
        echo -e "${RED}FAIL${NC} $name mtime: expected $expected, got $actual"
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC} $name mtime: $actual"
done
echo -e "${GREEN}OK${NC} setuid/setgid, extended attributes and mtimes preserved"

# Success
print_test_result "$TEST_NAME" 0
exit 0
