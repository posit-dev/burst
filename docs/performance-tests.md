# BURST Performance Tests

This document describes the performance testing framework for BURST, what it measures, and how to interpret results.

## What Are BURST Performance Tests?

BURST performance tests measure the download and extraction speed of `burst-downloader` under controlled conditions. The tests evaluate how quickly BURST can download archives of various sizes from S3 and extract them to different filesystem types.

The framework is designed to:
- Establish baseline performance metrics for different configurations
- Identify performance improvements or regressions between versions
- Compare performance across different EC2 instance types
- Measure the impact of BTRFS compressed write optimization

## Test Matrix

### Instance Types

We test on a variety of storage-optimized and general-purpose instances:

| Instance Type | vCPUs | Memory | Network Bandwidth | Storage |
|--------------|-------|--------|-------------------|---------|
| **i7ie.xlarge** | 4 | 32 GiB | Up to 25 Gbps | NVMe SSD |
| **i7ie.3xlarge** | 12 | 96 GiB | Up to 25 Gbps | NVMe SSD |
| **i7ie.12xlarge** | 48 | 384 GiB | 75 Gbps | NVMe SSD |
| **m6id.4xlarge** | 16 | 64 GiB | Up to 12.5 Gbps | NVMe SSD |

These instances are chosen to represent common deployment scenarios and to evaluate how BURST scales with available resources.

### Archive Sizes

Tests cover a range of archive sizes representing different use cases:

| Archive | Uncompressed Size | Files | Use Case |
|---------|------------------|-------|----------|
| **Very Small** | ~5 MiB | 1 | Quick deployments, config files |
| **Small** | ~40 MiB | 1 | Small application packages |
| **Medium** | ~250 MiB | 1 | Typical application deployments |
| **Medium (many files)** | ~250 MiB | ~5,000 | Source code, many small files |
| **Large** | ~1 GiB | 1 | Large applications, dependencies |
| **Large (many files)** | ~1 GiB | ~10,000 | Large codebases |
| **Extra Large** | ~10 GiB | 1 | ML models, large datasets |
| **Extra Large (many files)** | ~10 GiB | ~25,000 | Very large projects |
| **XXLarge** | ~50 GiB | 1 | Massive datasets |

### Filesystem Configurations

Each instance is tested with two BTRFS configurations to measure the performance impact of `BTRFS_IOC_ENCODED_WRITE`:

1. **BTRFS as root**: BTRFS filesystem with zstd compression, running burst-downloader as root. This configuration enables BURST's `BTRFS_IOC_ENCODED_WRITE` optimization, which writes compressed data directly to disk without decompression/recompression. This ioctl requires elevated privileges.

2. **BTRFS as user**: BTRFS filesystem with zstd compression, running burst-downloader as a regular user. This configuration prevents use of `BTRFS_IOC_ENCODED_WRITE`, forcing standard write operations. This isolates the performance benefit of the encoded write optimization.

## What We Measure

For each test, we collect the following metrics using `/usr/bin/time`:

| Metric | Description |
|--------|-------------|
| **Wall Time** | Total elapsed time from start to finish (seconds) |
| **User CPU Time** | Time spent in user-mode code (seconds) |
| **System CPU Time** | Time spent in kernel-mode code (seconds) |
| **Max Memory** | Peak memory usage (KB) |

### Understanding the Metrics

- **Wall time** is the primary metric for overall performance. Lower is better.

- **User CPU time** reflects time spent on decompression and data processing. With BTRFS passthrough, this should be significantly reduced since data isn't decompressed.

- **System CPU time** reflects I/O operations and kernel overhead. BTRFS with compression may show higher system time due to filesystem complexity, but this is offset by reduced user time.

- **Wall time < User + System time** can occur when operations are parallelized across multiple CPU cores.

## How Tests Ensure Isolation

### Sequential Execution

Tests are run sequentially, one instance at a time. This ensures:
- No competition for S3 bandwidth between test instances
- Consistent network conditions for each test
- Predictable S3 performance (no hot/cold object effects)

### Cooldown Periods

A 45-minute cooldown period occurs between different instance types. This:
- Allows S3's internal caching/distribution to stabilize
- Prevents performance artifacts from recent accesses
- Ensures each instance type encounters "fresh" S3 objects

### Why This Matters

S3 performance can be affected by concurrent or recent access patterns:
- Objects with frequent access may be cached closer to the requestor
- High concurrency can trigger throttling
- Recent accesses can warm caches, improving subsequent performance

By testing sequentially with cooldowns, we measure more consistent, reproducible performance.

## Interpreting Results

### Expected Patterns

**By User Privilege:**
- BTRFS as root typically shows the best wall time for large archives due to zero-copy writes via `BTRFS_IOC_ENCODED_WRITE`
- BTRFS as user provides a baseline showing standard write performance without the encoded write optimization
- The difference between these two configurations isolates the benefit of `BTRFS_IOC_ENCODED_WRITE`

**By Archive Size:**
- Throughput (MB/s) should remain relatively constant for single-file archives
- Many-files archives may show lower throughput due to filesystem metadata operations
- Very small archives may show higher relative overhead from S3 round-trips

**By Instance Type:**
- Larger instances should show better performance up to network saturation
- i7ie.12xlarge with 75 Gbps network should significantly outperform others on large archives
- CPU cores matter less than network and storage bandwidth for this workload

### Identifying Issues

**High exit_code values**: Tests that fail (exit_code != 0) indicate errors. Check the detailed logs in S3.

**Unexpected variance**: If wall_time varies significantly between similar runs, investigate:
- Spot instance type (may have different underlying hardware)
- S3 regional capacity at time of test
- Instance storage performance variability

**No performance difference between root and user**: Could indicate:
- BTRFS encoded write optimization not being triggered
- burst-downloader not attempting to use `BTRFS_IOC_ENCODED_WRITE`
- Loop device overhead dominating for small archives where the optimization benefit is minimal

## Running Your Own Tests

For detailed instructions on running performance tests, including:
- AWS resource setup
- Archive generation
- Workflow configuration
- Manual testing

See [tests/performance/README.md](../tests/performance/README.md).

### Quick Start

```bash
# Trigger a performance test run via GitHub Actions
gh workflow run performance-test.yaml \
  -f branch_ref=main \
  -f s3_results_prefix=perf-$(date +%Y%m%d) \
  -f test_instance_types=i7ie.xlarge \
  -f test_archives=verysmall,small,medium
```

### Downloading Results

```bash
# Download all results for a test run
aws s3 sync s3://burst-performance-results/perf-20250108/ ./results/

# View a specific result file
cat results/i7ie.xlarge-setup_btrfs.csv
```

## Future Enhancements

The performance testing framework is designed to be extended. Planned improvements include:

- **Profiling mode**: Detailed syscall-level metrics using BURST's built-in profiling
- **Comparison tests**: Benchmark alternative download tools using the individual files structure
- **Instance storage testing**: Compare NVMe vs EBS performance
- **Visualization**: Automated graph generation from CSV results
- **Historical tracking**: Compare performance across git commits/releases
