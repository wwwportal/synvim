#include "image_engine.h"

#include <png.h>
#include <sys/stat.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

struct CachedImage {
    int width = 0;
    int height = 0;
    long mtime_sec = 0;
    long mtime_nsec = 0;
    std::vector<unsigned char> rgba; // width * height * 4
};

static std::unordered_map<std::string, CachedImage> g_cache;
static thread_local std::string g_last_payload;
static thread_local std::string g_last_delete;
static thread_local std::string g_last_error;

static const char B64_TABLE[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string base64_encode(const unsigned char* data, size_t len) {
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    for (size_t i = 0; i < len; i += 3) {
        unsigned int n = static_cast<unsigned int>(data[i]) << 16;
        if (i + 1 < len) n |= static_cast<unsigned int>(data[i + 1]) << 8;
        if (i + 2 < len) n |= static_cast<unsigned int>(data[i + 2]);

        out.push_back(B64_TABLE[(n >> 18) & 0x3F]);
        out.push_back(B64_TABLE[(n >> 12) & 0x3F]);
        out.push_back((i + 1 < len) ? B64_TABLE[(n >> 6) & 0x3F] : '=');
        out.push_back((i + 2 < len) ? B64_TABLE[n & 0x3F] : '=');
    }
    return out;
}

static bool decode_png_file(const char* filepath, CachedImage& out_img, std::string& err) {
    FILE* fp = std::fopen(filepath, "rb");
    if (!fp) {
        err = "Failed to open image file";
        return false;
    }

    unsigned char header[8];
    if (std::fread(header, 1, 8, fp) != 8 || png_sig_cmp(header, 0, 8) != 0) {
        std::fclose(fp);
        err = "File is not a valid PNG";
        return false;
    }

    png_structp png_ptr = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    if (!png_ptr) {
        std::fclose(fp);
        err = "png_create_read_struct failed";
        return false;
    }

    png_infop info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_read_struct(&png_ptr, nullptr, nullptr);
        std::fclose(fp);
        err = "png_create_info_struct failed";
        return false;
    }

    if (setjmp(png_jmpbuf(png_ptr))) {
        png_destroy_read_struct(&png_ptr, &info_ptr, nullptr);
        std::fclose(fp);
        err = "libpng read error";
        return false;
    }

    png_init_io(png_ptr, fp);
    png_set_sig_bytes(png_ptr, 8);
    png_read_info(png_ptr, info_ptr);

    int width = static_cast<int>(png_get_image_width(png_ptr, info_ptr));
    int height = static_cast<int>(png_get_image_height(png_ptr, info_ptr));
    png_byte color_type = png_get_color_type(png_ptr, info_ptr);
    png_byte bit_depth = png_get_bit_depth(png_ptr, info_ptr);

    if (bit_depth == 16) png_set_strip_16(png_ptr);
    if (color_type == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png_ptr);
    if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8) png_set_expand_gray_1_2_4_to_8(png_ptr);
    if (png_get_valid(png_ptr, info_ptr, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png_ptr);
    if (color_type == PNG_COLOR_TYPE_RGB || color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_PALETTE) {
        png_set_filler(png_ptr, 0xFF, PNG_FILLER_AFTER);
    }
    if (color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_GRAY_ALPHA) {
        png_set_gray_to_rgb(png_ptr);
    }

    png_read_update_info(png_ptr, info_ptr);

    out_img.width = width;
    out_img.height = height;
    out_img.rgba.resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);

    std::vector<png_bytep> row_pointers(height);
    for (int y = 0; y < height; ++y) {
        row_pointers[y] = out_img.rgba.data() + static_cast<size_t>(y) * static_cast<size_t>(width) * 4;
    }

    png_read_image(png_ptr, row_pointers.data());
    png_destroy_read_struct(&png_ptr, &info_ptr, nullptr);
    std::fclose(fp);
    return true;
}

static void png_mem_write_cb(png_structp png_ptr, png_bytep data, png_size_t length) {
    auto* buf = static_cast<std::vector<unsigned char>*>(png_get_io_ptr(png_ptr));
    buf->insert(buf->end(), data, data + length);
}

static void png_mem_flush_cb(png_structp) {}

static bool encode_cropped_png(
    const CachedImage& img,
    const SynvimCropRect& crop,
    std::vector<unsigned char>& out_png,
    std::string& err
) {
    png_structp png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    if (!png_ptr) {
        err = "png_create_write_struct failed";
        return false;
    }

    png_infop info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_write_struct(&png_ptr, nullptr);
        err = "png_create_info_struct failed";
        return false;
    }

    if (setjmp(png_jmpbuf(png_ptr))) {
        png_destroy_write_struct(&png_ptr, &info_ptr);
        err = "libpng write error";
        return false;
    }

    out_png.clear();
    out_png.reserve(static_cast<size_t>(crop.w) * static_cast<size_t>(crop.h));
    png_set_write_fn(png_ptr, &out_png, png_mem_write_cb, png_mem_flush_cb);
    png_set_compression_level(png_ptr, 1); // Fast in-memory zlib compression for interactive 60fps zoom/pan

    png_set_IHDR(
        png_ptr,
        info_ptr,
        crop.w,
        crop.h,
        8,
        PNG_COLOR_TYPE_RGBA,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT
    );
    png_write_info(png_ptr, info_ptr);

    std::vector<png_bytep> row_pointers(crop.h);
    for (int r = 0; r < crop.h; ++r) {
        size_t src_y = static_cast<size_t>(crop.y + r);
        size_t src_x = static_cast<size_t>(crop.x);
        const unsigned char* row_ptr =
            img.rgba.data() + (src_y * static_cast<size_t>(img.width) + src_x) * 4;
        row_pointers[r] = const_cast<png_bytep>(row_ptr);
    }

    png_write_image(png_ptr, row_pointers.data());
    png_write_end(png_ptr, nullptr);
    png_destroy_write_struct(&png_ptr, &info_ptr);
    return true;
}

static const CachedImage* get_or_load_image(const char* filepath, std::string& err) {
    if (!filepath || filepath[0] == '\0') {
        err = "Empty filepath";
        return nullptr;
    }

    struct stat st {};
    if (stat(filepath, &st) != 0) {
        err = "File does not exist";
        return nullptr;
    }

    std::string key(filepath);
    auto it = g_cache.find(key);
    if (it != g_cache.end()) {
        if (it->second.mtime_sec == st.st_mtim.tv_sec &&
            it->second.mtime_nsec == st.st_mtim.tv_nsec &&
            it->second.width > 0 && it->second.height > 0) {
            return &it->second;
        }
    }

    CachedImage decoded;
    if (!decode_png_file(filepath, decoded, err)) {
        return nullptr;
    }
    decoded.mtime_sec = st.st_mtim.tv_sec;
    decoded.mtime_nsec = st.st_mtim.tv_nsec;
    g_cache[key] = std::move(decoded);
    return &g_cache[key];
}

static void build_kitty_chunks_into(
    std::string& dst,
    const unsigned char* png_bytes,
    size_t png_len,
    int image_id,
    int term_row,
    int term_col,
    int win_cols,
    int win_rows
) {
    dst.clear();
    std::string b64 = base64_encode(png_bytes, png_len);
    dst.reserve(b64.size() + 256);

    char header_buf[256];
    std::snprintf(header_buf, sizeof(header_buf), "\033_Ga=d,d=i,i=%d,q=2\033\\", image_id);
    dst.append(header_buf);

    if (term_row > 0 && term_col > 0) {
        std::snprintf(header_buf, sizeof(header_buf), "\033[s\033[%d;%dH", term_row, term_col);
        dst.append(header_buf);
    }

    const size_t CHUNK_SIZE = 4096;
    size_t total = b64.size();
    size_t offset = 0;
    bool first = true;

    while (offset < total || first) {
        size_t take = std::min(CHUNK_SIZE, total - offset);
        int more = (offset + take < total) ? 1 : 0;

        if (first) {
            std::snprintf(
                header_buf,
                sizeof(header_buf),
                "\033_Ga=T,f=100,i=%d,c=%d,r=%d,C=1,z=1,q=2,m=%d;",
                image_id,
                std::max(1, win_cols),
                std::max(1, win_rows),
                more
            );
            first = false;
        } else {
            std::snprintf(header_buf, sizeof(header_buf), "\033_Gm=%d;", more);
        }

        dst.append(header_buf);
        if (take > 0) {
            dst.append(b64.data() + offset, take);
        }
        dst.append("\033\\");
        offset += take;
    }

    if (term_row > 0 && term_col > 0) {
        dst.append("\033[u");
    }
}

} // namespace

extern "C" {

SynvimCropRect synvim_image_compute_crop(
    int img_w,
    int img_h,
    double scale,
    double pan_x,
    double pan_y
) {
    SynvimCropRect rect{0, 0, std::max(1, img_w), std::max(1, img_h)};
    if (img_w <= 0 || img_h <= 0) {
        return rect;
    }
    double clamped_scale = std::max(1.0, std::min(32.0, scale));
    int cw = std::max(1, static_cast<int>(std::floor(static_cast<double>(img_w) / clamped_scale)));
    int ch = std::max(1, static_cast<int>(std::floor(static_cast<double>(img_h) / clamped_scale)));

    double cx_center = pan_x * static_cast<double>(img_w);
    double cy_center = pan_y * static_cast<double>(img_h);

    int cx = static_cast<int>(std::floor(cx_center - static_cast<double>(cw) * 0.5));
    int cy = static_cast<int>(std::floor(cy_center - static_cast<double>(ch) * 0.5));

    cx = std::max(0, std::min(img_w - cw, cx));
    cy = std::max(0, std::min(img_h - ch, cy));

    rect.x = cx;
    rect.y = cy;
    rect.w = cw;
    rect.h = ch;
    return rect;
}

SynvimImageMeta synvim_image_inspect(const char* filepath) {
    SynvimImageMeta meta{0, 0, 0, nullptr};
    g_last_error.clear();
    const CachedImage* img = get_or_load_image(filepath, g_last_error);
    if (!img) {
        meta.error = g_last_error.c_str();
        return meta;
    }
    meta.ok = 1;
    meta.width = img->width;
    meta.height = img->height;
    return meta;
}

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
) {
    SynvimKittyRenderResult res{};
    g_last_error.clear();

    const CachedImage* img = get_or_load_image(filepath, g_last_error);
    if (!img) {
        res.ok = 0;
        res.error = g_last_error.c_str();
        return res;
    }

    SynvimCropRect crop = synvim_image_compute_crop(img->width, img->height, scale, pan_x, pan_y);
    std::vector<unsigned char> png_bytes;
    if (!encode_cropped_png(*img, crop, png_bytes, g_last_error)) {
        res.ok = 0;
        res.error = g_last_error.c_str();
        return res;
    }

    build_kitty_chunks_into(
        g_last_payload,
        png_bytes.data(),
        png_bytes.size(),
        image_id,
        term_row,
        term_col,
        win_cols,
        win_rows
    );

    res.ok = 1;
    res.img_w = img->width;
    res.img_h = img->height;
    res.crop = crop;
    res.payload = g_last_payload.c_str();
    res.payload_len = g_last_payload.size();
    return res;
}

const char* synvim_image_build_kitty_payload(
    const unsigned char* png_bytes,
    size_t png_len,
    int image_id,
    int term_row,
    int term_col,
    int win_cols,
    int win_rows
) {
    if (!png_bytes || png_len == 0) {
        g_last_payload.clear();
        return g_last_payload.c_str();
    }
    build_kitty_chunks_into(
        g_last_payload,
        png_bytes,
        png_len,
        image_id,
        term_row,
        term_col,
        win_cols,
        win_rows
    );
    return g_last_payload.c_str();
}

const char* synvim_image_build_kitty_delete(int image_id) {
    char buf[128];
    std::snprintf(buf, sizeof(buf), "\033_Ga=d,d=i,i=%d,q=2\033\\", image_id);
    g_last_delete.assign(buf);
    return g_last_delete.c_str();
}

void synvim_image_invalidate_cache(const char* filepath) {
    if (!filepath || filepath[0] == '\0') {
        g_cache.clear();
    } else {
        g_cache.erase(std::string(filepath));
    }
}

const char* synvim_image_version(void) {
    return "1.0.0-image-ffi";
}

} // extern "C"
