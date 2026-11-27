#pragma once
#include <stdint.h>

/// Minimal zero-latency H.264 encoder on top of libx264, loaded with dlopen so the
/// app still builds and runs where libx264 is missing. Used when VideoToolbox has no
/// hardware H.264 encoder (its software encoder buffers ~20 frames, ~360 ms).
typedef struct x264shim x264shim;

/// NULL when libx264 cannot be loaded or the encoder cannot be opened.
x264shim *x264shim_open(int width, int height, int fps, int bitrate_kbps);

/// Encodes one NV12 frame. Returns the Annex B size written to *out (valid until the
/// next call), 0 when the encoder produced nothing, or -1 on error.
int x264shim_encode(x264shim *s, const uint8_t *y, int y_stride, const uint8_t *uv, int uv_stride,
                    int force_keyframe, const uint8_t **out, int *is_keyframe);

void x264shim_set_bitrate(x264shim *s, int bitrate_kbps);
void x264shim_close(x264shim *s);
