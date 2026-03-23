#!/bin/bash
#
# EC2 Test Runner Script for BURST Performance Tests
#
# This script runs on the EC2 instance and executes all performance tests.
# It is called after ec2_bootstrap.sh completes.
#
# The script:
#   1. Loads configuration from /opt/burst-perf/config.env
#   2. Runs the specified initialization script (setup_baseline.sh, setup_btrfs.sh, etc.)
#   3. For each archive, runs burst-downloader with /usr/bin/time
#   4. Collects metrics and appends to CSV file
#   5. Uploads results to S3
#   6. Shuts down the instance on completion or error
#
# Usage:
#   ./ec2_run_tests.sh
#
# The script expects the following files to exist:
#   /opt/burst-perf/config.env           - Configuration from bootstrap
#   /opt/burst-perf/bin/burst-downloader - The binary to test
#   /opt/burst-perf/scripts/init_scripts/ - Initialization scripts
#

set -e

PERF_DIR="/opt/burst-perf"
LOG_FILE="/var/log/burst-perf-tests.log"
SCRIPTS_DIR="$PERF_DIR/scripts"

# Redirect all output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "BURST Performance Test Runner"
echo "Started at: $(date -Iseconds)"
echo "=========================================="

# Error handler - shutdown on failure
error_handler() {
    local exit_code=$?
    local line_number=$1
    echo ""
    echo "ERROR: Test runner failed at line $line_number with exit code $exit_code"
    echo "Test runner failed at $(date -Iseconds)" >> "$LOG_FILE"

    # Give time for logs to flush
    sync
    sleep 5

    # Shutdown the instance
    #echo "Initiating instance shutdown..."
    #sudo shutdown -h now
}

trap 'error_handler $LINENO' ERR

# Load configuration
if [ ! -f "$PERF_DIR/config.env" ]; then
    echo "ERROR: Configuration file not found: $PERF_DIR/config.env"
    exit 1
fi

# shellcheck source=/dev/null
source "$PERF_DIR/config.env"

# Source aggregate_results.sh for CSV functions
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/aggregate_results.sh"

echo ""
echo "Configuration:"
echo "  Instance ID: $INSTANCE_ID"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  Init Script: $BURST_INIT_SCRIPT"
echo "  Test Archives: $BURST_TEST_ARCHIVES"
echo "  Results Prefix: $BURST_RESULTS_PREFIX"
echo ""

# Validate configuration
if [ -z "$BURST_INIT_SCRIPT" ]; then
    echo "ERROR: BURST_INIT_SCRIPT not set"
    exit 1
fi

if [ -z "$BURST_TEST_ARCHIVES" ]; then
    echo "ERROR: BURST_TEST_ARCHIVES not set"
    exit 1
fi

if [ -z "$BURST_RESULTS_PREFIX" ]; then
    echo "ERROR: BURST_RESULTS_PREFIX not set"
    exit 1
fi

# Parse test archives (comma-separated)
IFS=',' read -ra ARCHIVES <<< "$BURST_TEST_ARCHIVES"

echo "Archives to test: ${ARCHIVES[*]}"
echo ""

# Run initialization script
echo "=========================================="
echo "Running initialization script: $BURST_INIT_SCRIPT"
echo "=========================================="

INIT_SCRIPT_PATH="$SCRIPTS_DIR/init_scripts/$BURST_INIT_SCRIPT"
if [ ! -f "$INIT_SCRIPT_PATH" ]; then
    echo "ERROR: Init script not found: $INIT_SCRIPT_PATH"
    exit 1
fi

# Source the init script to get BURST_OUTPUT_DIR
# shellcheck source=/dev/null
source "$INIT_SCRIPT_PATH"

if [ -z "$BURST_OUTPUT_DIR" ]; then
    echo "ERROR: Init script did not set BURST_OUTPUT_DIR"
    exit 1
fi

echo ""
echo "Init script complete. Output directory: $BURST_OUTPUT_DIR"
echo ""

# Initialize CSV file
CSV_FILE="$PERF_DIR/results/${INSTANCE_TYPE}-${BURST_INIT_SCRIPT%.sh}.csv"
write_csv_header "$CSV_FILE"
echo "Results will be written to: $CSV_FILE"
echo ""

# Run tests for each archive
TOTAL_TESTS=${#ARCHIVES[@]}
COMPLETED=0
FAILED=0

echo "=========================================="
echo "Running performance tests"
echo "=========================================="

for archive_name in "${ARCHIVES[@]}"; do
    COMPLETED=$((COMPLETED + 1))
    echo ""
    echo "[$COMPLETED/$TOTAL_TESTS] Testing archive: $archive_name"
    echo "-------------------------------------------"

    # Create output directory for this test
    TEST_OUTPUT_DIR="$BURST_OUTPUT_DIR/test-$archive_name-$(date +%s)"
    mkdir -p "$TEST_OUTPUT_DIR"

    # Prepare time output file
    TIME_OUTPUT="/tmp/burst-time-$archive_name.txt"

    # Record test start time
    TEST_DATE=$(date -Iseconds)

    # Run burst-downloader with /usr/bin/time
    # If BURST_RUN_AS_ROOT is set, run as root to enable BTRFS_IOC_ENCODED_WRITE
    echo "Starting download at $TEST_DATE..."
    EXIT_CODE=0

    if [ "${BURST_RUN_AS_ROOT:-0}" = "1" ]; then
        echo "Running as root (enables BTRFS_IOC_ENCODED_WRITE)..."
        sudo /usr/bin/time -f "PERF_METRICS: wall=%e user=%U sys=%S maxrss=%M" \
            "$BURST_BINARY" \
                --bucket burst-performance-tests \
                --key "perf-test-$archive_name/archive.zip" \
                --region us-west-2 \
                --output-dir "$TEST_OUTPUT_DIR" \
                --part-size 8 \
                --max-concurrent-parts 8 \
            2>&1 | tee "$TIME_OUTPUT" || EXIT_CODE=$?
    else
        echo "Running as regular user (BTRFS_IOC_ENCODED_WRITE disabled)..."
        /usr/bin/time -f "PERF_METRICS: wall=%e user=%U sys=%S maxrss=%M" \
            "$BURST_BINARY" \
                --bucket burst-performance-tests \
                --key "perf-test-$archive_name/archive.zip" \
                --region us-west-2 \
                --output-dir "$TEST_OUTPUT_DIR" \
                --part-size 8 \
                --max-concurrent-parts 8 \
            2>&1 | tee "$TIME_OUTPUT" || EXIT_CODE=$?
    fi

    echo ""
    if [ $EXIT_CODE -eq 0 ]; then
        echo "Download completed successfully"
    else
        echo "Download failed with exit code: $EXIT_CODE"
        FAILED=$((FAILED + 1))
    fi

    # Parse time output and append to CSV
    if parse_and_append "$TIME_OUTPUT" "$CSV_FILE" "$TEST_DATE" "$INSTANCE_TYPE" \
        "${BURST_INIT_SCRIPT%.sh}" "$archive_name" "$EXIT_CODE"; then
        echo "Metrics recorded to CSV"
    else
        echo "Warning: Failed to parse metrics, recorded with zeros"
    fi

    # Clean up test output to free disk space
    echo "Cleaning up test output..."
    rm -rf "$TEST_OUTPUT_DIR"
    rm -f "$TIME_OUTPUT"

    echo "-------------------------------------------"
done

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total tests: $TOTAL_TESTS"
echo "Completed: $COMPLETED"
echo "Failed: $FAILED"
echo ""

# Display CSV contents
echo "Results CSV:"
cat "$CSV_FILE"
echo ""

# Upload results to S3
echo "=========================================="
echo "Uploading results to S3"
echo "=========================================="

S3_RESULTS_PATH="s3://burst-performance-results/$BURST_RESULTS_PREFIX/${INSTANCE_TYPE}-${BURST_INIT_SCRIPT%.sh}.csv"
echo "Uploading to: $S3_RESULTS_PATH"

if aws s3 cp "$CSV_FILE" "$S3_RESULTS_PATH" --region us-west-2; then
    echo "Results uploaded successfully"
else
    echo "ERROR: Failed to upload results"
    sleep 240 # Time for operator to view log on instance locally
    exit 1
fi

echo ""
echo "=========================================="
echo "Performance tests complete"
echo "Completed at: $(date -Iseconds)"
echo "=========================================="

# Give time for logs to flush
sync
sleep 5

# Shutdown the instance
echo ""
echo "Initiating instance shutdown..."
sudo shutdown -h now
