# BURST Performance Testing Framework

This directory contains the performance testing framework for benchmarking `burst-downloader` across different EC2 instance types, archive sizes, and filesystem configurations.

## Overview

The framework provisions EC2 spot instances, runs controlled download tests, collects timing metrics, and aggregates results to S3. Tests are run sequentially with cooldown periods to ensure S3 performance isolation between tests.

## S3 Bucket Structure

### Test Archives Bucket: `burst-performance-tests`

```
burst-performance-tests/
├── perf-test-verysmall/
│   ├── archive.zip          # BURST archive (~5 MiB)
│   └── files/
│       └── data.bin         # Individual files for comparison testing
├── perf-test-small/
│   ├── archive.zip          # BURST archive (~40 MiB)
│   └── files/
│       └── data.bin
├── perf-test-medium/
│   ├── archive.zip          # BURST archive (~250 MiB)
│   └── files/
│       └── data.bin
├── perf-test-medium-manyfiles/
│   ├── archive.zip          # BURST archive (~250 MiB, ~5000 files)
│   └── files/
│       └── dir_XXXX/file_XXXXXX.txt  # Preserves directory structure
├── ... (large, xlarge, xxlarge variants)
└── runs/                    # Temporary storage for test binaries/scripts
```

### Results Bucket: `burst-performance-results`

```
burst-performance-results/
└── {prefix}/
    ├── i7ie.xlarge-setup_btrfs_root.csv
    ├── i7ie.xlarge-setup_btrfs_user.csv
    ├── i7ie.3xlarge-setup_btrfs_root.csv
    ├── i7ie.3xlarge-setup_btrfs_user.csv
    └── ... (one CSV per instance type × init script combination)
```

## CSV Format

```csv
date,instance_type,init_script,archive_name,wall_time,user_cpu_time,system_cpu_time,max_memory_kb,exit_code
2025-01-08T10:30:00Z,i7ie.xlarge,setup_btrfs_root,verysmall,0.523,0.142,0.089,45632,0
```

## Setup Instructions

### 1. Create S3 Buckets

Create the following S3 buckets in us-west-2:

```bash
aws s3 mb s3://burst-performance-tests --region us-west-2
aws s3 mb s3://burst-performance-results --region us-west-2
```

### 2. Create IAM Resources

#### EC2 Instance Profile

Create an IAM role `BurstPerformanceTestInstance` with:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::burst-performance-tests/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::burst-performance-results/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeTags"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ],
      "Resource": "*"
    }
  ]
}
```

Create an instance profile with the same name and attach the role.

#### Security Group

Create security group `burst-perf-test-sg` with:
- Outbound: Allow all HTTPS (port 443) for S3 and SSM
- Inbound: None required (SSM uses outbound-only connections)

### 3. Generate Test Archives

Build burst-writer and run the archive creation script:

```bash
cd build && make burst-writer
cd ..
./tests/performance/create_perf_test_archives.sh
```

To create specific archives only:

```bash
./tests/performance/create_perf_test_archives.sh verysmall small medium
```

**Note**: Large archives (xlarge, xxlarge) require significant disk space and time to generate.

### 4. Configure GitHub Actions

The workflow uses the IAM role `arn:aws:iam::339404546440:role/BurstPerformanceTests` via OIDC authentication. Ensure this role has permissions for:

- EC2: `RunInstances`, `TerminateInstances`, `DescribeInstances`, `DescribeInstanceStatus`
- IAM: `PassRole` (to attach instance profile to EC2)
- SSM: `SendCommand`, `GetCommandInvocation`
- S3: `GetObject`, `PutObject`, `ListBucket` on both buckets

## Running Tests

### Via GitHub Actions (Recommended)

Trigger the workflow manually from the Actions tab:

```bash
gh workflow run performance-test.yaml \
  -f branch_ref=main \
  -f s3_results_prefix=perf-run-$(date +%Y%m%d) \
  -f test_instance_types=i7ie.xlarge,m6id.4xlarge \
  -f test_archives=verysmall,small,medium
```

### Workflow Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `branch_ref` | Branch or ref to build from | `main` |
| `s3_results_prefix` | S3 prefix for results | (required) |
| `test_instance_types` | Comma-separated instance types | `i7ie.xlarge,i7ie.3xlarge,i7ie.12xlarge,m6id.4xlarge` |
| `test_init_scripts` | Comma-separated init scripts | `setup_btrfs_root.sh,setup_btrfs_user.sh` |
| `test_archives` | Comma-separated archive names | All archives |
| `cooldown_minutes` | Cooldown between instance types | `45` |

### Manual Testing

For debugging, you can run the orchestration script directly:

```bash
export AWS_REGION=us-west-2

./tests/performance/run_perf_test_on_ec2.sh \
  --instance-type t3.medium \
  --init-script setup_btrfs_user.sh \
  --archives verysmall \
  --binary-path ./build/burst-downloader \
  --results-prefix test-manual-$(date +%s)
```

## Test Matrix

### Instance Types

| Type | vCPUs | Memory | Network | Notes |
|------|-------|--------|---------|-------|
| i7ie.xlarge | 4 | 32 GiB | up to 25 Gbps | Storage-optimized, NVMe SSD |
| i7ie.3xlarge | 12 | 96 GiB | up to 25 Gbps | Storage-optimized, NVMe SSD |
| i7ie.12xlarge | 48 | 384 GiB | 75 Gbps | Storage-optimized, NVMe SSD |
| m6id.4xlarge | 16 | 64 GiB | up to 12.5 Gbps | General purpose with NVMe |

### Initialization Scripts

| Script | Description |
|--------|-------------|
| `setup_btrfs_root.sh` | BTRFS with zstd compression, runs burst-downloader as root (enables `BTRFS_IOC_ENCODED_WRITE`) |
| `setup_btrfs_user.sh` | BTRFS with zstd compression, runs burst-downloader as regular user (disables `BTRFS_IOC_ENCODED_WRITE`) |

### Archive Sizes

| Name | Size | Files | Notes |
|------|------|-------|-------|
| verysmall | ~5 MiB | 1 | Single BURST part |
| small | ~40 MiB | 1 | Multiple parts |
| medium | ~250 MiB | 1 | Single large file |
| medium-manyfiles | ~250 MiB | ~5000 | Many small files |
| large | ~1 GiB | 1 | Single large file |
| large-manyfiles | ~1 GiB | ~10000 | Many small files |
| xlarge | ~10 GiB | 1 | Single large file |
| xlarge-manyfiles | ~10 GiB | ~25000 | Many small files |
| xxlarge | ~50 GiB | 1 | Single large file |

## Results Interpretation

### Expected Performance Characteristics

- **BTRFS as root** should show lowest wall time due to BTRFS_IOC_ENCODED_WRITE zero-copy optimization
- **BTRFS as user** provides baseline showing standard write performance without the encoded write optimization
- The difference between these configurations isolates the benefit of `BTRFS_IOC_ENCODED_WRITE`

### Analyzing Results

Download results from S3:

```bash
aws s3 sync s3://burst-performance-results/your-prefix/ ./results/
```

Combine and analyze with Python:

```python
import pandas as pd
import glob

# Load all CSVs
dfs = [pd.read_csv(f) for f in glob.glob('results/*.csv')]
df = pd.concat(dfs, ignore_index=True)

# Summary by instance type and init script
summary = df.groupby(['instance_type', 'init_script', 'archive_name']).agg({
    'wall_time': ['mean', 'std'],
    'exit_code': 'sum'
})
print(summary)
```

## Troubleshooting

### Instance Fails to Start

1. Check CloudWatch Logs for user-data script output
2. Verify IAM instance profile exists and has correct permissions
3. Ensure security group allows outbound HTTPS

### Tests Timeout

1. Check if spot instance was interrupted (view spot request history)
2. Increase timeout in SSM command
3. Test with smaller archives first

### Results Not Uploaded

1. Instance may have terminated before upload completed
2. Check S3 bucket permissions
3. Review instance logs in `/var/log/burst-perf-*.log`

### Spot Instance Interruptions

The framework handles interruptions gracefully:
- Instance has `instance-initiated-shutdown-behavior: terminate`
- Orchestration script includes cleanup trap
- Failed tests can be retried with the retry step

## Cost Estimation

Per full test run (4 instance types × 2 init scripts × 9 archives):

| Component | Estimated Cost |
|-----------|----------------|
| i7ie.xlarge spot (~1h) | ~$0.07 |
| i7ie.3xlarge spot (~1h) | ~$0.21 |
| i7ie.12xlarge spot (~1h) | ~$0.84 |
| m6id.4xlarge spot (~1h) | ~$0.23 |
| S3 requests (~500 GETs) | ~$0.002 |
| Data transfer (in-region) | $0 |
| **Total** | **~$3-5** |

Note: Spot prices vary by availability zone and time.
