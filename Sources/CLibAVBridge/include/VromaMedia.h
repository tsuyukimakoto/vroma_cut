#ifndef VROMA_MEDIA_H
#define VROMA_MEDIA_H
#include <stdint.h>
#include <stddef.h>

typedef struct { int64_t value; int32_t scale; } VCTime;
typedef struct VCControl VCControl;
VCControl *vc_control_create(void);
void vc_control_cancel(VCControl *control);
void vc_control_set_full_decode(VCControl *control, int enabled);
typedef struct { int phase; int64_t completed, total; } VCProgress;
VCProgress vc_control_progress(VCControl *control);
void vc_control_free(VCControl *control);
typedef struct {
    VCTime start, end;
    int64_t first_dts, end_dts, source_bytes_read;
    int video_stream, audio_stream, timecode_stream;
    uint32_t timecode_counter;
} VCPlan;
typedef struct {
    int64_t video_packets, audio_packets, decoded_frames, source_bytes_read;
    char video_sha256[65], audio_sha256[65];
    char video_timing_sha256[65], audio_timing_sha256[65];
    int timecode_regenerated;
    int audio_boundary_adjustments;
} VCResult;
// Returns 0 on success. No AV pointers or structs cross the interface.
int vc_plan(const char *source, VCTime requested_start, VCTime requested_end, VCPlan *plan, char *error, size_t capacity, VCControl *control);
int vc_export(const char *source, const char *destination, const VCPlan *plan,
              const char *creation_date, VCResult *result, char *error, size_t capacity, VCControl *control);
int vc_export_segments(const char *const *sources, const VCPlan *plans, int count, const char *destination, const char *creation_date, VCResult *result, char *error, size_t capacity, VCControl *control);
const char *vc_version(void);
#endif
