#!/bin/bash
#
# Create performance test archives for BURST benchmarking
#
# Creates test archives at various sizes and uploads them to S3.
# Each archive is uploaded both as a complete ZIP and as individual files
# to enable future comparison testing with non-BURST tools.
#
# S3 Layout:
#   perf-test-{size}/archive.zip       - The BURST archive
#   perf-test-{size}/files/*           - Individual files (preserving structure)
#
# Archive sizes:
#   verysmall     - 5-6 MiB (single part)
#   small         - 40 MiB
#   medium        - 250 MiB (single large file)
#   medium-manyfiles - 250 MiB (~5000 files)
#   large         - 1 GiB (single large file)
#   large-manyfiles  - 1 GiB (~10000 files)
#   xlarge        - 10 GiB (single large file)
#   xlarge-manyfiles - 10 GiB (~25000 files)
#   xxlarge       - 50 GiB (single large file)
#
# Content Generation:
#   All content files are derived from a 200 MiB calibrated seed generated once
#   at startup. The seed is built by interleaving 32 KiB blocks of shuffled
#   dictionary words (compressible) and /dev/urandom (incompressible) at a
#   ratio tuned so the resulting burst-writer archive is 45-65% of the logical
#   size. Files <= 200 MiB take a random section of the seed; larger files
#   concatenate seed copies. This ensures S3 download benchmarks reflect
#   realistic data volumes.
#
# Usage:
#   ./create_perf_test_archives.sh [archive_name...]
#
#   If no archive names are specified, all archives are created.
#   Specify one or more names to create only those archives.
#
# Prerequisites:
#   - burst-writer built in build/
#   - aws CLI configured with appropriate credentials
#   - 7zz installed for archive validation
#   - /usr/share/dict/words for compressible content generation
#
# Environment variables:
#   BURST_PERF_BUCKET  - S3 bucket for test archives (default: burst-performance-tests)
#   AWS_REGION         - AWS region (default: us-west-2)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
BURST_WRITER="$BUILD_DIR/burst-writer"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration from .env if present
if [ -f "$PROJECT_ROOT/.env" ]; then
    echo "Loading configuration from .env..."
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/.env"
fi

# Set defaults
: "${BURST_PERF_BUCKET:=burst-performance-tests}"
: "${AWS_REGION:=us-west-2}"

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}BURST Performance Test Archive Creation${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Configuration:"
echo "  S3 Bucket: $BURST_PERF_BUCKET"
echo "  AWS Region: $AWS_REGION"
echo ""

# Archive configurations: name, target_size_bytes, type (single|many), file_count (for many)
declare -A ARCHIVE_CONFIGS=(
    ["verysmall"]="5242880:single:1"           # 5 MiB
    ["small"]="41943040:single:1"              # 40 MiB
    ["medium"]="262144000:single:1"            # 250 MiB
    ["medium-manyfiles"]="262144000:many:5000"
    ["large"]="1073741824:single:1"            # 1 GiB
    ["large-manyfiles"]="1073741824:many:10000"
    ["xlarge"]="10737418240:single:1"          # 10 GiB
    ["xlarge-manyfiles"]="10737418240:many:300000"
    ["xxlarge"]="53687091200:single:1"         # 50 GiB
)

# All archive names in order
ALL_ARCHIVES=(
    "verysmall"
    "small"
    "medium"
    "medium-manyfiles"
    "large"
    "large-manyfiles"
    "xlarge"
    "xlarge-manyfiles"
    "xxlarge"
)

# Check prerequisites
check_prerequisites() {
    local missing=0

    if [ ! -f "$BURST_WRITER" ]; then
        echo -e "${RED}Error: burst-writer not found at $BURST_WRITER${NC}"
        echo "  Run: cd $BUILD_DIR && make burst-writer"
        missing=1
    fi

    if ! command -v aws &> /dev/null; then
        echo -e "${RED}Error: aws CLI not found${NC}"
        missing=1
    fi

    if ! command -v 7zz &> /dev/null; then
        echo -e "${RED}Error: 7zz not found${NC}"
        echo "  Required for archive validation"
        missing=1
    fi

    if [ ! -s /usr/share/dict/words ]; then
        echo -e "${RED}Error: /usr/share/dict/words not found or empty${NC}"
        echo "  Required for generating compressible content"
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        return 1
    fi

    echo -e "${GREEN}All prerequisites met${NC}"
    return 0
}

# Generate 200 MiB blob of shuffled dictionary words
# Output written to $DICT_BLOB
generate_dict_blob() {
    local target_size=$((200 * 1024 * 1024))
    echo "Generating 200 MiB dictionary word blob..."
    > "$DICT_BLOB"
    while [ "$(stat -c%s "$DICT_BLOB")" -lt "$target_size" ]; do
        shuf /usr/share/dict/words | tr '\n' ' ' >> "$DICT_BLOB"
    done
    truncate -s "$target_size" "$DICT_BLOB"
    echo "  Done: $(( $(stat -c%s "$DICT_BLOB") / 1024 / 1024 )) MiB"
}

# Generate a mixed-content file by interleaving 32 KiB dict and random blocks
# Usage: generate_mixed_file <filename> <size_bytes> <dict_pct>
#   dict_pct: integer 0-100, percentage of blocks sourced from DICT_BLOB
generate_mixed_file() {
    local filename="$1"
    local size_bytes="$2"
    local dict_pct="$3"

    local block_size=32768  # 32 KiB
    local num_blocks=$(( size_bytes / block_size ))
    local dict_total_blocks=$(( 200 * 1024 * 1024 / block_size ))  # 6400 blocks
    local dict_idx=0

    > "$filename"

    for (( i = 0; i < num_blocks; i++ )); do
        if (( RANDOM % 100 < dict_pct )); then
            dd if="$DICT_BLOB" bs="$block_size" skip="$dict_idx" count=1 2>/dev/null >> "$filename"
            dict_idx=$(( (dict_idx + 1) % dict_total_blocks ))
        else
            dd if=/dev/urandom bs="$block_size" count=1 2>/dev/null >> "$filename"
        fi
    done

    truncate -s "$size_bytes" "$filename"
}

# Run burst-writer on a file and return archive_size * 100 / input_size
# Usage: ratio=$(measure_burst_compression_ratio <file>)
measure_burst_compression_ratio() {
    local input_file="$1"
    local input_size
    input_size=$(stat -c%s "$input_file")

    local measure_dir="$TEMP_DIR/measure_$$"
    local measure_input="$measure_dir/input"
    local measure_archive="$measure_dir/archive.zip"
    mkdir -p "$measure_input"

    ln "$input_file" "$measure_input/data.bin"
    "$BURST_WRITER" -l 3 -o "$measure_archive" "$measure_input" &>/dev/null

    local archive_size
    archive_size=$(stat -c%s "$measure_archive")

    rm -rf "$measure_dir"

    echo $(( archive_size * 100 / input_size ))
}

# Calibrate CALIBRATED_SEED by adjusting CALIBRATED_DICT_PCT until burst-writer
# produces an archive that is 45-65% of the input size.
calibrate_seed() {
    local seed_size=$((200 * 1024 * 1024))
    echo "Calibrating seed for target compression ratio (45-65%)..."

    for (( attempt = 0; attempt < 8; attempt++ )); do
        echo "  Attempt $((attempt + 1)): dict_pct=$CALIBRATED_DICT_PCT"
        echo "  Generating 200 MiB mixed seed..."
        generate_mixed_file "$CALIBRATED_SEED" "$seed_size" "$CALIBRATED_DICT_PCT"

        echo "  Measuring compression ratio..."
        local ratio
        ratio=$(measure_burst_compression_ratio "$CALIBRATED_SEED")
        echo "  Compression ratio: ${ratio}% (archive/input)"

        if (( ratio >= 45 && ratio <= 65 )); then
            echo -e "${GREEN}  Calibration successful: ratio=${ratio}%, dict_pct=${CALIBRATED_DICT_PCT}${NC}"
            return 0
        elif (( ratio < 45 )); then
            # Too compressible — reduce dict content, add more random data
            CALIBRATED_DICT_PCT=$(( CALIBRATED_DICT_PCT - 15 ))
        else
            # Not compressible enough — add more dict content
            CALIBRATED_DICT_PCT=$(( CALIBRATED_DICT_PCT + 15 ))
        fi

        # Clamp to [5, 95]
        if (( CALIBRATED_DICT_PCT < 5 )); then
            CALIBRATED_DICT_PCT=5
        fi
        if (( CALIBRATED_DICT_PCT > 95 )); then
            CALIBRATED_DICT_PCT=95
        fi
    done

    echo -e "${YELLOW}Warning: Could not achieve 45-65% ratio after 8 attempts. Using dict_pct=${CALIBRATED_DICT_PCT}${NC}"
}

# Create a content file derived from the calibrated seed
# Files <= 200 MiB: extract a random 512-byte-aligned section
# Files > 200 MiB: concatenate seed copies + partial remainder
# Usage: create_content_file <filename> <size_bytes>
create_content_file() {
    local filename="$1"
    local size_bytes="$2"

    local seed_size=$((200 * 1024 * 1024))

    if (( size_bytes <= seed_size )); then
        local max_offset=$(( seed_size - size_bytes ))
        local offset=0
        if (( max_offset > 512 )); then
            local max_offset_blocks=$(( max_offset / 512 ))
            offset=$(( (RANDOM * 32768 + RANDOM) % max_offset_blocks * 512 ))
        fi
        dd if="$CALIBRATED_SEED" iflag=skip_bytes,count_bytes \
            skip="$offset" count="$size_bytes" bs=65536 of="$filename" 2>/dev/null
    else
        > "$filename"
        local written=0
        while (( written + seed_size <= size_bytes )); do
            cat "$CALIBRATED_SEED" >> "$filename"
            written=$(( written + seed_size ))
        done
        local remaining=$(( size_bytes - written ))
        if (( remaining > 0 )); then
            head -c "$remaining" "$CALIBRATED_SEED" >> "$filename"
        fi
        truncate -s "$size_bytes" "$filename"
    fi
}

# Generate random lowercase string
random_string() {
    local length="$1"
    tr -dc 'a-z' < /dev/urandom | head -c "$length"
}

# Generate random size between min and max
# Usage: random_size <min_bytes> <max_bytes>
random_size() {
    local min="$1"
    local max="$2"
    echo $(( (RANDOM * 32768 + RANDOM) % (max - min) + min ))
}

# Create single-file archive
# Usage: create_single_file_archive <name> <target_size_bytes>
create_single_file_archive() {
    local name="$1"
    local target_size="$2"

    echo ""
    echo -e "${BLUE}--- Creating $name archive (single file, $((target_size / 1024 / 1024)) MiB) ---${NC}"

    local work_dir="$TEMP_DIR/$name"
    local input_dir="$work_dir/input"
    local archive_file="$work_dir/archive.zip"

    mkdir -p "$input_dir"

    # Create single large file
    echo "  Creating content file ($((target_size / 1024 / 1024)) MiB)..."
    create_content_file "$input_dir/data.bin" "$target_size"
    echo "  Created file: $(($(stat -c%s "$input_dir/data.bin") / 1024 / 1024)) MiB"

    # Create BURST archive
    echo "Creating BURST archive..."
    "$BURST_WRITER" -l 3 -o "$archive_file" "$input_dir"

    local archive_size
    archive_size=$(stat -c%s "$archive_file")
    local part_count=$(( (archive_size + 8388607) / 8388608 ))
    echo -e "${GREEN}Created archive: $((archive_size / 1024 / 1024)) MiB ($part_count parts)${NC}"

    # Verify archive with 7zz
    echo "Verifying archive..."
    if ! 7zz t "$archive_file" 2>&1 | grep -q "Everything is Ok"; then
        echo -e "${RED}Archive validation failed${NC}"
        7zz t "$archive_file"
        return 1
    fi
    echo -e "${GREEN}Archive validation passed${NC}"

    # Upload archive to S3
    echo "Uploading archive to S3..."
    if ! aws s3 cp "$archive_file" "s3://$BURST_PERF_BUCKET/perf-test-$name/archive.zip" \
        --region "$AWS_REGION" >/dev/null; then
        echo -e "${RED}Failed to upload archive${NC}"
        return 1
    fi
    echo -e "${GREEN}Uploaded s3://$BURST_PERF_BUCKET/perf-test-$name/archive.zip${NC}"

    # Upload individual files to S3 (preserving structure)
    echo "Uploading individual files to S3..."
    if ! aws s3 sync "$input_dir" "s3://$BURST_PERF_BUCKET/perf-test-$name/files/" \
        --region "$AWS_REGION" >/dev/null; then
        echo -e "${RED}Failed to upload individual files${NC}"
        return 1
    fi
    echo -e "${GREEN}Uploaded individual files to s3://$BURST_PERF_BUCKET/perf-test-$name/files/${NC}"

    echo -e "${GREEN}$name archive complete${NC}"
}

# Create many-files archive
# Each file is generated from a unique section of the calibrated seed.
# Usage: create_many_files_archive <name> <target_size_bytes> <file_count>
create_many_files_archive() {
    local name="$1"
    local target_size="$2"
    local file_count="$3"

    echo ""
    echo -e "${BLUE}--- Creating $name archive ($file_count files, ~$((target_size / 1024 / 1024)) MiB) ---${NC}"

    local work_dir="$TEMP_DIR/$name"
    local input_dir="$work_dir/input"
    local archive_file="$work_dir/archive.zip"

    mkdir -p "$input_dir"

    # Calculate target file size (with some variation)
    local avg_file_size=$((target_size / file_count))
    local min_file_size=$((avg_file_size / 2))
    local max_file_size=$((avg_file_size * 3 / 2))

    # Distribute files across subdirectories (100 files per directory)
    local files_per_dir=100
    local num_dirs=$(( (file_count + files_per_dir - 1) / files_per_dir ))
    local created=0
    local total_size=0

    echo "Creating $file_count content files (avg $((avg_file_size / 1024)) KiB each)..."

    for ((dir_idx = 0; dir_idx < num_dirs; dir_idx++)); do
        local subdir="$input_dir/dir_$(printf "%04d" "$dir_idx")"
        mkdir -p "$subdir"

        for ((file_idx = 0; file_idx < files_per_dir && created < file_count; file_idx++)); do
            local filename="$subdir/file_$(printf "%06d" "$created").bin"
            local file_size
            file_size=$(random_size "$min_file_size" "$max_file_size")

            create_content_file "$filename" "$file_size"

            total_size=$((total_size + file_size))
            created=$((created + 1))
        done

        # Progress every 50 directories
        if (( (dir_idx + 1) % 50 == 0 )); then
            echo "  Progress: $created/$file_count files created ($((total_size / 1024 / 1024)) MiB)..."
        fi
    done

    echo -e "${GREEN}Created $created files ($((total_size / 1024 / 1024)) MiB uncompressed)${NC}"

    # Create BURST archive
    echo "Creating BURST archive..."
    "$BURST_WRITER" -l 3 -o "$archive_file" "$input_dir"

    local archive_size
    archive_size=$(stat -c%s "$archive_file")
    local part_count=$(( (archive_size + 8388607) / 8388608 ))
    echo -e "${GREEN}Created archive: $((archive_size / 1024 / 1024)) MiB ($part_count parts)${NC}"

    # Verify archive with 7zz
    echo "Verifying archive..."
    if ! 7zz t "$archive_file" 2>&1 | grep -q "Everything is Ok"; then
        echo -e "${RED}Archive validation failed${NC}"
        7zz t "$archive_file"
        return 1
    fi
    echo -e "${GREEN}Archive validation passed${NC}"

    # Upload archive to S3
    echo "Uploading archive to S3..."
    if ! aws s3 cp "$archive_file" "s3://$BURST_PERF_BUCKET/perf-test-$name/archive.zip" \
        --region "$AWS_REGION" >/dev/null; then
        echo -e "${RED}Failed to upload archive${NC}"
        return 1
    fi
    echo -e "${GREEN}Uploaded s3://$BURST_PERF_BUCKET/perf-test-$name/archive.zip${NC}"

    # Upload individual files to S3 (preserving structure)
    echo "Uploading individual files to S3 (this may take a while for many files)..."
    if ! aws s3 sync "$input_dir" "s3://$BURST_PERF_BUCKET/perf-test-$name/files/" \
        --region "$AWS_REGION" >/dev/null; then
        echo -e "${RED}Failed to upload individual files${NC}"
        return 1
    fi
    echo -e "${GREEN}Uploaded individual files to s3://$BURST_PERF_BUCKET/perf-test-$name/files/${NC}"

    echo -e "${GREEN}$name archive complete${NC}"
}

# Create archive based on configuration
# Usage: create_archive <name>
create_archive() {
    local name="$1"
    local config="${ARCHIVE_CONFIGS[$name]}"

    if [ -z "$config" ]; then
        echo -e "${RED}Unknown archive: $name${NC}"
        return 1
    fi

    IFS=':' read -r target_size type file_count <<< "$config"

    if [ "$type" = "single" ]; then
        create_single_file_archive "$name" "$target_size"
    else
        create_many_files_archive "$name" "$target_size" "$file_count"
    fi
}

# Print usage
print_usage() {
    echo "Usage: $0 [archive_name...]"
    echo ""
    echo "Available archives:"
    for name in "${ALL_ARCHIVES[@]}"; do
        local config="${ARCHIVE_CONFIGS[$name]}"
        IFS=':' read -r size type count <<< "$config"
        local size_mb=$((size / 1024 / 1024))
        if [ "$type" = "single" ]; then
            echo "  $name - ${size_mb} MiB (single file)"
        else
            echo "  $name - ${size_mb} MiB (~$count files)"
        fi
    done
    echo ""
    echo "If no archive names are specified, all archives are created."
}

# Main execution
if ! check_prerequisites; then
    exit 1
fi

# Parse arguments
archives_to_create=()
if [ $# -eq 0 ]; then
    archives_to_create=("${ALL_ARCHIVES[@]}")
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    print_usage
    exit 0
else
    for arg in "$@"; do
        if [ -z "${ARCHIVE_CONFIGS[$arg]}" ]; then
            echo -e "${RED}Unknown archive: $arg${NC}"
            print_usage
            exit 1
        fi
        archives_to_create+=("$arg")
    done
fi

echo "Archives to create: ${archives_to_create[*]}"
echo ""

# Create temporary working directory
TEMP_DIR=$(mktemp -d)
echo "Working directory: $TEMP_DIR"

# Global paths for calibrated content generation
DICT_BLOB="$TEMP_DIR/dict_blob.bin"
CALIBRATED_SEED="$TEMP_DIR/calibrated_seed.bin"
CALIBRATED_DICT_PCT=50

# Cleanup on exit
cleanup() {
    echo ""
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT

# Generate calibrated seed once before creating any archives
echo ""
echo -e "${BLUE}--- Generating calibrated content seed ---${NC}"
generate_dict_blob
calibrate_seed
echo ""

# Create archives
for name in "${archives_to_create[@]}"; do
    create_archive "$name"

    # Clean up intermediate files after each archive to save disk space
    rm -rf "${TEMP_DIR:?}/$name"
done

# Print summary
echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${GREEN}Performance Test Archives Created${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Archives available at s3://$BURST_PERF_BUCKET/"
for name in "${archives_to_create[@]}"; do
    echo "  perf-test-$name/archive.zip"
    echo "  perf-test-$name/files/"
done
echo ""
