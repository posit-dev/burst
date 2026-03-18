#!/bin/bash
#
# Aggregate Results Script for BURST Performance Tests
#
# This script parses /usr/bin/time output and formats it as CSV.
# It can be sourced by ec2_run_tests.sh or used standalone.
#
# Functions:
#   parse_time_output <time_output_file> - Parse /usr/bin/time output
#   format_csv_row <params...>           - Format a CSV row
#   write_csv_header <csv_file>          - Write CSV header
#   append_csv_row <csv_file> <params..> - Append a row to CSV
#

# Parse /usr/bin/time output with format "wall=%e user=%U sys=%S maxrss=%M"
# Usage: parse_time_output <time_output_file>
# Sets: WALL_TIME, USER_TIME, SYS_TIME, MAX_RSS
parse_time_output() {
    local time_file="$1"

    # Initialize defaults
    WALL_TIME="0"
    USER_TIME="0"
    SYS_TIME="0"
    MAX_RSS="0"

    if [ ! -f "$time_file" ]; then
        echo "Warning: Time output file not found: $time_file" >&2
        return 1
    fi

    # Look for PERF_METRICS line in the output
    local metrics_line
    metrics_line=$(grep "PERF_METRICS:" "$time_file" 2>/dev/null | tail -1)

    if [ -z "$metrics_line" ]; then
        echo "Warning: No PERF_METRICS found in $time_file" >&2
        return 1
    fi

    # Parse the metrics
    # Format: "PERF_METRICS: wall=1.23 user=0.45 sys=0.12 maxrss=12345"
    WALL_TIME=$(echo "$metrics_line" | grep -oP 'wall=\K[0-9.]+' || echo "0")
    USER_TIME=$(echo "$metrics_line" | grep -oP 'user=\K[0-9.]+' || echo "0")
    SYS_TIME=$(echo "$metrics_line" | grep -oP 'sys=\K[0-9.]+' || echo "0")
    MAX_RSS=$(echo "$metrics_line" | grep -oP 'maxrss=\K[0-9]+' || echo "0")

    return 0
}

# Write CSV header
# Usage: write_csv_header <csv_file>
write_csv_header() {
    local csv_file="$1"
    echo "date,instance_type,init_script,archive_name,wall_time,user_cpu_time,system_cpu_time,max_memory_kb,exit_code" > "$csv_file"
}

# Format a CSV row
# Usage: format_csv_row <date> <instance_type> <init_script> <archive_name> <wall_time> <user_time> <sys_time> <max_rss> <exit_code>
# Returns: CSV-formatted row
format_csv_row() {
    local date="$1"
    local instance_type="$2"
    local init_script="$3"
    local archive_name="$4"
    local wall_time="$5"
    local user_time="$6"
    local sys_time="$7"
    local max_rss="$8"
    local exit_code="$9"

    echo "$date,$instance_type,$init_script,$archive_name,$wall_time,$user_time,$sys_time,$max_rss,$exit_code"
}

# Append a row to CSV file
# Usage: append_csv_row <csv_file> <date> <instance_type> <init_script> <archive_name> <wall_time> <user_time> <sys_time> <max_rss> <exit_code>
append_csv_row() {
    local csv_file="$1"
    shift
    format_csv_row "$@" >> "$csv_file"
}

# Parse time output and append to CSV in one step
# Usage: parse_and_append <time_output_file> <csv_file> <date> <instance_type> <init_script> <archive_name> <exit_code>
parse_and_append() {
    local time_file="$1"
    local csv_file="$2"
    local date="$3"
    local instance_type="$4"
    local init_script="$5"
    local archive_name="$6"
    local exit_code="$7"

    if parse_time_output "$time_file"; then
        append_csv_row "$csv_file" "$date" "$instance_type" "$init_script" "$archive_name" \
            "$WALL_TIME" "$USER_TIME" "$SYS_TIME" "$MAX_RSS" "$exit_code"
        return 0
    else
        # Still record the result even if parsing failed
        append_csv_row "$csv_file" "$date" "$instance_type" "$init_script" "$archive_name" \
            "0" "0" "0" "0" "$exit_code"
        return 1
    fi
}

# If run directly (not sourced), provide a simple CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        parse)
            if [ -z "$2" ]; then
                echo "Usage: $0 parse <time_output_file>"
                exit 1
            fi
            if parse_time_output "$2"; then
                echo "WALL_TIME=$WALL_TIME"
                echo "USER_TIME=$USER_TIME"
                echo "SYS_TIME=$SYS_TIME"
                echo "MAX_RSS=$MAX_RSS"
            else
                exit 1
            fi
            ;;
        header)
            if [ -z "$2" ]; then
                echo "Usage: $0 header <csv_file>"
                exit 1
            fi
            write_csv_header "$2"
            echo "Header written to $2"
            ;;
        *)
            echo "Usage: $0 <command> [args...]"
            echo ""
            echo "Commands:"
            echo "  parse <time_output_file>  - Parse time output and print values"
            echo "  header <csv_file>         - Write CSV header to file"
            echo ""
            echo "This script can also be sourced to use its functions directly."
            exit 1
            ;;
    esac
fi
