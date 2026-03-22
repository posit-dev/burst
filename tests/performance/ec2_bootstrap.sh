#!/bin/bash
#
# EC2 Bootstrap Script for BURST Performance Tests
#
# This script runs as user-data when the EC2 instance starts.
# It prepares the instance environment for running performance tests.
#
# The script:
#   1. Installs required dependencies (libzstd, awscli, time)
#   2. Creates the performance test directory structure
#   3. Downloads the burst-downloader binary from S3
#   4. Downloads test scripts from S3
#   5. Signals readiness via SSM parameter
#
# On failure, the instance will self-terminate via shutdown.
#
# Environment variables (passed via instance tags or SSM):
#   BURST_BINARY_S3_PATH   - S3 path to burst-downloader binary
#   BURST_SCRIPTS_S3_PATH  - S3 path to test scripts tarball
#   BURST_RESULTS_PREFIX   - S3 prefix for results
#   AWS_REGION             - AWS region for S3 operations
#

set -e

LOG_FILE="/var/log/burst-perf-bootstrap.log"
PERF_DIR="/opt/burst-perf"

# Redirect all output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "BURST Performance Test Bootstrap"
echo "Started at: $(date -Iseconds)"
echo "=========================================="

# Error handler - shutdown on failure
error_handler() {
    local exit_code=$?
    local line_number=$1
    echo ""
    echo "ERROR: Bootstrap failed at line $line_number with exit code $exit_code"
    echo "Initiating instance shutdown..."
    echo "Bootstrap failed at $(date -Iseconds)" >> "$LOG_FILE"

    # Give time for logs to flush
    sync
    sleep 5

    # Shutdown the instance (will terminate due to instance-initiated-shutdown-behavior)
    sudo shutdown -h now
}

trap 'error_handler $LINENO' ERR

# Get instance metadata
echo "Fetching instance metadata..."
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_TYPE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
AVAILABILITY_ZONE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

echo "Instance ID: $INSTANCE_ID"
echo "Instance Type: $INSTANCE_TYPE"
echo "Availability Zone: $AVAILABILITY_ZONE"

# Get configuration from instance tags
echo ""
echo "Fetching instance tags..."

# Wait for IAM role to be available
for i in {1..30}; do
    if aws sts get-caller-identity --region us-west-2 >/dev/null; then
        break
    fi
    echo "Waiting for IAM role... ($i/30)"
    sleep 2
done

# Fetch tags
BURST_BINARY_S3_PATH=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=BurstBinaryS3Path" \
    --query 'Tags[0].Value' --output text --region us-west-2 || echo "")

BURST_SCRIPTS_S3_PATH=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=BurstScriptsS3Path" \
    --query 'Tags[0].Value' --output text --region us-west-2 || echo "")

BURST_RESULTS_PREFIX=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=BurstResultsPrefix" \
    --query 'Tags[0].Value' --output text --region us-west-2 || echo "")

BURST_INIT_SCRIPT=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=BurstInitScript" \
    --query 'Tags[0].Value' --output text --region us-west-2 || echo "")

BURST_TEST_ARCHIVES=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=BurstTestArchives" \
    --query 'Tags[0].Value' --output text --region us-west-2 || echo "")

echo "Binary S3 Path: $BURST_BINARY_S3_PATH"
echo "Scripts S3 Path: $BURST_SCRIPTS_S3_PATH"
echo "Results Prefix: $BURST_RESULTS_PREFIX"
echo "Init Script: $BURST_INIT_SCRIPT"
echo "Test Archives: $BURST_TEST_ARCHIVES"

# Validate required tags
if [ -z "$BURST_BINARY_S3_PATH" ] || [ "$BURST_BINARY_S3_PATH" = "None" ]; then
    echo "ERROR: BurstBinaryS3Path tag not set"
    exit 1
fi

if [ -z "$BURST_SCRIPTS_S3_PATH" ] || [ "$BURST_SCRIPTS_S3_PATH" = "None" ]; then
    echo "ERROR: BurstScriptsS3Path tag not set"
    exit 1
fi

# Install dependencies
echo ""
echo "Installing dependencies..."

# Update package list
sudo apt-get update -qq

# Install required packages
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    libzstd1 \
    awscli \
    time \
    btrfs-progs \
    jq

echo "Dependencies installed successfully"

# Create directory structure
echo ""
echo "Creating directory structure..."
sudo mkdir -p "$PERF_DIR"/{bin,scripts,results,output}
sudo chown -R ubuntu:ubuntu "$PERF_DIR"

# Download burst-downloader binary
echo ""
echo "Downloading burst-downloader binary..."
aws s3 cp "$BURST_BINARY_S3_PATH" "$PERF_DIR/bin/burst-downloader" --region us-west-2
chmod +x "$PERF_DIR/bin/burst-downloader"
echo "Binary downloaded: $PERF_DIR/bin/burst-downloader"

# Verify binary works
if ! "$PERF_DIR/bin/burst-downloader" --help >/dev/null; then
    echo "ERROR: burst-downloader binary verification failed"
    exit 1
fi
echo "Binary verification passed"

# Download test scripts
echo ""
echo "Downloading test scripts..."
aws s3 cp "$BURST_SCRIPTS_S3_PATH" "$PERF_DIR/scripts/scripts.tar.gz" --region us-west-2
tar -xzf "$PERF_DIR/scripts/scripts.tar.gz" -C "$PERF_DIR/scripts/"
rm "$PERF_DIR/scripts/scripts.tar.gz"
chmod +x "$PERF_DIR/scripts/"*.sh || true
chmod +x "$PERF_DIR/scripts/init_scripts/"*.sh || true
echo "Scripts downloaded to $PERF_DIR/scripts/"

# Save configuration for test runner
echo ""
echo "Saving configuration..."
cat > "$PERF_DIR/config.env" << EOF
INSTANCE_ID=$INSTANCE_ID
INSTANCE_TYPE=$INSTANCE_TYPE
AVAILABILITY_ZONE=$AVAILABILITY_ZONE
BURST_RESULTS_PREFIX=$BURST_RESULTS_PREFIX
BURST_INIT_SCRIPT=$BURST_INIT_SCRIPT
BURST_TEST_ARCHIVES=$BURST_TEST_ARCHIVES
AWS_REGION=us-west-2
BURST_BINARY=$PERF_DIR/bin/burst-downloader
PERF_DIR=$PERF_DIR
EOF

echo "Configuration saved to $PERF_DIR/config.env"

# Mark bootstrap as complete
echo ""
echo "=========================================="
echo "Bootstrap complete at: $(date -Iseconds)"
echo "=========================================="
echo ""
echo "Ready to run performance tests."
echo "Run: $PERF_DIR/scripts/ec2_run_tests.sh"

# Create completion marker
touch "$PERF_DIR/.bootstrap_complete"
