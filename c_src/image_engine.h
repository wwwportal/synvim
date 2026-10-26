#ifndef SYNVIM_IMAGE_ENGINE_H
#define SYNVIM_IMAGE_ENGINE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int x;
    int y;
    int w;
    int h;
} SynvimCropRect;

typedef struct {
    int ok;
    int width;
    int height;
    const char* error;
} SynvimImageMeta;

typedef struct {
    int ok;
    int img_w;
    int img_h;
    SynvimCropRect crop;
    const char* payload;
    size_t payload_len;
    const char* error;
} SynvimKittyRenderResult;

/**
 * Compute clamped pixel crop rectangle for a given image size, zoom scale (>= 1.0),
 * and normalized pan center (pan_x, pan_y in [0.0, 1.0]).
 */
SynvimCropRect synvim_image_compute_crop(
    int img_w,
    int img_h,
    double scale,
    double pan_x,
    double pan_y
);

/**
 * Decode/cache image in memory via libpng and return pixel dimensions.
 */
SynvimImageMeta synvim_image_inspect(const char* filepath);

/**
 * Crop cached RGBA image in memory, encode cropped region to PNG via libpng,
 * and build a complete chunked Kitty graphics protocol escape sequence.
 */
SynvimKittyRenderResult synvim_image_render_kitty(
    const char* filepath,
    int image_id,
    double scale,
    double pan_x,
    double pan_y,
    int term_row,
    int term_col,
    int win_cols,
    int win_rows
);

/**
 * Build a chunked Kitty graphics protocol payload from raw PNG bytes.
 */
const char* synvim_image_build_kitty_payload(
    const unsigned char* png_bytes,
    size_t png_len,
    int image_id,
    int term_row,
    int term_col,
    int win_cols,
    int win_rows
);

/**
 * Build Kitty graphics protocol delete sequence for a given image_id.
 */
const char* synvim_image_build_kitty_delete(int image_id);

/**
 * Clear in-memory decoded image cache (or a specific file if filepath != NULL).
 */
void synvim_image_invalidate_cache(const char* filepath);

/**
 * Return native FFI image engine version string.
 */
const char* synvim_image_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SYNVIM_IMAGE_ENGINE_H */
