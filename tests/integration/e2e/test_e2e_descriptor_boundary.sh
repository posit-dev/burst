#!/bin/bash
#
# End-to-End Test: Data Descriptor Pushed Past a Part Boundary
#
# Tests:
#   - A file whose compressed data ends 24-67 bytes before the 8 MiB boundary, so the writer pads
#     to the boundary and writes a Start-of-Part frame there, and only the data descriptor lands
#     in the next part
#   - More files following in that next part
#   - The downloader treating that part as continuing the file, then reading the next local header
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=e2e_common.sh
source "$SCRIPT_DIR/e2e_common.sh"

# shellcheck source=setup_btrfs.sh
source "$SCRIPT_DIR/setup_btrfs.sh"

TEST_NAME="E2E Data Descriptor Past Part Boundary"
TEST_ID="descriptor-boundary-$(date +%s)"
TEST_WORK_DIR="$E2E_TMP_DIR/test_descriptor_boundary_$TEST_ID"
S3_KEY="${BURST_TEST_KEY_PREFIX}${TEST_ID}.zip"

PART_SIZE=$((8 * 1024 * 1024))
# Bytes between the end of the file's data and the boundary. The writer pads when fewer than
# 68 bytes remain (descriptor + padding LFH + skippable frame header) and the last frame needs 24.
TARGET_GAP=40
# Long enough that an estimate of 30 + compressed size + 16 bytes falls short of the boundary.
BOUNDARY_FILE="descriptor_boundary_$(printf 'x%.0s' $(seq 1 80)).bin"

S3_UPLOADED=""
TEST_EXIT_CODE=0

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        TEST_EXIT_CODE=$exit_code
    fi

    echo ""
    echo "Cleaning up..."

    if [ -d "$TEST_WORK_DIR" ]; then
        rm -rf "$TEST_WORK_DIR"
        echo -e "${GREEN}✓${NC} Removed test directory"
    fi

    if [ -d "$BTRFS_MOUNT_DIR/extracted_$TEST_ID" ]; then
        rm -rf "$BTRFS_MOUNT_DIR/extracted_$TEST_ID"
        echo -e "${GREEN}✓${NC} Removed extracted files"
    fi

    if [ $TEST_EXIT_CODE -eq 0 ] && [ -n "$S3_UPLOADED" ]; then
        delete_from_s3 "$S3_KEY"
        echo -e "${GREEN}✓${NC} Removed S3 object"
    elif [ -n "$S3_UPLOADED" ]; then
        echo -e "${YELLOW}Note:${NC} Leaving S3 object for debugging: s3://$BURST_TEST_BUCKET/$S3_KEY"
    fi
}

trap cleanup EXIT

# Prints "hit" when the archive has a Start-of-Part frame at the first boundary immediately followed
# by the boundary file's data descriptor and then the next file's local header. Otherwise prints the
# offset of the boundary file's data descriptor, which is where its data ends when no padding follows.
inspect_archive() {
    python3 -I - "$1" "$BOUNDARY_FILE" "$PART_SIZE" <<'EOF'
import struct, sys, zipfile
path, name, ps = sys.argv[1], sys.argv[2], int(sys.argv[3])
info = zipfile.ZipFile(path).getinfo(name)
data = open(path, "rb").read()
nlen, xlen = struct.unpack_from("<HH", data, info.header_offset + 26)
data_start = info.header_offset + 30 + nlen + xlen
desc = struct.pack("<II", 0x08074B50, info.CRC)
desc_at = data.find(desc, data_start)
if desc_at < 0:
    sys.exit(f"no data descriptor for {name}")
magic, size, kind = struct.unpack_from("<IIB", data, ps)
if magic == 0x184D2A5B and size == 16 and kind == 1 and desc_at == ps + 24:
    (offset,) = struct.unpack_from("<Q", data, ps + 9)
    if offset != info.file_size:
        sys.exit(f"Start-of-Part offset {offset} != file size {info.file_size}")
    after = desc_at + 16
    if data[after:after + 4] != b"PK\x03\x04":
        sys.exit(f"no local header after the data descriptor at {after}")
    print("hit")
else:
    print(desc_at)
EOF
}

print_test_header "$TEST_NAME"

if ! check_prerequisites; then
    exit 1
fi

echo "Test configuration:"
echo "  Boundary file: data ends ~$TARGET_GAP bytes before the 8 MiB boundary"
echo "  S3 Bucket:     $BURST_TEST_BUCKET"
echo "  S3 Key:        $S3_KEY"
echo "  BTRFS Mount:   $BTRFS_MOUNT_DIR"
echo ""

mkdir -p "$TEST_WORK_DIR/input"
cd "$TEST_WORK_DIR"

echo "Step 1: Creating test files..."
create_test_file "random_pool.bin" "$PART_SIZE"
create_test_file "input/after.bin" $((3 * 1024 * 1024))
echo "small file after the boundary" > input/tail.txt
echo -e "${GREEN}✓${NC} Created random data"

# Step 2: size the boundary file. Random data doesn't compress, so each input byte adds one output
# byte; the second pass absorbs small changes such as a wider zstd frame content size field.
echo ""
echo "Step 2: Sizing the boundary file so only its data descriptor crosses the boundary..."
file_size=$((PART_SIZE - 65536))
hit=""
for attempt in 1 2 3 4 5; do
    head -c "$file_size" random_pool.bin > "input/$BOUNDARY_FILE"
    rm -f test.zip
    (cd input && "$BURST_WRITER" -l 3 -o ../test.zip "$BOUNDARY_FILE" after.bin tail.txt > /dev/null)
    result=$(inspect_archive test.zip)
    if [ "$result" = "hit" ]; then
        hit="yes"
        break
    fi
    data_end="$result"
    echo "  attempt $attempt: size $file_size, data ends $((PART_SIZE - data_end)) bytes before the boundary"
    file_size=$((file_size + PART_SIZE - TARGET_GAP - data_end))
done

if [ -z "$hit" ]; then
    echo -e "${RED}✗ Could not produce the descriptor-past-boundary layout${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Boundary file of $file_size bytes: Start-of-Part frame at the boundary, then its data descriptor, then the next local header"

store_checksums "input" "checksums_original.txt"

if ! verify_archive "test.zip"; then
    exit 1
fi
echo -e "${GREEN}✓${NC} Archive valid (7zz t)"

if ! verify_alignment "test.zip"; then
    exit 1
fi
echo -e "${GREEN}✓${NC} Alignment verified"

echo ""
echo "Step 3: Uploading to S3..."
if ! upload_to_s3 "test.zip" "$S3_KEY"; then
    exit 1
fi
S3_UPLOADED="yes"

echo ""
echo "Step 4: Downloading and extracting..."
EXTRACT_DIR="$BTRFS_MOUNT_DIR/extracted_$TEST_ID"
mkdir -p "$EXTRACT_DIR"

"$BURST_DOWNLOADER" \
    --bucket "$BURST_TEST_BUCKET" \
    --key "$S3_KEY" \
    --region "$AWS_REGION" \
    ${BURST_TEST_ENDPOINT:+--endpoint "$BURST_TEST_ENDPOINT"} \
    --output-dir "$EXTRACT_DIR"
echo -e "${GREEN}✓${NC} Download completed"

echo ""
echo "Step 5: Verifying file integrity..."
if ! verify_checksums "$EXTRACT_DIR" "checksums_original.txt"; then
    exit 1
fi
echo -e "${GREEN}✓${NC} All files extracted correctly"

print_test_result "$TEST_NAME" 0
exit 0
