#include "VromaMedia.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/timecode.h>
#include <libavutil/mem.h>
#include <libavutil/mathematics.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <CommonCrypto/CommonDigest.h>

struct VCControl { atomic_int cancelled; int full_decode; atomic_int phase; atomic_llong completed, total; };
VCControl *vc_control_create(void) { VCControl *c = malloc(sizeof(*c)); if (c) { atomic_init(&c->cancelled, 0); c->full_decode = 0; atomic_init(&c->phase, 0); atomic_init(&c->completed, 0); atomic_init(&c->total, 0); } return c; }
void vc_control_cancel(VCControl *c) { if (c) atomic_store(&c->cancelled, 1); }
void vc_control_set_full_decode(VCControl *c, int enabled) { if (c) c->full_decode = enabled; }
VCProgress vc_control_progress(VCControl *c) {
    if (!c) return (VCProgress){0};
    return (VCProgress){atomic_load(&c->phase), atomic_load(&c->completed), atomic_load(&c->total)};
}
static void progress(VCControl *c, int phase, int64_t completed, int64_t total) {
    if (!c) return;
    atomic_store(&c->total, total); atomic_store(&c->completed, completed); atomic_store(&c->phase, phase);
}
void vc_control_free(VCControl *c) { free(c); }
static int cancelled(void *opaque) { VCControl *c = opaque; return c && atomic_load(&c->cancelled); }

static int fail(char *error, size_t cap, const char *message, int code) {
    char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (code < 0) av_strerror(code, detail, sizeof(detail));
    snprintf(error, cap, "%s%s%s", message, code < 0 ? ": " : "", detail);
    return -1;
}
static int open_input(const char *path, AVFormatContext **ctx, char *error, size_t cap, VCControl *control) {
    if (cancelled(control)) return fail(error, cap, "Cancelled", 0);
    *ctx = avformat_alloc_context();
    if (!*ctx) return fail(error, cap, "Input allocation failed", 0);
    (*ctx)->interrupt_callback = (AVIOInterruptCB){cancelled, control};
    int ret = avformat_open_input(ctx, path, NULL, NULL);
    if (ret < 0) return fail(error, cap, "Cannot open source", ret);
    ret = avformat_find_stream_info(*ctx, NULL);
    if (ret < 0) return fail(error, cap, "Cannot inspect streams", ret);
    return 0;
}
static int inspect(AVFormatContext *ctx, VCPlan *p, char *error, size_t cap) {
    p->video_stream = p->audio_stream = p->timecode_stream = -1;
    for (unsigned i = 0; i < ctx->nb_streams; i++) {
        AVStream *s = ctx->streams[i];
        if (s->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && s->codecpar->codec_id == AV_CODEC_ID_HEVC && p->video_stream < 0) {
            if (s->time_base.num != 1 || s->start_time != 0 || s->codecpar->extradata_size < 23 || s->codecpar->extradata[0] != 1)
                return fail(error, cap, "Unsupported HEVC timing or configuration", 0);
            p->video_stream = (int)i;
        } else if (s->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && s->codecpar->codec_id == AV_CODEC_ID_AAC && p->audio_stream < 0) {
            if (s->time_base.num != 1) return fail(error, cap, "Unsupported audio time base", 0);
            p->audio_stream = (int)i;
        } else if (s->codecpar->codec_tag == MKTAG('t','m','c','d') && p->timecode_stream < 0) {
            // Single, non-drop-frame sample only. Never silently discard another data stream.
            if (s->codecpar->extradata_size < 17 || (AV_RB32(s->codecpar->extradata + 4) & 1) || s->avg_frame_rate.num <= 0 || s->avg_frame_rate.den <= 0)
                return fail(error, cap, "Unsupported timecode representation", 0);
            p->timecode_stream = (int)i;
        } else return fail(error, cap, "Unsupported or additional stream; export stopped", 0);
    }
    if (p->video_stream < 0 || p->audio_stream < 0) return fail(error, cap, "One HEVC video and one AAC audio stream required", 0);
    return 0;
}
// Accept IDR access units only. CRA flags alone do not establish independence.
static int is_idr(const AVPacket *packet, AVStream *stream) {
    int width = (stream->codecpar->extradata[21] & 3) + 1;
    size_t pos = 0; int found = 0;
    while (pos < (size_t)packet->size) {
        if ((size_t)packet->size - pos < (size_t)width) return 0;
        uint32_t length = 0;
        for (int i = 0; i < width; i++) length = (length << 8) | packet->data[pos++];
        if (length < 2 || length > (size_t)packet->size - pos) return 0;
        int type = (packet->data[pos] >> 1) & 63;
        if (type <= 31) { if (type != 19 && type != 20) return 0; found = 1; }
        pos += length;
    }
    return found;
}
// A MOV sample table gives the location of the single supported tmcd sample.
// Read those four bytes, not every media packet in the file.
static int read_timecode(const char *path, AVFormatContext *in, int stream, uint32_t *counter, int64_t *position, char *error, size_t cap) {
    AVStream *st = in->streams[stream];
    if (st->nb_frames != 1 || avformat_index_get_entries_count(st) != 1)
        return fail(error, cap, "Unsupported timecode sample count", 0);
    const AVIndexEntry *entry = avformat_index_get_entry(st, 0);
    if (!entry || entry->size != 4 || entry->timestamp != 0 || entry->pos < 0)
        return fail(error, cap, "Unsupported timecode sample index", 0);
    int64_t pos = entry->pos;
    int fd = open(path, O_RDONLY); unsigned char bytes[4];
    if (fd < 0) return fail(error, cap, "Cannot read timecode", 0);
    ssize_t n = pread(fd, bytes, 4, pos); close(fd);
    if (n != 4) return fail(error, cap, "Truncated timecode", 0);
    *counter = AV_RB32(bytes); if (position) *position = pos;
    return 0;
}
const char *vc_version(void) { return av_version_info(); }
int vc_plan(const char *source, VCTime start, VCTime end, VCPlan *plan, char *error, size_t cap, VCControl *control) {
    AVFormatContext *in = NULL; AVPacket *packet = NULL; int status = -1, ret;
    memset(plan, 0, sizeof(*plan)); plan->first_dts = plan->end_dts = AV_NOPTS_VALUE;
    if (start.scale <= 0 || end.scale <= 0 || start.value < 0 || av_compare_ts(start.value, (AVRational){1, start.scale}, end.value, (AVRational){1, end.scale}) >= 0) return fail(error, cap, "Invalid requested range", 0);
    if (open_input(source, &in, error, cap, control) || inspect(in, plan, error, cap)) goto cleanup;
    AVStream *video = in->streams[plan->video_stream];
    const int64_t requested_start = av_rescale_q_rnd(start.value, (AVRational){1, start.scale}, video->time_base, AV_ROUND_DOWN);
    const int64_t requested_end = av_rescale_q_rnd(end.value, (AVRational){1, end.scale}, video->time_base, AV_ROUND_UP);
    if (plan->timecode_stream >= 0 && read_timecode(source, in, plan->timecode_stream, &plan->timecode_counter, NULL, error, cap)) goto cleanup;
    packet = av_packet_alloc(); if (!packet) { fail(error, cap, "Allocation failed", 0); goto cleanup; }
    // Seek using the MOV index, then inspect actual NAL units. A key flag is
    // only a search hint: CRA still cannot substitute for a verified IDR.
    int64_t seek = requested_start, step = video->time_base.den;
    for (;;) {
        if (cancelled(control)) { fail(error, cap, "Cancelled", 0); goto cleanup; }
        if ((ret = av_seek_frame(in, plan->video_stream, seek, AVSEEK_FLAG_BACKWARD)) < 0) { fail(error, cap, "Start seek failed", ret); goto cleanup; }
        while ((ret = av_read_frame(in, packet)) >= 0) {
            if (cancelled(control)) { fail(error, cap, "Cancelled", 0); goto cleanup; }
            if (packet->stream_index == plan->video_stream) {
                if (packet->pts == AV_NOPTS_VALUE || packet->dts == AV_NOPTS_VALUE || packet->duration <= 0) { fail(error, cap, "Missing video timestamps", 0); goto cleanup; }
                if (packet->pts > requested_start) { av_packet_unref(packet); break; }
                if (is_idr(packet, video)) { plan->start.value = packet->pts; plan->first_dts = packet->dts; }
            }
            av_packet_unref(packet);
        }
        if (ret < 0 && ret != AVERROR_EOF) { fail(error, cap, "Start scan failed", ret); goto cleanup; }
        if (plan->first_dts != AV_NOPTS_VALUE || seek == 0) break;
        seek = seek > step ? seek - step : 0;
        if (step < INT64_MAX / 2) step *= 2;
    }
    if (plan->first_dts == AV_NOPTS_VALUE) { fail(error, cap, "No preceding independent IDR", 0); goto cleanup; }
    if ((ret = av_seek_frame(in, plan->video_stream, requested_end, AVSEEK_FLAG_BACKWARD)) < 0) { fail(error, cap, "End seek failed", ret); goto cleanup; }
    int64_t max_end = 0;
    while ((ret = av_read_frame(in, packet)) >= 0) {
        if (cancelled(control)) { fail(error, cap, "Cancelled", 0); goto cleanup; }
        if (packet->stream_index == plan->video_stream) {
            if (packet->pts == AV_NOPTS_VALUE || packet->dts == AV_NOPTS_VALUE || packet->duration <= 0 || packet->pts > INT64_MAX - packet->duration) { fail(error, cap, "Invalid video timestamps", 0); goto cleanup; }
            if (packet->pts >= requested_end && is_idr(packet, video)) { plan->end.value = packet->pts; plan->end_dts = packet->dts; av_packet_unref(packet); break; }
            if (packet->pts + packet->duration > max_end) max_end = packet->pts + packet->duration;
        }
        av_packet_unref(packet);
    }
    if (ret < 0 && ret != AVERROR_EOF) { fail(error, cap, "End scan failed", ret); goto cleanup; }
    if (plan->end_dts == AV_NOPTS_VALUE && ret == AVERROR_EOF) { plan->end.value = max_end; plan->end_dts = INT64_MAX; }
    if (plan->end.value < requested_end || plan->end.value <= plan->start.value) { fail(error, cap, "Cannot contain requested range", 0); goto cleanup; }
    plan->start.scale = plan->end.scale = video->time_base.den;
    plan->source_bytes_read = in->pb ? in->pb->bytes_read : 0;
    status = 0;
cleanup:
    av_packet_free(&packet); avformat_close_input(&in); return status;
}
static void hash_text(CC_SHA256_CTX *hash, char *text) {
    unsigned char bytes[32]; CC_SHA256_Final(bytes, hash);
    for (int i = 0; i < 32; i++) snprintf(text + i * 2, 3, "%02x", bytes[i]);
}
static void hash_timing(CC_SHA256_CTX *hash, const AVPacket *packet) {
    unsigned char bytes[24];
    AV_WB64(bytes, packet->pts); AV_WB64(bytes + 8, packet->dts); AV_WB64(bytes + 16, packet->duration);
    CC_SHA256_Update(hash, bytes, sizeof(bytes));
}
// mov_create_timecode_track in FFmpeg 8.0 initializes DTS from the counter
// in movie timescale, which can exceed INT_MAX at ordinary wall-clock values.
// Generate at zero, then set the one generated 4-byte sample by its demuxed
// file position. This operates solely on our staged output, never the source.
static int finalize_timecode(const char *path, uint32_t counter, char *error, size_t cap, VCControl *control) {
    AVFormatContext *ctx = NULL; FILE *file = NULL;
    int status = -1, stream = -1; int64_t position = -1; uint32_t original;
    if (open_input(path, &ctx, error, cap, control)) goto cleanup;
    for (unsigned i = 0; i < ctx->nb_streams; i++) if (ctx->streams[i]->codecpar->codec_tag == MKTAG('t','m','c','d')) {
        if (stream >= 0) { fail(error, cap, "Multiple generated timecode streams", 0); goto cleanup; }
        stream = (int)i;
    }
    if (stream < 0 || read_timecode(path, ctx, stream, &original, &position, error, cap) || original != 0) { fail(error, cap, "Unexpected generated timecode", 0); goto cleanup; }
    avformat_close_input(&ctx);
    file = fopen(path, "r+b");
    unsigned char bytes[4]; AV_WB32(bytes, counter);
    if (!file || fseeko(file, position, SEEK_SET) || fwrite(bytes, 1, 4, file) != 4 || fflush(file)) { fail(error, cap, "Cannot finalize generated timecode", 0); goto cleanup; }
    status = 0;
cleanup:
    if (file && fclose(file)) status = fail(error, cap, "Timecode close failed", 0);
    avformat_close_input(&ctx); return status;
}

int vc_export_segments(const char *const *sources, const VCPlan *plans, int count, const char *destination, const char *date,
              VCResult *result, char *error, size_t cap, VCControl *control) {
    if (count < 1) return fail(error, cap, "Empty source list", 0);
    const char *source = sources[0]; const VCPlan *plan = &plans[0];
    AVFormatContext *in = NULL, *out = NULL, *verify = NULL;
    AVPacket *packet = NULL; AVFrame *frame = NULL; AVCodecContext *decoder = NULL;
    CC_SHA256_CTX *hashes[4] = {NULL, NULL, NULL, NULL}; AVDictionary *options = NULL;
    int status = -1, ret, mapping[3] = {-1, -1, -1};
    memset(result, 0, sizeof(*result));
    if (open_input(source, &in, error, cap, control)) goto cleanup;
    VCPlan check = {0}; if (inspect(in, &check, error, cap)) goto cleanup;
    if (check.video_stream != plan->video_stream || check.audio_stream != plan->audio_stream || check.timecode_stream != plan->timecode_stream || in->nb_streams > 3 || plan->start.scale != in->streams[plan->video_stream]->time_base.den) {
        fail(error, cap, "Source differs from export plan", 0); goto cleanup;
    }
    ret = avformat_alloc_output_context2(&out, NULL, "mp4", destination);
    if (ret < 0 || !out) { fail(error, cap, "Output allocation failed", ret); goto cleanup; }
    av_dict_copy(&out->metadata, in->metadata, 0);
    av_dict_set(&out->metadata, "creation_time", date, 0);
    av_dict_set(&out->metadata, "com.apple.quicktime.creationdate", date, 0);
    // Swift adds the precise date to a movie-level QuickTime meta box after this controlled mux.
    av_dict_set(&out->metadata, "timecode", NULL, 0);
    char timecode[AV_TIMECODE_STR_SIZE] = {0}; uint32_t expected_counter = 0;
    if (plan->timecode_stream >= 0) {
        AVRational fps = in->streams[plan->video_stream]->avg_frame_rate;
        int64_t counter = av_rescale_q(plan->timecode_counter, av_inv_q(in->streams[plan->timecode_stream]->avg_frame_rate), av_inv_q(fps))
            + av_rescale_q(plan->start.value, (AVRational){1, plan->start.scale}, av_inv_q(fps));
        if (counter < 0 || counter > INT_MAX) { fail(error, cap, "Timecode out of range", 0); goto cleanup; }
        expected_counter = (uint32_t)counter;
        AVTimecode tc; ret = av_timecode_init(&tc, fps, 0, (int)counter, NULL);
        if (ret < 0) { fail(error, cap, "Timecode initialization failed", ret); goto cleanup; }
        snprintf(timecode, sizeof(timecode), "00:00:00:00"); result->timecode_regenerated = 1;
    }
    for (unsigned i = 0; i < in->nb_streams; i++) {
        if ((int)i == plan->timecode_stream) continue;
        AVStream *src = in->streams[i], *dst = avformat_new_stream(out, NULL);
        if (!dst) { fail(error, cap, "Stream allocation failed", 0); goto cleanup; }
        mapping[i] = dst->index;
        if ((ret = avcodec_parameters_copy(dst->codecpar, src->codecpar)) < 0) { fail(error, cap, "Parameter copy failed", ret); goto cleanup; }
        dst->time_base = src->time_base; dst->avg_frame_rate = src->avg_frame_rate; dst->disposition = src->disposition;
        av_dict_copy(&dst->metadata, src->metadata, 0); av_dict_set(&dst->metadata, "creation_time", date, 0); av_dict_set(&dst->metadata, "timecode", NULL, 0);
        if ((int)i == plan->video_stream && timecode[0]) av_dict_set(&dst->metadata, "timecode", timecode, 0);
    }
    // Destination must be an exclusively owned staging file created by the Swift coordinator.
    if ((ret = avio_open(&out->pb, destination, AVIO_FLAG_WRITE)) < 0) { fail(error, cap, "Cannot open staging output", ret); goto cleanup; }
    av_dict_set(&options, "write_tmcd", timecode[0] ? "1" : "0", 0);
    av_dict_set(&options, "movflags", "use_metadata_tags", 0);
    int64_t video_scale = in->streams[plan->video_stream]->time_base.den;
    int64_t audio_scale = in->streams[plan->audio_stream]->time_base.den;
    int64_t movie_scale = video_scale / av_gcd(video_scale, audio_scale) * audio_scale;
    if (movie_scale > INT_MAX) { fail(error, cap, "Cannot represent track timing in movie timescale", 0); goto cleanup; }
    av_dict_set_int(&options, "movie_timescale", movie_scale, 0);
    if ((ret = avformat_write_header(out, &options)) < 0) { fail(error, cap, "MP4 header failed", ret); goto cleanup; }
    for (int i = 0; i < 4; i++) { hashes[i] = av_malloc(sizeof(CC_SHA256_CTX)); if (!hashes[i]) { fail(error, cap, "Hash allocation failed", 0); goto cleanup; } CC_SHA256_Init(hashes[i]); }
    packet = av_packet_alloc(); if (!packet) { fail(error, cap, "Packet allocation failed", 0); goto cleanup; }
    AVPacket previous_audio = {0}; int previous_audio_part = -1;
    int64_t timeline_offset = 0, total_duration = 0;
    for (int part = 0; part < count; part++) {
        if (plans[part].start.scale != video_scale || plans[part].end.scale != video_scale) { fail(error, cap, "Chapter video time bases differ", 0); goto cleanup; }
        total_duration += plans[part].end.value - plans[part].start.value;
    }
    for (int part = 0; part < count; part++) {
        plan = &plans[part]; source = sources[part];
        if (part > 0) {
            avformat_close_input(&in);
            if (open_input(source, &in, error, cap, control)) goto cleanup;
            VCPlan check = {0};
            if (inspect(in, &check, error, cap) || check.video_stream != plans[0].video_stream || check.audio_stream != plans[0].audio_stream || check.timecode_stream != plans[0].timecode_stream || in->nb_streams > 3) { fail(error, cap, "Chapter stream layout differs", 0); goto cleanup; }
            for (unsigned i = 0; i < in->nb_streams; i++) {
                if ((int)i == plan->timecode_stream) continue;
                AVStream *src = in->streams[i], *dst = out->streams[mapping[i]];
                AVCodecParameters *a = src->codecpar, *b = dst->codecpar;
                if (a->nb_coded_side_data != b->nb_coded_side_data) { fail(error, cap, "Chapter display metadata differs", 0); goto cleanup; }
                for (int side = 0; side < a->nb_coded_side_data; side++) {
                    const AVPacketSideData *other = av_packet_side_data_get(b->coded_side_data, b->nb_coded_side_data, a->coded_side_data[side].type);
                    if (!other || other->size != a->coded_side_data[side].size || memcmp(other->data, a->coded_side_data[side].data, other->size)) { fail(error, cap, "Chapter rotation or display metadata differs", 0); goto cleanup; }
                }
                if (av_cmp_q(src->time_base, dst->time_base) || a->codec_id != b->codec_id || a->format != b->format || a->color_range != b->color_range || a->color_primaries != b->color_primaries || a->color_trc != b->color_trc || a->color_space != b->color_space || a->field_order != b->field_order || av_cmp_q(a->sample_aspect_ratio, b->sample_aspect_ratio) || a->width != b->width || a->height != b->height || a->sample_rate != b->sample_rate || av_channel_layout_compare(&a->ch_layout, &b->ch_layout) || a->extradata_size != b->extradata_size || (a->extradata_size && memcmp(a->extradata, b->extradata, a->extradata_size))) { fail(error, cap, "Chapter codec configuration differs; cannot join without encoding", 0); goto cleanup; }
            }
        }
        if ((ret = av_seek_frame(in, plan->video_stream, plan->start.value, AVSEEK_FLAG_BACKWARD)) < 0) { fail(error, cap, "Copy seek failed", ret); goto cleanup; }
        progress(control, 1, timeline_offset, total_duration);
        int64_t minimum_pts = INT64_MAX, maximum_end = 0;
        int done[2] = {0, 0}; int first_video = 1;
        while ((ret = av_read_frame(in, packet)) >= 0) {
            if (cancelled(control)) { fail(error, cap, "Cancelled", 0); goto cleanup; }
            int i = packet->stream_index, kind = i == plan->video_stream ? 0 : 1;
            if (i == plan->timecode_stream) { av_packet_unref(packet); continue; }
            AVStream *src = in->streams[i], *dst = out->streams[mapping[i]];
            int64_t start = av_rescale_q(plan->start.value, (AVRational){1, plan->start.scale}, src->time_base);
            int64_t end = av_rescale_q(plan->end.value, (AVRational){1, plan->end.scale}, src->time_base);
            int take;
            if (kind == 0) { take = packet->dts >= plan->first_dts && packet->dts < plan->end_dts; if (packet->dts >= plan->end_dts) done[0] = 1; }
            else { take = packet->pts >= start && packet->pts < end; if (packet->pts >= end) done[1] = 1; }
            if (done[0] && done[1]) { av_packet_unref(packet); ret = AVERROR_EOF; break; }
            if (!take) { av_packet_unref(packet); continue; }
            if (packet->pts == AV_NOPTS_VALUE || packet->dts == AV_NOPTS_VALUE || packet->duration <= 0 || packet->pts < start || (kind == 0 && packet->pts + packet->duration > end)) {
                fail(error, cap, "Selected packets exceed the independent presentation range", 0); goto cleanup;
            }
            if (kind == 0) {
                if (first_video && (packet->dts != plan->first_dts || packet->pts != plan->start.value || !is_idr(packet, src))) { fail(error, cap, "Copy does not begin at planned IDR", 0); goto cleanup; }
                if (packet->pts < minimum_pts) minimum_pts = packet->pts;
                if (packet->pts + packet->duration > maximum_end) maximum_end = packet->pts + packet->duration;
                first_video = 0; result->video_packets++;
                progress(control, 1, timeline_offset + maximum_end - plan->start.value, total_duration);
            } else result->audio_packets++;
            CC_SHA256_Update(hashes[kind], packet->data, packet->size);
            int64_t offset = av_rescale_q(timeline_offset, (AVRational){1, (int)video_scale}, src->time_base);
            packet->pts += offset - start; packet->dts += offset - start;
            av_packet_rescale_ts(packet, src->time_base, dst->time_base); packet->stream_index = dst->index; packet->pos = -1;
            if (kind == 1) {
                if (previous_audio_part >= 0) {
                    if (previous_audio_part != part) {
                        // MP4 stts stores the interval to the next sample (movenc.c
                        // get_cluster_duration). Only the chapter seam can differ
                        // from an AAC frame's nominal duration. PTS/DTS and payload
                        // remain unchanged; verify the explicitly computed interval.
                        int64_t interval = packet->dts - previous_audio.dts;
                        if (interval <= 0 || interval > 2 * previous_audio.duration) { fail(error, cap, "Discontinuous chapter audio timestamps", 0); goto cleanup; }
                        if (interval != previous_audio.duration) result->audio_boundary_adjustments++;
                        previous_audio.duration = interval;
                    }
                    hash_timing(hashes[3], &previous_audio);
                }
                previous_audio.pts = packet->pts; previous_audio.dts = packet->dts; previous_audio.duration = packet->duration; previous_audio_part = part;
            } else hash_timing(hashes[2], packet);
            if ((ret = av_interleaved_write_frame(out, packet)) < 0) { fail(error, cap, "Packet write failed", ret); goto cleanup; }
            av_packet_unref(packet);
        }
        if (ret != AVERROR_EOF || minimum_pts != plan->start.value || maximum_end != plan->end.value || !result->audio_packets) { fail(error, cap, "Output range verification failed", ret == AVERROR_EOF ? 0 : ret); goto cleanup; }
        result->source_bytes_read += in->pb ? in->pb->bytes_read : 0;
        timeline_offset += plan->end.value - plan->start.value;
    }
    if (previous_audio_part >= 0) hash_timing(hashes[3], &previous_audio);
    plan = &plans[0];
    if ((ret = av_write_trailer(out)) < 0) { fail(error, cap, "MP4 trailer failed", ret); goto cleanup; }
    if ((ret = avio_closep(&out->pb)) < 0) { fail(error, cap, "Output close failed", ret); goto cleanup; }
    if (result->timecode_regenerated && finalize_timecode(destination, expected_counter, error, cap, control)) goto cleanup;
    hash_text(hashes[0], result->video_sha256); hash_text(hashes[1], result->audio_sha256);
    hash_text(hashes[2], result->video_timing_sha256); hash_text(hashes[3], result->audio_timing_sha256);
    for (int i = 0; i < 4; i++) CC_SHA256_Init(hashes[i]);
    if (open_input(destination, &verify, error, cap, control)) goto cleanup;
    if (verify->nb_streams != in->nb_streams) { fail(error, cap, "Output stream count mismatch", 0); goto cleanup; }
    int vi = mapping[plan->video_stream], ai = mapping[plan->audio_stream];
    if (control && control->full_decode) {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    decoder = avcodec_alloc_context3(codec); frame = av_frame_alloc();
    if (!decoder || !frame) { fail(error, cap, "Decoder allocation failed", 0); goto cleanup; }
    decoder->err_recognition = AV_EF_EXPLODE;
    if ((ret = avcodec_parameters_to_context(decoder, verify->streams[vi]->codecpar)) < 0 || (ret = avcodec_open2(decoder, codec, NULL)) < 0) { fail(error, cap, "Decoder open failed", ret); goto cleanup; }
    }
    progress(control, 2, 0, result->video_packets + result->audio_packets);
    int64_t counts[2] = {0, 0}, first_display = INT64_MAX; int timecodes = 0;
    while ((ret = av_read_frame(verify, packet)) >= 0) {
        if (cancelled(control)) { fail(error, cap, "Cancelled", 0); goto cleanup; }
        int kind = packet->stream_index == vi ? 0 : packet->stream_index == ai ? 1 : 2;
        if (kind == 2) {
            if (!result->timecode_regenerated || packet->size != 4 || AV_RB32(packet->data) != expected_counter || verify->streams[packet->stream_index]->codecpar->codec_tag != MKTAG('t','m','c','d')) { fail(error, cap, "Regenerated timecode mismatch", 0); goto cleanup; }
            timecodes++;
        } else {
            CC_SHA256_Update(hashes[kind], packet->data, packet->size); counts[kind]++;
            progress(control, 2, counts[0] + counts[1], result->video_packets + result->audio_packets);
            av_packet_rescale_ts(packet, verify->streams[packet->stream_index]->time_base, out->streams[packet->stream_index]->time_base);
            hash_timing(hashes[kind + 2], packet);
            if (kind == 0) {
                if (counts[0] == 1 && !is_idr(packet, verify->streams[vi])) { fail(error, cap, "Output lacks initial IDR", 0); goto cleanup; }
                if (packet->pts < first_display) first_display = packet->pts;
            }
            if (kind == 0 && decoder) {
                if ((ret = avcodec_send_packet(decoder, packet)) < 0) { fail(error, cap, "Decode send failed", ret); goto cleanup; }
                while ((ret = avcodec_receive_frame(decoder, frame)) >= 0) { result->decoded_frames++; if (frame->best_effort_timestamp < first_display) first_display = frame->best_effort_timestamp; av_frame_unref(frame); }
                if (ret != AVERROR(EAGAIN)) { fail(error, cap, "Video decode failed", ret); goto cleanup; }
            }
        }
        av_packet_unref(packet);
    }
    if (ret != AVERROR_EOF) { fail(error, cap, "Output read failed", ret); goto cleanup; }
    if (decoder) {
    if ((ret = avcodec_send_packet(decoder, NULL)) < 0) { fail(error, cap, "Decoder drain failed", ret); goto cleanup; }
    while ((ret = avcodec_receive_frame(decoder, frame)) >= 0) { result->decoded_frames++; if (frame->best_effort_timestamp < first_display) first_display = frame->best_effort_timestamp; av_frame_unref(frame); }
    }
    char actual[4][65]; for (int i = 0; i < 4; i++) hash_text(hashes[i], actual[i]);
    if (ret != AVERROR_EOF || counts[0] != result->video_packets || counts[1] != result->audio_packets || (decoder && result->decoded_frames != result->video_packets) || first_display != 0 || timecodes != result->timecode_regenerated || strcmp(actual[0], result->video_sha256) || strcmp(actual[1], result->audio_sha256) || strcmp(actual[2], result->video_timing_sha256) || strcmp(actual[3], result->audio_timing_sha256)) {
        snprintf(error, cap, "Verification failed: video=%lld/%lld audio=%lld/%lld decoded=%lld origin=%lld tc=%d/%d hashes=%d,%d,%d,%d", (long long)counts[0], (long long)result->video_packets, (long long)counts[1], (long long)result->audio_packets, (long long)result->decoded_frames, (long long)first_display, timecodes, result->timecode_regenerated, strcmp(actual[0], result->video_sha256), strcmp(actual[1], result->audio_sha256), strcmp(actual[2], result->video_timing_sha256), strcmp(actual[3], result->audio_timing_sha256)); goto cleanup;
    }
    status = 0;
cleanup:
    av_dict_free(&options); av_packet_free(&packet); av_frame_free(&frame); avcodec_free_context(&decoder);
    for (int i = 0; i < 4; i++) av_free(hashes[i]);
    avformat_close_input(&in); avformat_close_input(&verify);
    if (out) { if (out->pb) avio_closep(&out->pb); avformat_free_context(out); }
    return status;
}

int vc_export(const char *source, const char *destination, const VCPlan *plan, const char *date,
              VCResult *result, char *error, size_t cap, VCControl *control) {
    return vc_export_segments(&source, plan, 1, destination, date, result, error, cap, control);
}
