#include <jni.h>
#ifdef __ANDROID__
#include <android/bitmap.h>
#endif
#include "JPEGXLBridge.h"
#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <jxl/cms.h>
#include <jxl/color_encoding.h>
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <limits>
#include <memory>
#include <png.h>
#include <skcms.h>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
constexpr size_t kMaxInput = 128ull * 1024 * 1024, kMaxPixels = 32000000;
constexpr size_t kMaxBudget = 1280ull * 1024 * 1024;
struct JavaError {};
struct IoError : std::runtime_error {
    using std::runtime_error::runtime_error;
};
struct CodecError : std::runtime_error {
    using std::runtime_error::runtime_error;
};
struct Info {
    int format = 0;
    uint32_t width = 0, height = 0, orientation = 1, depth = 8, frames = 1;
    bool hasColorProfile = false;
};

std::string stringUtf8(JNIEnv *env, jstring text) {
    if (!text)
        throw IoError("Missing codec file path.");
    const auto length = env->GetStringLength(text);
    const auto *chars = env->GetStringChars(text, nullptr);
    if (!chars)
        throw JavaError{};
    struct Release {
        JNIEnv *env;
        jstring text;
        const jchar *chars;
        ~Release() { env->ReleaseStringChars(text, chars); }
    } release{env, text, chars};
    std::string out;
    for (jsize i = 0; i < length; ++i) {
        uint32_t c = chars[i];
        if (c >= 0xd800 && c <= 0xdbff) {
            if (++i >= length || chars[i] < 0xdc00 || chars[i] > 0xdfff)
                throw IoError("Invalid Unicode codec path.");
            c = 0x10000 + ((c - 0xd800) << 10) + (chars[i] - 0xdc00);
        } else if (c >= 0xdc00 && c <= 0xdfff)
            throw IoError("Invalid Unicode codec path.");
        if (!c)
            throw IoError("Invalid NUL in codec path.");
        if (c < 0x80)
            out.push_back(c);
        else if (c < 0x800) {
            out.push_back(0xc0 | (c >> 6));
            out.push_back(0x80 | (c & 63));
        } else if (c < 0x10000) {
            out.push_back(0xe0 | (c >> 12));
            out.push_back(0x80 | ((c >> 6) & 63));
            out.push_back(0x80 | (c & 63));
        } else {
            out.push_back(0xf0 | (c >> 18));
            out.push_back(0x80 | ((c >> 12) & 63));
            out.push_back(0x80 | ((c >> 6) & 63));
            out.push_back(0x80 | (c & 63));
        }
    }
    return out;
}
void throwIo(JNIEnv *env, const char *message) {
    if (env->ExceptionCheck())
        return;
    auto cls = env->FindClass("java/io/IOException");
    if (cls) {
        env->ThrowNew(cls, message);
        env->DeleteLocalRef(cls);
    }
}
std::vector<uint8_t> readFile(const std::string &path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file)
        throw IoError("Cannot open image file.");
    const auto size = file.tellg();
    if (size <= 0 || uint64_t(size) > kMaxInput)
        throw CodecError("unsupported_input");
    std::vector<uint8_t> data(static_cast<size_t>(size));
    file.seekg(0);
    if (!file.read(reinterpret_cast<char *>(data.data()), data.size()))
        throw IoError("Cannot read complete image file.");
    return data;
}
void writeFile(const std::string &path, const uint8_t *bytes, size_t count) {
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0)
        throw IoError("Cannot create codec candidate.");
    bool good = false;
    try {
        size_t written = 0;
        while (written < count) {
            const auto n = write(fd, bytes + written, count - written);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                throw IoError("Cannot write codec candidate.");
            written += n;
        }
        if (fsync(fd) != 0)
            throw IoError("Cannot sync codec candidate.");
        good = true;
    } catch (...) {
        close(fd);
        unlink(path.c_str());
        throw;
    }
    const int status = close(fd);
    if (!good || status != 0) {
        unlink(path.c_str());
        throw IoError("Cannot close codec candidate.");
    }
}
uint32_t be32(const uint8_t *p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
uint16_t be16(const uint8_t *p) { return (uint16_t(p[0]) << 8) | p[1]; }
uint32_t orientationTiff(const uint8_t *data, size_t size) {
    if (size < 8)
        return 1;
    const bool le = data[0] == 'I' && data[1] == 'I';
    if (!le && !(data[0] == 'M' && data[1] == 'M'))
        return 1;
    auto u16 = [&](const uint8_t *p) { return le ? uint16_t(p[0] | (p[1] << 8)) : be16(p); };
    auto u32 = [&](const uint8_t *p) {
        return le ? uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
                        (uint32_t(p[3]) << 24)
                  : be32(p);
    };
    if (u16(data + 2) != 42)
        return 1;
    size_t at = u32(data + 4);
    if (at > size - 2)
        return 1;
    const auto count = u16(data + at);
    at += 2;
    for (size_t i = 0; i < count && at <= size && size - at >= 12; ++i, at += 12) {
        if (u16(data + at) == 0x112 && u16(data + at + 2) == 3 && u32(data + at + 4) == 1) {
            const auto o = u16(data + at + 8);
            return o >= 1 && o <= 8 ? o : 1;
        }
    }
    return 1;
}
struct Budget {
    size_t limit, used = 0, peak = 0;
};
struct alignas(std::max_align_t) Allocation {
    size_t size;
};
void *allocate(void *opaque, size_t size) {
    auto &b = *static_cast<Budget *>(opaque);
    if (size > b.limit - b.used || size > SIZE_MAX - sizeof(Allocation))
        return nullptr;
    auto *p = static_cast<Allocation *>(malloc(sizeof(Allocation) + size));
    if (!p)
        return nullptr;
    p->size = size;
    b.used += size;
    b.peak = std::max(b.used, b.peak);
    return p + 1;
}
void freeAllocation(void *opaque, void *ptr) {
    if (!ptr)
        return;
    auto *p = static_cast<Allocation *>(ptr) - 1;
    static_cast<Budget *>(opaque)->used -= p->size;
    free(p);
}
using Decoder = std::unique_ptr<JxlDecoder, decltype(&JxlDecoderDestroy)>;
Info inspectData(const std::vector<uint8_t> &data) {
    Info info;
    if (data.size() >= 8 && png_sig_cmp(data.data(), 0, 8) == 0) {
        info.format = 2;
        size_t at = 8;
        while (at <= data.size() && data.size() - at >= 12) {
            const size_t n = be32(data.data() + at);
            if (n > data.size() - at - 12)
                throw CodecError("truncated_png");
            const uint8_t *type = data.data() + at + 4;
            const uint8_t *payload = data.data() + at + 8;
            if (!memcmp(type, "IHDR", 4) && n == 13) {
                info.width = be32(payload);
                info.height = be32(payload + 4);
                info.depth = payload[8];
            }
            if (!memcmp(type, "acTL", 4) && n >= 8)
                info.frames = std::max(2u, be32(payload));
            if (!memcmp(type, "iCCP", 4))
                info.hasColorProfile = true;
            if (!memcmp(type, "eXIf", 4))
                info.orientation = orientationTiff(payload, n);
            if (!memcmp(type, "IEND", 4))
                break;
            at += n + 12;
        }
    } else if (data.size() > 4 && data[0] == 0xff && data[1] == 0xd8) {
        info.format = 1;
        size_t at = 2;
        while (at < data.size()) {
            if (data[at++] != 0xff)
                break;
            while (at < data.size() && data[at] == 0xff)
                ++at;
            if (at >= data.size())
                break;
            const auto marker = data[at++];
            if (marker == 0xd9 || marker == 0xda)
                break;
            if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7))
                continue;
            if (data.size() - at < 2)
                throw CodecError("truncated_jpeg");
            const size_t length = be16(data.data() + at);
            if (length < 2 || length > data.size() - at)
                throw CodecError("truncated_jpeg");
            const auto *p = data.data() + at + 2;
            const size_t n = length - 2;
            if (marker == 0xe1 && n >= 6 && !memcmp(p, "Exif\0\0", 6))
                info.orientation = orientationTiff(p + 6, n - 6);
            if (marker == 0xe2 && n >= 4 && !memcmp(p, "MPF\0", 4))
                info.frames = 2;
            if ((marker >= 0xc0 && marker <= 0xcf) && marker != 0xc4 && marker != 0xc8 &&
                marker != 0xcc && n >= 6) {
                info.depth = p[0];
                info.height = be16(p + 1);
                info.width = be16(p + 3);
            }
            at += length;
        }
    } else if (JxlSignatureCheck(data.data(), data.size()) >= JXL_SIG_CODESTREAM) {
        Budget budget{64ull * 1024 * 1024};
        JxlMemoryManager mm{&budget, allocate, freeAllocation};
        Decoder decoder(JxlDecoderCreate(&mm), JxlDecoderDestroy);
        if (!decoder)
            throw std::bad_alloc();
        JxlDecoderSetKeepOrientation(decoder.get(), JXL_TRUE);
        if (JxlDecoderSubscribeEvents(decoder.get(), JXL_DEC_BASIC_INFO) != JXL_DEC_SUCCESS ||
            JxlDecoderSetInput(decoder.get(), data.data(), data.size()) != JXL_DEC_SUCCESS)
            throw CodecError("invalid_jxl");
        JxlDecoderCloseInput(decoder.get());
        if (JxlDecoderProcessInput(decoder.get()) != JXL_DEC_BASIC_INFO)
            throw CodecError("invalid_jxl");
        JxlBasicInfo basic{};
        if (JxlDecoderGetBasicInfo(decoder.get(), &basic) != JXL_DEC_SUCCESS)
            throw CodecError("invalid_jxl");
        info = {3,
                basic.xsize,
                basic.ysize,
                uint32_t(basic.orientation),
                basic.bits_per_sample,
                basic.have_animation ? 2u : 1u};
    }
    if (!info.format || !info.width || !info.height)
        throw CodecError("unsupported_input");
    return info;
}
struct PngPixels {
    std::vector<uint8_t> rgb, icc;
};
void pngError(png_structp png, const char *) { png_longjmp(png, 1); }
void pngWarning(png_structp, const char *) {}
PngPixels pngPixels(const std::string &path, const Info &expected) {
    std::unique_ptr<FILE, decltype(&fclose)> file(fopen(path.c_str(), "rb"), fclose);
    if (!file)
        throw IoError("Cannot read PNG pixels.");
    // libpng reports errors with longjmp. Keep mutable C++ storage on the heap,
    // owned by an unchanged local, so its state survives that error boundary.
    struct Storage {
        PngPixels result;
        std::vector<uint8_t> rgba;
        std::vector<png_bytep> rows;
    };
    const auto storage = std::make_unique<Storage>();
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, pngError, pngWarning);
    if (!png)
        throw std::bad_alloc();
    png_infop metadata = png_create_info_struct(png);
    if (!metadata) {
        png_destroy_read_struct(&png, nullptr, nullptr);
        throw std::bad_alloc();
    }
    struct PngOwner {
        png_structp *p;
        png_infop *i;
        ~PngOwner() {
            if (*p)
                png_destroy_read_struct(p, i, nullptr);
        }
    } owner{&png, &metadata};
    if (setjmp(png_jmpbuf(png))) {
        png_destroy_read_struct(&png, &metadata, nullptr);
        throw CodecError("invalid_png");
    }
    auto &result = storage->result;
    auto &rgba = storage->rgba;
    auto &rows = storage->rows;
    png_init_io(png, file.get());
    png_set_user_limits(png, 100000, 100000);
    png_set_chunk_malloc_max(png, 16ull * 1024 * 1024);
    png_read_info(png, metadata);
    const auto width = png_get_image_width(png, metadata),
               height = png_get_image_height(png, metadata);
    const auto depth = png_get_bit_depth(png, metadata), type = png_get_color_type(png, metadata);
    if (width != expected.width || height != expected.height || depth > 8 ||
        uint64_t(width) * height > kMaxPixels) {
        png_destroy_read_struct(&png, &metadata, nullptr);
        throw CodecError("unsupported_png");
    }
    png_charp name = nullptr;
    int compression = 0;
    png_bytep profile = nullptr;
    png_uint_32 profileSize = 0;
    if (png_get_iCCP(png, metadata, &name, &compression, &profile, &profileSize) &&
        profileSize <= 16 * 1024 * 1024)
        result.icc.assign(profile, profile + profileSize);
    // libpng can warn and discard a malformed ancillary profile. Retain the
    // original instead of silently interpreting its colors as untagged sRGB.
    if (expected.hasColorProfile && result.icc.empty())
        throw CodecError("unsupported_png_profile");
    bool convertToSrgb = (type == PNG_COLOR_TYPE_GRAY || type == PNG_COLOR_TYPE_GRAY_ALPHA);
    skcms_ICCProfile sourceProfile = *skcms_sRGB_profile();
    if (!result.icc.empty() && !skcms_Parse(result.icc.data(), result.icc.size(), &sourceProfile)) {
        png_destroy_read_struct(&png, &metadata, nullptr);
        throw CodecError("unsupported_png_profile");
    }
    if (result.icc.empty()) {
        double gamma = 0;
        int intent = 0;
        if (!png_get_sRGB(png, metadata, &intent) && png_get_gAMA(png, metadata, &gamma) &&
            gamma > 0) {
            skcms_TransferFunction tf{float(1.0 / gamma), 1, 0, 0, 0, 0, 0};
            skcms_SetTransferFunction(&sourceProfile, &tf);
            convertToSrgb = true;
        }
        double wx, wy, rx, ry, gx, gy, bx, by;
        if (!png_get_sRGB(png, metadata, &intent) &&
            png_get_cHRM(png, metadata, &wx, &wy, &rx, &ry, &gx, &gy, &bx, &by)) {
            skcms_Matrix3x3 matrix;
            if (!skcms_PrimariesToXYZD50(rx, ry, gx, gy, bx, by, wx, wy, &matrix)) {
                png_destroy_read_struct(&png, &metadata, nullptr);
                throw CodecError("unsupported_png_chromaticities");
            }
            skcms_SetXYZD50(&sourceProfile, &matrix);
            convertToSrgb = true;
        }
    }
    if (type == PNG_COLOR_TYPE_PALETTE)
        png_set_palette_to_rgb(png);
    if (type == PNG_COLOR_TYPE_GRAY && depth < 8)
        png_set_expand_gray_1_2_4_to_8(png);
    const bool transparency = png_get_valid(png, metadata, PNG_INFO_tRNS);
    if (transparency)
        png_set_tRNS_to_alpha(png);
    if (type == PNG_COLOR_TYPE_GRAY || type == PNG_COLOR_TYPE_GRAY_ALPHA)
        png_set_gray_to_rgb(png);
    if (!(type & PNG_COLOR_MASK_ALPHA) && !transparency)
        png_set_filler(png, 255, PNG_FILLER_AFTER);
    png_set_interlace_handling(png);
    png_read_update_info(png, metadata);
    if (png_get_rowbytes(png, metadata) != size_t(width) * 4) {
        png_destroy_read_struct(&png, &metadata, nullptr);
        throw CodecError("unsupported_png_layout");
    }
    rgba.resize(size_t(width) * height * 4);
    rows.resize(height);
    for (size_t y = 0; y < height; ++y)
        rows[y] = rgba.data() + y * width * 4;
    png_read_image(png, rows.data());
    png_read_end(png, nullptr);
    png_destroy_read_struct(&png, &metadata, nullptr);
    if (convertToSrgb) {
        if (!skcms_Transform(rgba.data(), skcms_PixelFormat_RGBA_8888, skcms_AlphaFormat_Unpremul,
                             &sourceProfile, rgba.data(), skcms_PixelFormat_RGBA_8888,
                             skcms_AlphaFormat_Unpremul, skcms_sRGB_profile(),
                             size_t(width) * height))
            throw CodecError("png_color_conversion_failed");
        result.icc.clear();
    }
    result.rgb.resize(size_t(width) * height * 3);
    for (size_t i = 0; i < size_t(width) * height; ++i) {
        const uint32_t alpha = rgba[i * 4 + 3];
        for (size_t c = 0; c < 3; ++c)
            result.rgb[i * 3 + c] =
                uint8_t((uint32_t(rgba[i * 4 + c]) * alpha + 255 * (255 - alpha) + 127) / 255);
    }
    return std::move(result);
}

struct OutputPixels {
    uint8_t *pixels = nullptr;
    size_t stride = 0, width = 0, height = 0, sourceWidth = 0, sourceHeight = 0;
    struct Sum {
        float r, g, b;
        uint32_t count;
    };
    Sum *sums = nullptr;
    bool invalid = false;
    static void callback(void *opaque, size_t x, size_t y, size_t count, const void *input) {
        auto &out = *static_cast<OutputPixels *>(opaque);
        if (x > out.sourceWidth || count > out.sourceWidth - x || y >= out.sourceHeight) {
            out.invalid = true;
            return;
        }
        if (!out.pixels)
            return;
        const auto *rgba = static_cast<const uint8_t *>(input);
        if (!out.sums) {
            memcpy(out.pixels + y * out.stride + x * 4, rgba, count * 4);
            return;
        }
        const size_t targetY = y * out.height / out.sourceHeight;
        for (size_t i = 0; i < count; ++i) {
            auto &sum = out.sums[targetY * out.width + (x + i) * out.width / out.sourceWidth];
            sum.r += rgba[i * 4];
            sum.g += rgba[i * 4 + 1];
            sum.b += rgba[i * 4 + 2];
            ++sum.count;
        }
    }
    void finish() {
        if (!sums)
            return;
        for (size_t y = 0; y < height; ++y)
            for (size_t x = 0; x < width; ++x) {
                const auto &sum = sums[y * width + x];
                if (!sum.count) {
                    invalid = true;
                    return;
                }
                auto *p = pixels + y * stride + x * 4;
                p[0] = uint8_t(std::clamp(std::lround(sum.r / sum.count), 0l, 255l));
                p[1] = uint8_t(std::clamp(std::lround(sum.g / sum.count), 0l, 255l));
                p[2] = uint8_t(std::clamp(std::lround(sum.b / sum.count), 0l, 255l));
                p[3] = 255;
            }
    }
};
bool decodeData(const std::vector<uint8_t> &data, const Info &expected, bool keepOrientation,
                size_t limit, OutputPixels &output) {
    if (!limit || limit > kMaxBudget)
        return false;
    Budget budget{limit};
    JxlMemoryManager mm{&budget, allocate, freeAllocation};
    struct FreeSums {
        Budget &budget;
        OutputPixels &out;
        ~FreeSums() {
            freeAllocation(&budget, out.sums);
            out.sums = nullptr;
        }
    } freeSums{budget, output};
    Decoder decoder(JxlDecoderCreate(&mm), JxlDecoderDestroy);
    if (!decoder)
        return false;
    JxlDecoderSetKeepOrientation(decoder.get(), keepOrientation ? JXL_TRUE : JXL_FALSE);
    if (JxlDecoderSetCms(decoder.get(), *JxlGetDefaultCms()) != JXL_DEC_SUCCESS ||
        JxlDecoderSubscribeEvents(decoder.get(), JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING |
                                                     JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS ||
        JxlDecoderSetInput(decoder.get(), data.data(), data.size()) != JXL_DEC_SUCCESS)
        return false;
    JxlDecoderCloseInput(decoder.get());
    bool complete = false;
    size_t frames = 0;
    for (;;) {
        const auto status = JxlDecoderProcessInput(decoder.get());
        if (status == JXL_DEC_BASIC_INFO) {
            JxlBasicInfo basic{};
            if (JxlDecoderGetBasicInfo(decoder.get(), &basic) != JXL_DEC_SUCCESS ||
                basic.have_animation || uint64_t(basic.xsize) * basic.ysize > kMaxPixels ||
                !basic.xsize || !basic.ysize)
                return false;
            if (keepOrientation &&
                (basic.xsize != expected.width || basic.ysize != expected.height ||
                 uint32_t(basic.orientation) != expected.orientation))
                return false;
            output.sourceWidth = basic.xsize;
            output.sourceHeight = basic.ysize;
            if (output.pixels) {
                if (output.width > basic.xsize || output.height > basic.ysize)
                    return false;
                if (output.width != basic.xsize || output.height != basic.ysize) {
                    const size_t count = output.width * output.height;
                    output.sums = static_cast<OutputPixels::Sum *>(
                        allocate(&budget, count * sizeof(OutputPixels::Sum)));
                    if (!output.sums)
                        return false;
                    memset(output.sums, 0, count * sizeof(OutputPixels::Sum));
                }
            }
        } else if (status == JXL_DEC_COLOR_ENCODING) {
            JxlColorEncoding color;
            JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
            color.primaries = JXL_PRIMARIES_P3;
            if (JxlDecoderSetOutputColorProfile(decoder.get(), &color, nullptr, 0) !=
                JXL_DEC_SUCCESS)
                return false;
        } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            const JxlPixelFormat format{4, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
            if (JxlDecoderSetImageOutCallback(decoder.get(), &format, OutputPixels::callback,
                                              &output) != JXL_DEC_SUCCESS)
                return false;
        } else if (status == JXL_DEC_FULL_IMAGE) {
            complete = true;
            ++frames;
        } else if (status == JXL_DEC_SUCCESS) {
            output.finish();
            return complete && frames == 1 && !output.invalid;
        } else
            return false;
    }
}
jlongArray longs(JNIEnv *env, std::initializer_list<jlong> values) {
    auto result = env->NewLongArray(values.size());
    if (result)
        env->SetLongArrayRegion(result, 0, values.size(), values.begin());
    return result;
}
} // namespace

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_brite_zipimageviewer_nativebridge_NativeJpegXl_inspectNative(JNIEnv *env, jobject,
                                                                      jstring path) {
    try {
        auto data = readFile(stringUtf8(env, path));
        const auto info = inspectData(data);
        return longs(
            env, {info.format, info.width, info.height, info.orientation, info.depth, info.frames});
    } catch (const JavaError &) {
    } catch (const CodecError &) {
    } catch (const std::bad_alloc &) {
    } catch (const std::exception &e) {
        throwIo(env, e.what());
    } catch (...) {
        throwIo(env, "Image inspection failed.");
    }
    return nullptr;
}
extern "C" JNIEXPORT jlongArray JNICALL
Java_com_brite_zipimageviewer_nativebridge_NativeJpegXl_encodeNative(JNIEnv *env, jobject,
                                                                     jstring source,
                                                                     jstring destination,
                                                                     jlong memoryLimit) {
    size_t peak = 0;
    try {
        const auto path = stringUtf8(env, source), target = stringUtf8(env, destination);
        Info info;
        size_t inputSize = 0;
        {
            auto input = readFile(path);
            inputSize = input.size();
            info = inspectData(input);
        }
        if (memoryLimit <= 0 || uint64_t(memoryLimit) > kMaxBudget || info.frames != 1 ||
            info.depth > 8 || uint64_t(info.width) * info.height > kMaxPixels ||
            inputSize < 16384 || (info.format != 1 && info.format != 2))
            return longs(env, {0, 0, 1});
        std::vector<uint8_t> output(inputSize);
        size_t written = 0;
        if (info.format == 1) {
            auto input = readFile(path);
            written = ziv_jxl_repack_jpeg(input.data(), input.size(), output.data(), output.size(),
                                          memoryLimit, &peak);
        } else {
            auto pixels = pngPixels(path, info);
            written = ziv_jxl_encode_rgb(pixels.rgb.data(), info.width, info.height,
                                         info.orientation, pixels.icc.data(), pixels.icc.size(),
                                         output.data(), output.size(), memoryLimit, &peak);
        }
        if (!written)
            return longs(env, {0, jlong(peak), 2});
        writeFile(target, output.data(), written);
        return longs(env, {jlong(written), jlong(peak), 0});
    } catch (const JavaError &) {
    } catch (const CodecError &) {
        return longs(env, {0, jlong(peak), 1});
    } catch (const std::bad_alloc &) {
        return longs(env, {0, jlong(peak), 3});
    } catch (const std::exception &e) {
        throwIo(env, e.what());
    } catch (...) {
        throwIo(env, "Image encoding failed.");
    }
    return nullptr;
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_brite_zipimageviewer_nativebridge_NativeJpegXl_validateNative(JNIEnv *env, jobject,
                                                                       jstring path, jint width,
                                                                       jint height,
                                                                       jint orientation,
                                                                       jlong memoryLimit) {
    try {
        auto data = readFile(stringUtf8(env, path));
        OutputPixels output;
        Info expected{3, uint32_t(width), uint32_t(height), uint32_t(orientation), 8, 1};
        return decodeData(data, expected, true, memoryLimit, output);
    } catch (const JavaError &) {
    } catch (const CodecError &) {
    } catch (const std::bad_alloc &) {
    } catch (const std::exception &e) {
        throwIo(env, e.what());
    } catch (...) {
        throwIo(env, "Image validation failed.");
    }
    return false;
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_brite_zipimageviewer_nativebridge_NativeJpegXl_decodeNative(JNIEnv *env, jobject,
                                                                     jstring path, jobject bitmap,
                                                                     jlong memoryLimit) {
#ifdef __ANDROID__
    void *pixels = nullptr;
    bool locked = false;
    try {
        auto data = readFile(stringUtf8(env, path));
        const auto info = inspectData(data);
        AndroidBitmapInfo b{};
        if (info.format != 3 ||
            AndroidBitmap_getInfo(env, bitmap, &b) != ANDROID_BITMAP_RESULT_SUCCESS ||
            b.format != ANDROID_BITMAP_FORMAT_RGBA_8888)
            return false;
        if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS)
            return false;
        locked = true;
        OutputPixels output;
        output.pixels = static_cast<uint8_t *>(pixels);
        output.width = b.width;
        output.height = b.height;
        output.stride = b.stride;
        const bool result = decodeData(data, info, false, memoryLimit, output);
        AndroidBitmap_unlockPixels(env, bitmap);
        return result;
    } catch (const JavaError &) {
    } catch (const CodecError &) {
    } catch (const std::bad_alloc &) {
    } catch (const std::exception &e) {
        throwIo(env, e.what());
    } catch (...) {
        throwIo(env, "Image decoding failed.");
    }
    if (locked)
        AndroidBitmap_unlockPixels(env, bitmap);
#endif
    return false;
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_brite_zipimageviewer_nativebridge_NativeJpegXl_reconstructNative(JNIEnv *env, jobject,
                                                                          jstring path,
                                                                          jstring destination,
                                                                          jlong capacity) {
    try {
        if (capacity <= 0 || uint64_t(capacity) > kMaxInput)
            return false;
        auto input = readFile(stringUtf8(env, path));
        std::vector<uint8_t> output(capacity);
        const auto count =
            ziv_jxl_reconstruct_jpeg(input.data(), input.size(), output.data(), output.size());
        if (!count)
            return false;
        writeFile(stringUtf8(env, destination), output.data(), count);
        return true;
    } catch (const JavaError &) {
    } catch (const CodecError &) {
    } catch (const std::bad_alloc &) {
    } catch (const std::exception &e) {
        throwIo(env, e.what());
    } catch (...) {
        throwIo(env, "JPEG reconstruction failed.");
    }
    return false;
}
