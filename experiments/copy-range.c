/* Diagnostic for this sample, not the product export implementation.
 * Copies HEVC/AAC packet payloads and handles its single tmcd sample explicitly.
 * Arguments: source destination start_us end_us creation_iso adjust_timecode
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <libavformat/avformat.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/sha.h>
#include <libavutil/timecode.h>

static void check(int code, const char *operation) {
    if (code < 0) { fprintf(stderr, "%s: %s\n", operation, av_err2str(code)); exit(1); }
}

int main(int argc, char **argv) {
    if (argc != 7) return 2;
    if (access(argv[2], F_OK) == 0) { fprintf(stderr, "Destination exists\n"); return 2; }
    int64_t start = strtoll(argv[3], NULL, 10), end = strtoll(argv[4], NULL, 10);
    if (start < 0 || end <= start) return 2;
    int adjust = atoi(argv[6]);
    AVFormatContext *in = NULL, *out = NULL;
    check(avformat_open_input(&in, argv[1], NULL, NULL), "open source");
    check(avformat_find_stream_info(in, NULL), "probe source");
    if (in->nb_streams != 3) { fprintf(stderr, "Sample-specific probe expects three streams\n"); return 2; }
    AVPacket *packet = av_packet_alloc();
    uint32_t expected_timecode = 0;
    char tc_string[AV_TIMECODE_STR_SIZE] = {0};
    if (adjust) {
        if (in->streams[2]->codecpar->codec_tag != MKTAG('t','m','c','d')) return 2;
        int found = 0;
        while (av_read_frame(in, packet) >= 0) {
            if (packet->stream_index == 2) {
                if (packet->size != 4) return 2;
                uint32_t original = AV_RB32(packet->data);
                AVRational fps = in->streams[0]->avg_frame_rate;
                expected_timecode = av_rescale_q(original, av_inv_q(in->streams[2]->avg_frame_rate), av_inv_q(fps))
                    + av_rescale_q(start, AV_TIME_BASE_Q, av_inv_q(fps));
                AVTimecode tc;
                // This fixture uses a non-drop-frame timecode (colon-separated).
                check(av_timecode_init(&tc, fps, 0, expected_timecode, NULL), "timecode init");
                av_timecode_make_string(&tc, tc_string, 0);
                fprintf(stderr, "Regenerated timecode %s, frame counter %u\n", tc_string, expected_timecode);
                found = 1;
                av_packet_unref(packet);
                break;
            }
            av_packet_unref(packet);
        }
        if (!found) return 2;
    }
    check(avformat_alloc_output_context2(&out, NULL, "mp4", argv[2]), "output context");
    av_dict_copy(&out->metadata, in->metadata, 0);
    av_dict_set(&out->metadata, "creation_time", argv[5], 0);
    av_dict_set(&out->metadata, "com.apple.quicktime.creationdate", argv[5], 0);
    struct AVSHA *hashes[3];
    int counts[3] = {0};
    int64_t first[3] = {AV_NOPTS_VALUE, AV_NOPTS_VALUE, AV_NOPTS_VALUE};
    for (unsigned i = 0; i < in->nb_streams; i++) {
        hashes[i] = av_sha_alloc();
        if (!hashes[i]) return 1;
        av_sha_init(hashes[i], 256);
        if (adjust && i == 2) continue; // muxer regenerates the tmcd track.
        AVStream *src = in->streams[i], *dst = avformat_new_stream(out, NULL);
        if (!dst) return 1;
        check(avcodec_parameters_copy(dst->codecpar, src->codecpar), "copy parameters");
        dst->time_base = src->time_base;
        dst->avg_frame_rate = src->avg_frame_rate;
        dst->disposition = src->disposition;
        av_dict_copy(&dst->metadata, src->metadata, 0);
        av_dict_set(&dst->metadata, "creation_time", argv[5], 0);
        av_dict_set(&dst->metadata, "timecode", NULL, 0); // tmcd sample is authoritative.
        if (adjust && i == 0) av_dict_set(&dst->metadata, "timecode", tc_string, 0);
    }
    check(avio_open(&out->pb, argv[2], AVIO_FLAG_WRITE), "open destination");
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "write_tmcd", adjust ? "1" : "0", 0);
    av_dict_set(&opts, "movflags", "use_metadata_tags", 0);
    check(avformat_write_header(out, &opts), "write header");
    av_dict_free(&opts);
    check(av_seek_frame(in, 0, av_rescale_q(start, AV_TIME_BASE_Q, in->streams[0]->time_base), AVSEEK_FLAG_BACKWARD), "seek");
    int ret, done[3] = {0};
    if (adjust) done[2] = 1;
    while ((ret = av_read_frame(in, packet)) >= 0) {
        int i = packet->stream_index;
        if (adjust && i == 2) { av_packet_unref(packet); continue; }
        AVStream *src = in->streams[i], *dst = out->streams[i];
        int64_t a = av_rescale_q(start, AV_TIME_BASE_Q, src->time_base);
        int64_t b = av_rescale_q(end, AV_TIME_BASE_Q, src->time_base);
        if (src->codecpar->codec_tag == MKTAG('t','m','c','d')) {
            if (packet->size != 4 || counts[i] != 0) { fprintf(stderr, "Unexpected tmcd layout\n"); return 2; }
            uint32_t original = AV_RB32(packet->data);
            int64_t advance = av_rescale_q(start, AV_TIME_BASE_Q, av_inv_q(src->avg_frame_rate));
            check(av_packet_make_writable(packet), "writable timecode");
            if (adjust) AV_WB32(packet->data, original + advance);
            fprintf(stderr, "timecode original=%u advance=%lld applied=%d\n", original, (long long)advance, adjust);
            packet->pts = packet->dts = a;
            packet->duration = b - a;
            done[i] = 1;
        } else {
            if (packet->pts >= b) done[i] = 1;
            if (packet->pts < a || packet->pts >= b) {
                av_packet_unref(packet);
                if (done[0] && done[1] && done[2]) break;
                continue;
            }
        }
        if (first[i] == AV_NOPTS_VALUE) first[i] = packet->pts;
        av_sha_update(hashes[i], packet->data, packet->size);
        counts[i]++;
        packet->pts -= a;
        packet->dts -= a;
        av_packet_rescale_ts(packet, src->time_base, dst->time_base);
        packet->pos = -1;
        check(av_interleaved_write_frame(out, packet), "write packet");
        av_packet_unref(packet);
    }
    if (ret < 0 && ret != AVERROR_EOF) check(ret, "read packet");
    check(av_write_trailer(out), "write trailer");
    check(avio_closep(&out->pb), "close output");
    unsigned char expected[3][32];
    for (int i = 0; i < 3; i++) {
        av_sha_final(hashes[i], expected[i]);
        av_sha_init(hashes[i], 256);
        fprintf(stderr, "stream=%d count=%d first_input_pts=%lld\n", i, counts[i], (long long)first[i]);
    }
    avformat_free_context(out);
    avformat_close_input(&in);
    check(avformat_open_input(&in, argv[2], NULL, NULL), "reopen output");
    check(avformat_find_stream_info(in, NULL), "probe output");
    if (in->nb_streams != 3) { fprintf(stderr, "Stream count mismatch\n"); return 1; }
    int verified[3] = {0};
    while ((ret = av_read_frame(in, packet)) >= 0) {
        if (adjust && packet->stream_index == 2 &&
            (packet->size != 4 || AV_RB32(packet->data) != expected_timecode)) {
            fprintf(stderr, "Generated timecode mismatch\n"); return 1;
        }
        av_sha_update(hashes[packet->stream_index], packet->data, packet->size);
        verified[packet->stream_index]++;
        av_packet_unref(packet);
    }
    if (ret != AVERROR_EOF) check(ret, "verify read");
    for (int i = 0; i < 3; i++) {
        unsigned char actual[32];
        av_sha_final(hashes[i], actual);
        if (adjust && i == 2) {
            if (verified[i] != 1) return 1;
            printf("stream=2 regenerated_timecode=%s counter=%u VERIFIED\n", tc_string, expected_timecode);
            av_free(hashes[i]);
            continue;
        }
        if (memcmp(expected[i], actual, 32) || counts[i] != verified[i]) { fprintf(stderr, "Payload mismatch\n"); return 1; }
        printf("stream=%d packets=%d payload_sha256=", i, verified[i]);
        for (int j = 0; j < 32; j++) printf("%02x", actual[j]);
        printf(" MATCH\n");
        av_free(hashes[i]);
    }
    av_packet_free(&packet);
    avformat_close_input(&in);
    return 0;
}
