/*
 * test_metadata_abi.c — 元数据快路径 C ABI（zk_metadata_*）回归
 *
 * 验证 docs/audio-kernel-zig.md §8.4.2① 的结构化 ABI（无 JSON）：
 *   - zk_metadata_open 一次调用取回标量 + 全量 tags + 首张封面（不触发 PCM 解码）
 *   - 指针生命周期与句柄一致，zk_metadata_close 后释放
 *   - 并发协商 set/get 往返
 *
 * 用法: test_metadata_abi <file>
 */
#include "kernel_bridge.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, msg)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "FAIL: %s\n", msg);                                \
            failures++;                                                        \
        }                                                                      \
    } while (0)

static const char *cstr_buf(const char *p, int len, char *buf, size_t cap) {
    if (!p) return "(null)";
    int n = len < (int)cap - 1 ? len : (int)cap - 1;
    memcpy(buf, p, (size_t)n);
    buf[n] = 0;
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file>\n", argv[0]);
        return 2;
    }

    /* 并发协商往返 */
    zk_metadata_set_concurrency(6);
    CHECK(zk_metadata_get_concurrency() == 6, "set/get concurrency == 6");
    zk_metadata_set_concurrency(0);
    CHECK(zk_metadata_get_concurrency() == 0, "reset concurrency == 0");

    char err[64] = {0};
    ZkMetaInfo m;
    memset(&m, 0, sizeof(m));
    ZkMetaHandle *h = zk_metadata_open(argv[1], &m, err, (int)sizeof(err));
    CHECK(h != NULL, "zk_metadata_open returns handle");
    if (!h) return 1;

    printf("codec=%s format=%s sr=%d ch=%d bps=%d dur_us=%lld known=%d\n",
           m.codec_name ? m.codec_name : "(null)",
           m.format_name ? m.format_name : "(null)",
           m.sample_rate, m.channels, m.bits_per_sample, m.duration_us,
           m.duration_known);

    CHECK(m.sample_rate > 0, "sample_rate > 0");
    CHECK(m.channels > 0, "channels > 0");
    CHECK(m.bits_per_sample > 0, "bits_per_sample > 0");
    CHECK(m.duration_us > 0, "duration_us > 0");
    CHECK(m.codec_name != NULL && m.codec_name[0], "codec_name present");
    CHECK(m.format_name != NULL && m.format_name[0], "format_name present");

    printf("title=%s artist=%s album=%s tags=%d cover=%d bytes\n",
           m.title ? m.title : "(null)",
           m.artist ? m.artist : "(null)",
           m.album ? m.album : "(null)",
           m.tags_count, m.cover_size);

    /* fixture（native_seek_fixture.flac）带 PICTURE，tags 至少含标准字段 */
    CHECK(m.tags_count > 0, "tags_count > 0");
    CHECK(m.tags != NULL, "tags pointer present");
    CHECK(m.cover_size > 0, "cover present");
    CHECK(m.cover_data != NULL, "cover data pointer present");
    CHECK(m.cover_mime != NULL && m.cover_mime_len > 0, "cover mime present");

    int saw_title = 0;
    for (int i = 0; i < m.tags_count; i++) {
        const ZkTag *t = &m.tags[i];
        char kb[256], vb[512];
        printf("  tag[%d] %s = %s\n", i,
               cstr_buf(t->key, t->key_len, kb, sizeof(kb)),
               cstr_buf(t->value, t->value_len, vb, sizeof(vb)));
        CHECK(t->key != NULL, "tag key present");
        if (t->key && t->key_len == 5 &&
            (!strncmp(t->key, "TITLE", 5) || !strncmp(t->key, "title", 5)))
            saw_title = 1;
    }
    CHECK(saw_title, "TITLE tag present");

    zk_metadata_close(h);

    /* NULL 句柄空操作 */
    zk_metadata_close(NULL);

    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}
