#!/bin/bash
#
# EC2 Performance Test Orchestration Script
#
# This script runs from GitHub Actions to provision an EC2 instance,
# run performance tests, and clean up afterwards.
#
# The script:
#   1. Creates a tarball of test scripts
#   2. Uploads the binary and scripts to S3
#   3. Provisions an EC2 spot instance with specific tags
#   4. Waits for the instance to complete bootstrap
#   5. Triggers test execution via SSM
#   6. Waits for tests to complete
#   7. Terminates the instance
#
# Usage:
#   ./run_perf_test_on_ec2.sh \
#       --instance-type <type> \
#       --init-script <script.sh> \
#       --archives <archive1,archive2,...> \
#       --binary-path <path/to/burst-downloader> \
#       --results-prefix <s3-prefix>
#
# Required environment variables:
#   AWS_REGION - AWS region (default: us-west-2)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
AWS_REGION="${AWS_REGION:-us-west-2}"
PERF_BUCKET="burst-performance-tests"
RESULTS_BUCKET="burst-performance-results"

# Ubuntu 24.04 LTS AMI in us-west-2 (update as needed)
# This is the official Canonical Ubuntu 24.04 LTS AMI
UBUNTU_AMI="ami-0cf2b4e024cdb6960"

# Instance profile name (must exist in AWS account)
INSTANCE_PROFILE="BurstPerformanceTestInstance"

# Security group (must exist in AWS account, needs outbound HTTPS)
SECURITY_GROUP="burst-perf-test-sg"

# Global variable for cleanup
INSTANCE_ID=""

# Cleanup function
cleanup() {
    local exit_code=$?

    if [ -n "$INSTANCE_ID" ]; then
        echo ""
        echo -e "${YELLOW}Cleaning up instance: $INSTANCE_ID${NC}"
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
        echo -e "${GREEN}Instance termination initiated${NC}"
    fi

    # Clean up temporary files
    rm -f /tmp/burst-perf-scripts.tar.gz 2>/dev/null || true

    exit $exit_code
}

trap cleanup EXIT INT TERM

# Print usage
print_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --instance-type TYPE    EC2 instance type (required)"
    echo "  --init-script SCRIPT    Initialization script name (required)"
    echo "  --archives LIST         Comma-separated list of archives (required)"
    echo "  --binary-path PATH      Path to burst-downloader binary (required)"
    echo "  --results-prefix PREFIX S3 prefix for results (required)"
    echo "  --help                  Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --instance-type i7ie.xlarge --init-script setup_btrfs.sh \\"
    echo "     --archives verysmall,small,medium --binary-path ./burst-downloader \\"
    echo "     --results-prefix perf-run-2025-01-08"
}

# Parse arguments
INSTANCE_TYPE=""
INIT_SCRIPT=""
ARCHIVES=""
BINARY_PATH=""
RESULTS_PREFIX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        --init-script)
            INIT_SCRIPT="$2"
            shift 2
            ;;
        --archives)
            ARCHIVES="$2"
            shift 2
            ;;
        --binary-path)
            BINARY_PATH="$2"
            shift 2
            ;;
        --results-prefix)
            RESULTS_PREFIX="$2"
            shift 2
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$INSTANCE_TYPE" ] || [ -z "$INIT_SCRIPT" ] || [ -z "$ARCHIVES" ] || \
   [ -z "$BINARY_PATH" ] || [ -z "$RESULTS_PREFIX" ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    print_usage
    exit 1
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${RED}Error: Binary not found: $BINARY_PATH${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}BURST Performance Test Orchestration${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  Init Script: $INIT_SCRIPT"
echo "  Archives: $ARCHIVES"
echo "  Binary Path: $BINARY_PATH"
echo "  Results Prefix: $RESULTS_PREFIX"
echo "  AWS Region: $AWS_REGION"
echo ""

# Step 1: Create scripts tarball
echo -e "${BLUE}Step 1: Creating scripts tarball${NC}"
SCRIPTS_TARBALL="/tmp/burst-perf-scripts.tar.gz"
tar -czf "$SCRIPTS_TARBALL" -C "$SCRIPT_DIR" \
    ec2_run_tests.sh \
    aggregate_results.sh \
    init_scripts/
echo -e "${GREEN}Scripts tarball created: $SCRIPTS_TARBALL${NC}"

# Step 2: Upload binary and scripts to S3
echo ""
echo -e "${BLUE}Step 2: Uploading binary and scripts to S3${NC}"

# Generate unique prefix for this run
RUN_ID=$(date +%Y%m%d-%H%M%S)-$(head -c 4 /dev/urandom | xxd -p)
S3_RUN_PREFIX="runs/$RUN_ID"

BINARY_S3_PATH="s3://$PERF_BUCKET/$S3_RUN_PREFIX/burst-downloader"
SCRIPTS_S3_PATH="s3://$PERF_BUCKET/$S3_RUN_PREFIX/scripts.tar.gz"

aws s3 cp "$BINARY_PATH" "$BINARY_S3_PATH" --region "$AWS_REGION"
echo -e "${GREEN}Binary uploaded to: $BINARY_S3_PATH${NC}"

aws s3 cp "$SCRIPTS_TARBALL" "$SCRIPTS_S3_PATH" --region "$AWS_REGION"
echo -e "${GREEN}Scripts uploaded to: $SCRIPTS_S3_PATH${NC}"

# Step 3: Launch EC2 spot instance
echo ""
echo -e "${BLUE}Step 3: Launching EC2 spot instance${NC}"

# Read bootstrap script and encode as base64 for user-data
USER_DATA=$(base64 -w0 "$SCRIPT_DIR/ec2_bootstrap.sh")

# Launch instance with tags
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$UBUNTU_AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --instance-market-options 'MarketType=spot' \
    --instance-initiated-shutdown-behavior terminate \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" \
    --security-groups "$SECURITY_GROUP" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[
        {Key=Name,Value=burst-perf-test-$INSTANCE_TYPE},
        {Key=BurstBinaryS3Path,Value=$BINARY_S3_PATH},
        {Key=BurstScriptsS3Path,Value=$SCRIPTS_S3_PATH},
        {Key=BurstResultsPrefix,Value=$RESULTS_PREFIX},
        {Key=BurstInitScript,Value=$INIT_SCRIPT},
        {Key=BurstTestArchives,Value=$ARCHIVES}
    ]" \
    --query 'Instances[0].InstanceId' \
    --output text \
    --region "$AWS_REGION")

echo -e "${GREEN}Instance launched: $INSTANCE_ID${NC}"

# Step 4: Wait for instance to be running
echo ""
echo -e "${BLUE}Step 4: Waiting for instance to start${NC}"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
echo -e "${GREEN}Instance is running${NC}"

# Get instance public IP
INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    --region "$AWS_REGION")
echo "Instance IP: $INSTANCE_IP"

# Step 5: Wait for instance status checks
echo ""
echo -e "${BLUE}Step 5: Waiting for instance status checks${NC}"
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
echo -e "${GREEN}Instance status checks passed${NC}"

# Step 6: Wait for bootstrap to complete (check for marker file via SSM)
echo ""
echo -e "${BLUE}Step 6: Waiting for bootstrap to complete${NC}"

BOOTSTRAP_TIMEOUT=600  # 10 minutes
BOOTSTRAP_START=$(date +%s)

while true; do
    ELAPSED=$(($(date +%s) - BOOTSTRAP_START))
    if [ $ELAPSED -gt $BOOTSTRAP_TIMEOUT ]; then
        echo -e "${RED}Bootstrap timeout exceeded${NC}"
        exit 1
    fi

    # Check for bootstrap completion marker via SSM
    COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["test -f /opt/burst-perf/.bootstrap_complete && echo READY || echo WAITING"]' \
        --query 'Command.CommandId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null) || {
        echo "  Waiting for SSM agent... ($ELAPSED s)"
        sleep 10
        continue
    }

    # Wait for command to complete
    sleep 5

    # Get command output
    OUTPUT=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null) || OUTPUT=""

    if [[ "$OUTPUT" == *"READY"* ]]; then
        echo -e "${GREEN}Bootstrap complete${NC}"
        break
    fi

    echo "  Bootstrap in progress... ($ELAPSED s)"
    sleep 10
done

# Step 7: Trigger test execution via SSM
echo ""
echo -e "${BLUE}Step 7: Starting performance tests${NC}"

COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["sudo -u ubuntu /opt/burst-perf/scripts/ec2_run_tests.sh"]' \
    --timeout-seconds 7200 \
    --query 'Command.CommandId' \
    --output text \
    --region "$AWS_REGION")

echo "SSM Command ID: $COMMAND_ID"
echo "Tests started, waiting for completion..."

# Step 8: Wait for tests to complete (instance will self-terminate)
echo ""
echo -e "${BLUE}Step 8: Waiting for tests to complete${NC}"

TEST_TIMEOUT=7200  # 2 hours
TEST_START=$(date +%s)

while true; do
    ELAPSED=$(($(date +%s) - TEST_START))
    if [ $ELAPSED -gt $TEST_TIMEOUT ]; then
        echo -e "${RED}Test timeout exceeded${NC}"
        exit 1
    fi

    # Check instance state
    STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null) || STATE="unknown"

    if [ "$STATE" = "terminated" ] || [ "$STATE" = "shutting-down" ]; then
        echo -e "${GREEN}Instance is terminating (tests completed)${NC}"
        INSTANCE_ID=""  # Prevent cleanup from trying to terminate again
        break
    fi

    # Check SSM command status
    STATUS=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'Status' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null) || STATUS="unknown"

    if [ "$STATUS" = "Success" ]; then
        echo -e "${GREEN}Tests completed successfully${NC}"
        break
    elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Cancelled" ] || [ "$STATUS" = "TimedOut" ]; then
        echo -e "${RED}Tests failed with status: $STATUS${NC}"
        # Get command output for debugging
        aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$AWS_REGION" || true
        exit 1
    fi

    MINUTES=$((ELAPSED / 60))
    echo "  Tests in progress... ($MINUTES min elapsed)"
    sleep 30
done

# Step 9: Verify results uploaded
echo ""
echo -e "${BLUE}Step 9: Verifying results${NC}"

RESULTS_PATH="s3://$RESULTS_BUCKET/$RESULTS_PREFIX/${INSTANCE_TYPE}-${INIT_SCRIPT%.sh}.csv"
if aws s3 ls "$RESULTS_PATH" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo -e "${GREEN}Results found at: $RESULTS_PATH${NC}"

    # Download and display results
    echo ""
    echo "Results:"
    aws s3 cp "$RESULTS_PATH" - --region "$AWS_REGION"
else
    echo -e "${RED}Results not found at: $RESULTS_PATH${NC}"
    exit 1
fi

# Cleanup S3 run artifacts
echo ""
echo -e "${BLUE}Cleaning up S3 run artifacts${NC}"
aws s3 rm "s3://$PERF_BUCKET/$S3_RUN_PREFIX/" --recursive --region "$AWS_REGION" >/dev/null 2>&1 || true

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Performance test completed successfully${NC}"
echo -e "${GREEN}============================================${NC}"
