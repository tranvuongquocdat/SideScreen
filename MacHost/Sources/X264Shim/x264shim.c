#include "x264shim.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

// Built without x264 headers (e.g. CI): every entry point reports "unavailable"
// and the encoder keeps using VideoToolbox.
#if __has_include(<x264.h>)
#include <x264.h>

#define STR2(x) #x
#define STR(x) STR2(x)

static struct {
    int loaded;
    int (*param_default_preset)(x264_param_t *, const char *, const char *);
    int (*param_apply_profile)(x264_param_t *, const char *);
    x264_t *(*encoder_open)(x264_param_t *);
    int (*encoder_encode)(x264_t *, x264_nal_t **, int *, x264_picture_t *, x264_picture_t *);
    int (*encoder_reconfig)(x264_t *, x264_param_t *);
    void (*encoder_close)(x264_t *);
    void (*picture_init)(x264_picture_t *);
} api;

static int load_api(void) {
    if (api.loaded) return api.loaded > 0;
    const char *paths[] = {"/usr/local/lib/libx264.dylib", "/opt/homebrew/lib/libx264.dylib", "libx264.dylib"};
    void *lib = NULL;
    for (size_t i = 0; i < sizeof paths / sizeof *paths && !lib; i++) lib = dlopen(paths[i], RTLD_NOW);
    if (lib) {
        api.param_default_preset = dlsym(lib, "x264_param_default_preset");
        api.param_apply_profile = dlsym(lib, "x264_param_apply_profile");
        api.encoder_open = dlsym(lib, "x264_encoder_open_" STR(X264_BUILD));
        api.encoder_encode = dlsym(lib, "x264_encoder_encode");
        api.encoder_reconfig = dlsym(lib, "x264_encoder_reconfig");
        api.encoder_close = dlsym(lib, "x264_encoder_close");
        api.picture_init = dlsym(lib, "x264_picture_init");
    }
    int ok = lib && api.param_default_preset && api.param_apply_profile && api.encoder_open &&
             api.encoder_encode && api.encoder_reconfig && api.encoder_close && api.picture_init;
    api.loaded = ok ? 1 : -1;
    return ok;
}

struct x264shim {
    x264_t *enc;
    x264_param_t param;
    int64_t pts;
    uint8_t *buf;
    size_t cap;
};

static void apply_bitrate(x264_param_t *p, int kbps) {
    p->rc.i_rc_method = X264_RC_ABR;
    p->rc.i_bitrate = kbps;
    p->rc.i_vbv_max_bitrate = kbps;
    p->rc.i_vbv_buffer_size = kbps / 10;  // ~100 ms: caps bursts on scene changes
}

x264shim *x264shim_open(int width, int height, int fps, int bitrate_kbps) {
    if (!load_api()) return NULL;
    x264shim *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    x264_param_t *p = &s->param;
    if (api.param_default_preset(p, "ultrafast", "zerolatency") < 0) goto fail;
    p->i_width = width;
    p->i_height = height;
    p->i_csp = X264_CSP_NV12;
    p->i_fps_num = fps;
    p->i_fps_den = 1;
    p->i_keyint_max = fps;      // 1 s GOP, same as the VideoToolbox path
    p->b_repeat_headers = 1;    // SPS/PPS before every keyframe
    p->b_annexb = 1;            // start codes, what the client parses
    p->i_threads = 4;
    p->b_sliced_threads = 1;    // threads without frame delay
    p->vui.i_colorprim = 1;     // BT.709, matches the VideoToolbox VUI
    p->vui.i_transfer = 1;
    p->vui.i_colmatrix = 1;
    apply_bitrate(p, bitrate_kbps);
    if (api.param_apply_profile(p, "main") < 0) goto fail;
    s->enc = api.encoder_open(p);
    if (!s->enc) goto fail;
    return s;
fail:
    free(s);
    return NULL;
}

int x264shim_encode(x264shim *s, const uint8_t *y, int y_stride, const uint8_t *uv, int uv_stride,
                    int force_keyframe, const uint8_t **out, int *is_keyframe) {
    x264_picture_t in, pic_out;
    api.picture_init(&in);
    in.img.i_csp = X264_CSP_NV12;
    in.img.i_plane = 2;
    in.img.plane[0] = (uint8_t *)y;
    in.img.i_stride[0] = y_stride;
    in.img.plane[1] = (uint8_t *)uv;
    in.img.i_stride[1] = uv_stride;
    in.i_pts = s->pts++;
    in.i_type = force_keyframe ? X264_TYPE_IDR : X264_TYPE_AUTO;

    x264_nal_t *nals = NULL;
    int n = 0;
    int size = api.encoder_encode(s->enc, &nals, &n, &in, &pic_out);
    if (size <= 0) return size;
    // NAL payloads are contiguous in x264's buffer, but copy so the result stays
    // valid while Swift wraps it in Data.
    if ((size_t)size > s->cap) {
        uint8_t *nb = realloc(s->buf, (size_t)size);
        if (!nb) return -1;
        s->buf = nb;
        s->cap = (size_t)size;
    }
    memcpy(s->buf, nals[0].p_payload, (size_t)size);
    *out = s->buf;
    *is_keyframe = pic_out.b_keyframe;
    return size;
}

void x264shim_set_bitrate(x264shim *s, int bitrate_kbps) {
    apply_bitrate(&s->param, bitrate_kbps);
    api.encoder_reconfig(s->enc, &s->param);
}

void x264shim_close(x264shim *s) {
    if (!s) return;
    if (s->enc) api.encoder_close(s->enc);
    free(s->buf);
    free(s);
}

#else

x264shim *x264shim_open(int width, int height, int fps, int bitrate_kbps) {
    (void)width; (void)height; (void)fps; (void)bitrate_kbps;
    return NULL;
}
int x264shim_encode(x264shim *s, const uint8_t *y, int y_stride, const uint8_t *uv, int uv_stride,
                    int force_keyframe, const uint8_t **out, int *is_keyframe) {
    (void)s; (void)y; (void)y_stride; (void)uv; (void)uv_stride; (void)force_keyframe; (void)out; (void)is_keyframe;
    return -1;
}
void x264shim_set_bitrate(x264shim *s, int bitrate_kbps) { (void)s; (void)bitrate_kbps; }
void x264shim_close(x264shim *s) { (void)s; }

#endif
