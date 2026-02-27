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
    ["xlarge-manyfiles"]="10737418240:many:250000"
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

    if [ $missing -eq 1 ]; then
        return 1
    fi

    echo -e "${GREEN}All prerequisites met${NC}"
    return 0
}

# Create semi-compressible data file
# Uses a mix of random and repeated data to achieve moderate compression
# Optimized: generates seed pool then copies data to reach target size
# Usage: create_semi_compressible_file <filename> <size_bytes>
create_semi_compressible_file() {
    local filename="$1"
    local target_size="$2"

    echo "  Creating semi-compressible file ($((target_size / 1024 / 1024)) MiB)..."

    local block_size=$((1024 * 1024))  # 1 MiB blocks

    # Determine seed pool size (100 MiB for files > 500 MiB, otherwise 20% of target)
    local seed_size
    if [ "$target_size" -gt 524288000 ]; then
        seed_size=$((100 * 1024 * 1024))  # 100 MiB seed for large files
    else
        seed_size=$((target_size / 5))  # 20% for smaller files
        if [ "$seed_size" -lt $((10 * 1024 * 1024)) ]; then
            seed_size=$((10 * 1024 * 1024))  # Minimum 10 MiB seed
        fi
        if [ "$seed_size" -gt "$target_size" ]; then
            seed_size="$target_size"
        fi
    fi

    local seed_blocks=$((seed_size / block_size))

    echo "  Generating seed pool ($((seed_size / 1024 / 1024)) MiB)..."

    # Create the file and generate seed pool
    > "$filename"

    for ((i = 0; i < seed_blocks; i++)); do
        # Alternate between random and semi-predictable data
        if ((i % 4 == 0)); then
            # Every 4th block is random
            dd if=/dev/urandom bs="$block_size" count=1 2>/dev/null >> "$filename"
        else
            # Other blocks are semi-compressible (repeated patterns with variation)
            dd if=/dev/urandom bs=256 count=1 2>/dev/null | \
                head -c 256 | \
                perl -e 'my $p = <STDIN>; print $p x 4096;' | \
                head -c "$block_size" >> "$filename"
        fi
    done

    local current_size
    current_size=$(stat -c%s "$filename")

    # If target size is larger than seed, replicate data by copying from file itself
    if [ "$current_size" -lt "$target_size" ]; then
        echo "  Extending file by copying seed data..."

        while [ "$current_size" -lt "$target_size" ]; do
            local remaining=$((target_size - current_size))
            local copy_size="$current_size"

            # Don't copy more than we need
            if [ "$copy_size" -gt "$remaining" ]; then
                copy_size="$remaining"
            fi

            # Copy data from beginning of file to end
            dd if="$filename" bs="$block_size" count=$((copy_size / block_size)) 2>/dev/null >> "$filename"

            # Handle any remaining bytes
            local copied_bytes=$((copy_size / block_size * block_size))
            if [ "$copied_bytes" -lt "$copy_size" ]; then
                dd if="$filename" bs=1 skip="$copied_bytes" count=$((copy_size - copied_bytes)) 2>/dev/null >> "$filename"
            fi

            current_size=$(stat -c%s "$filename")

            # Progress report for large files
            if [ "$target_size" -gt 1073741824 ]; then
                echo "    Progress: $((current_size / 1024 / 1024)) / $((target_size / 1024 / 1024)) MiB"
            fi
        done
    fi

    # Ensure exact size
    truncate -s "$target_size" "$filename"

    local actual_size
    actual_size=$(stat -c%s "$filename")
    echo "  Created file: $((actual_size / 1024 / 1024)) MiB"
}

# Create compressible file using dictionary words
# Usage: create_compressible_file <filename> <size_bytes>
create_compressible_file() {
    local filename="$1"
    local target_size="$2"

    > "$filename"
    while [ "$(stat -c%s "$filename")" -lt "$target_size" ]; do
        local words
        words=$(shuf -n 100 /usr/share/dict/words 2>/dev/null) || \
            words="Lorem ipsum dolor sit amet consectetur adipiscing elit"
        printf '%s ' $words >> "$filename"
    done
    truncate -s "$target_size" "$filename"
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
    create_semi_compressible_file "$input_dir/data.bin" "$target_size"

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
# Optimized: creates template files and hardlinks them to reduce generation time
# Usage: create_many_files_archive <name> <target_size_bytes> <file_count>
create_many_files_archive() {
    local name="$1"
    local target_size="$2"
    local file_count="$3"

    echo ""
    echo -e "${BLUE}--- Creating $name archive ($file_count files, ~$((target_size / 1024 / 1024)) MiB) ---${NC}"

    local work_dir="$TEMP_DIR/$name"
    local input_dir="$work_dir/input"
    local template_dir="$work_dir/templates"
    local archive_file="$work_dir/archive.zip"

    mkdir -p "$input_dir"
    mkdir -p "$template_dir"

    # Calculate target file size (with some variation)
    local avg_file_size=$((target_size / file_count))
    local min_file_size=$((avg_file_size / 2))
    local max_file_size=$((avg_file_size * 3 / 2))

    # Determine number of template files to create
    # Use 1-2% of total files as templates, minimum 50, maximum 500
    local template_count=$((file_count / 75))
    if [ "$template_count" -lt 50 ]; then
        template_count=50
    fi
    if [ "$template_count" -gt 500 ]; then
        template_count=500
    fi
    if [ "$template_count" -gt "$file_count" ]; then
        template_count="$file_count"
    fi

    echo "Creating $template_count template files (will hardlink to create $file_count total files)..."

    # Create template files
    local templates=()
    for ((i = 0; i < template_count; i++)); do
        local file_size=$(random_size "$min_file_size" "$max_file_size")
        local template_file="$template_dir/template_$(printf "%04d" "$i").txt"

        create_compressible_file "$template_file" "$file_size"
        templates+=("$template_file")

        # Progress every 50 templates
        if (( i > 0 && i % 50 == 0 )); then
            echo "  Progress: $i/$template_count templates created..."
        fi
    done

    echo -e "${GREEN}Created $template_count template files${NC}"
    echo "Creating hardlinks to generate $file_count files..."

    # Distribute files across subdirectories (100 files per directory)
    local files_per_dir=100
    local num_dirs=$(( (file_count + files_per_dir - 1) / files_per_dir ))
    local created=0
    local total_size=0

    for ((dir_idx = 0; dir_idx < num_dirs; dir_idx++)); do
        local subdir="$input_dir/dir_$(printf "%04d" "$dir_idx")"
        mkdir -p "$subdir"

        for ((file_idx = 0; file_idx < files_per_dir && created < file_count; file_idx++)); do
            local filename="$subdir/file_$(printf "%06d" "$created").txt"

            # Randomly select a template to hardlink
            local template_idx=$((RANDOM % template_count))
            local template_file="${templates[$template_idx]}"

            ln "$template_file" "$filename"

            local file_size
            file_size=$(stat -c%s "$filename")
            total_size=$((total_size + file_size))
            created=$((created + 1))
        done

        # Progress every 50 directories
        if (( (dir_idx + 1) % 50 == 0 )); then
            echo "  Progress: $created/$file_count files created ($((total_size / 1024 / 1024)) MiB)..."
        fi
    done

    echo -e "${GREEN}Created $created files ($((total_size / 1024 / 1024)) MiB uncompressed)${NC}"

    # Clean up template directory
    rm -rf "$template_dir"

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

# Cleanup on exit
cleanup() {
    echo ""
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT

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
