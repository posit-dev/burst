#include "unity.h"
#include "burst_writer.h"
#include "zip_structures.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

void setUp(void) {
}

void tearDown(void) {
}

// Test writer creation and destruction
void test_writer_create_destroy(void) {
    FILE *tmp = tmpfile();
    TEST_ASSERT_NOT_NULL(tmp);

    struct burst_writer *writer = burst_writer_create(tmp, 3);
    TEST_ASSERT_NOT_NULL(writer);
    TEST_ASSERT_EQUAL(0, writer->current_offset);
    TEST_ASSERT_EQUAL(0, writer->num_files);
    TEST_ASSERT_NOT_NULL(writer->zstd_ctx);
    TEST_ASSERT_NOT_NULL(writer->write_buffer);

    burst_writer_destroy(writer);
    fclose(tmp);
}

// Test writer creation with NULL file
void test_writer_create_null_file(void) {
    struct burst_writer *writer = burst_writer_create(NULL, 3);
    TEST_ASSERT_NULL(writer);
}

// Test buffered writing
void test_writer_buffered_write(void) {
    FILE *tmp = tmpfile();
    struct burst_writer *writer = burst_writer_create(tmp, 3);

    const char *data = "Hello, World!";
    int result = burst_writer_write(writer, data, strlen(data));

    TEST_ASSERT_EQUAL(0, result);
    TEST_ASSERT_EQUAL(strlen(data), writer->buffer_used);
    TEST_ASSERT_EQUAL(0, writer->current_offset);  // Not flushed yet

    burst_writer_destroy(writer);
    fclose(tmp);
}

// Test flush operation
void test_writer_flush(void) {
    FILE *tmp = tmpfile();
    struct burst_writer *writer = burst_writer_create(tmp, 3);

    const char *data = "Test data for flushing";
    burst_writer_write(writer, data, strlen(data));

    int result = burst_writer_flush(writer);
    TEST_ASSERT_EQUAL(0, result);
    TEST_ASSERT_EQUAL(0, writer->buffer_used);
    TEST_ASSERT_EQUAL(strlen(data), writer->current_offset);

    burst_writer_destroy(writer);
    fclose(tmp);
}

// Test flushing empty buffer
void test_writer_flush_empty(void) {
    FILE *tmp = tmpfile();
    struct burst_writer *writer = burst_writer_create(tmp, 3);

    int result = burst_writer_flush(writer);
    TEST_ASSERT_EQUAL(0, result);
    TEST_ASSERT_EQUAL(0, writer->current_offset);

    burst_writer_destroy(writer);
    fclose(tmp);
}

// Test writing NULL data
void test_writer_write_null(void) {
    FILE *tmp = tmpfile();
    struct burst_writer *writer = burst_writer_create(tmp, 3);

    int result = burst_writer_write(writer, NULL, 10);
    TEST_ASSERT_EQUAL(-1, result);

    burst_writer_destroy(writer);
    fclose(tmp);
}

// Test writing zero bytes
void test_writer_write_zero_bytes(void) {
    FILE *tmp = tmpfile();
    struct burst_writer *writer = burst_writer_create(tmp, 3);

    const char *data = "test";
    int result = burst_writer_write(writer, data, 0);
    TEST_ASSERT_EQUAL(0, result);
    TEST_ASSERT_EQUAL(0, writer->buffer_used);

    burst_writer_destroy(writer);
    fclose(tmp);
}

// Test buffer overflow causes flush
void test_writer_buffer_overflow(void) {
    FILE *tmp = tmpfile();
    struct burst_writer *writer = burst_writer_create(tmp, 3);

    // Write more than buffer size (64 KiB)
    char large_data[70000];
    memset(large_data, 'A', sizeof(large_data));

    int result = burst_writer_write(writer, large_data, sizeof(large_data));
    TEST_ASSERT_EQUAL(0, result);

    // Buffer should have been flushed
    TEST_ASSERT(writer->current_offset > 0);
    TEST_ASSERT(writer->buffer_used < sizeof(large_data));

    burst_writer_destroy(writer);
    fclose(tmp);
}

// Returns whether the archive's central directory holds an extended timestamp (0x5455) field.
static bool archive_has_timestamp_field(FILE *f) {
    long size = ftell(f);
    uint8_t *buf = malloc((size_t)size);
    fseek(f, 0, SEEK_SET);
    size_t n = fread(buf, 1, (size_t)size, f);
    bool found = false;
    for (size_t i = 0; i + 46 <= n; i++) {
        if (memcmp(buf + i, "PK\x01\x02", 4) != 0) {
            continue;
        }
        uint16_t name_len, extra_len;
        memcpy(&name_len, buf + i + 28, 2);
        memcpy(&extra_len, buf + i + 30, 2);
        const uint8_t *extra = buf + i + 46 + name_len;
        for (size_t pos = 0; pos + 4 <= extra_len; ) {
            uint16_t id, len;
            memcpy(&id, extra + pos, 2);
            memcpy(&len, extra + pos + 2, 2);
            found |= id == 0x5455;
            pos += 4 + len;
        }
    }
    free(buf);
    return found;
}

static FILE *write_one_directory(bool set_attrs) {
    FILE *tmp = tmpfile();
    struct burst_writer *writer = burst_writer_create(tmp, 3);
    const char *name = "dir/";
    uint8_t lfh_buf[sizeof(struct zip_local_header) + 4];
    struct zip_local_header *lfh = (struct zip_local_header *)lfh_buf;
    memset(lfh, 0, sizeof(*lfh));
    lfh->signature = ZIP_LOCAL_FILE_HEADER_SIG;
    lfh->version_needed = 20;
    lfh->filename_length = 4;
    memcpy(lfh_buf + sizeof(*lfh), name, 4);
    TEST_ASSERT_EQUAL(0, burst_writer_add_directory(writer, lfh, sizeof(lfh_buf), 040755, 0, 0));
    if (set_attrs) {
        burst_writer_set_entry_attrs(writer, "/", 1700000000);
    }
    TEST_ASSERT_EQUAL(0, burst_writer_finalize(writer));
    burst_writer_destroy(writer);
    return tmp;
}

// An entry with no recorded mtime gets no timestamp field, so restores don't set it to 1970.
void test_timestamp_field_only_with_recorded_mtime(void) {
    FILE *without = write_one_directory(false);
    TEST_ASSERT_FALSE(archive_has_timestamp_field(without));
    fclose(without);

    FILE *with = write_one_directory(true);
    TEST_ASSERT_TRUE(archive_has_timestamp_field(with));
    fclose(with);
}

int main(void) {
    UNITY_BEGIN();

    RUN_TEST(test_writer_create_destroy);
    RUN_TEST(test_writer_create_null_file);
    RUN_TEST(test_writer_buffered_write);
    RUN_TEST(test_writer_flush);
    RUN_TEST(test_writer_flush_empty);
    RUN_TEST(test_writer_write_null);
    RUN_TEST(test_writer_write_zero_bytes);
    RUN_TEST(test_writer_buffer_overflow);

    RUN_TEST(test_timestamp_field_only_with_recorded_mtime);
    return UNITY_END();
}
