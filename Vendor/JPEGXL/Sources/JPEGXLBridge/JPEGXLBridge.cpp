#include "JPEGXLBridge.h"
#include <jxl/encode.h>
#include <jxl/decode.h>
#include <cstdlib>
#include <cstddef>
#include <memory>

namespace {
constexpr size_t kMaximumBudget = 1280 * 1024 * 1024;
struct Budget { size_t limit; size_t used = 0; size_t peak = 0; };
struct ReportPeak {
    Budget &budget; size_t *output;
    ~ReportPeak() { if (output) *output = budget.peak; }
};
struct alignas(std::max_align_t) Allocation { size_t size; };
void *Allocate(void *opaque, size_t size) {
    auto *budget = static_cast<Budget *>(opaque);
    if (size > budget->limit - budget->used || size > SIZE_MAX - sizeof(Allocation)) return nullptr;
    auto *allocation = static_cast<Allocation *>(std::malloc(sizeof(Allocation) + size));
    if (!allocation) return nullptr;
    allocation->size = size; budget->used += size;
    if (budget->used > budget->peak) budget->peak = budget->used;
    return allocation + 1;
}
void Free(void *opaque, void *pointer) {
    if (!pointer) return;
    auto *allocation = static_cast<Allocation *>(pointer) - 1;
    static_cast<Budget *>(opaque)->used -= allocation->size;
    std::free(allocation);
}
// Write directly into the caller's bounded output; overflow is an encoder
// failure, never a realloc or an unbounded temporary output vector.
struct Output {
    uint8_t *bytes; size_t capacity; size_t position = 0; size_t finalized = 0;
    bool failed = false;
    JxlEncoderOutputProcessor Processor() {
        JxlEncoderOutputProcessor result{};
        result.opaque = this;
        result.get_buffer = [](void *opaque, size_t *size) -> void * {
            auto &out = *static_cast<Output *>(opaque);
            if (out.failed || out.position >= out.capacity) { *size = 0; return nullptr; }
            *size = out.capacity - out.position;
            return out.bytes + out.position;
        };
        result.release_buffer = [](void *opaque, size_t written) {
            auto &out = *static_cast<Output *>(opaque);
            if (written > out.capacity - out.position) { out.failed = true; return; }
            out.position += written;
        };
        result.set_finalized_position = [](void *opaque, uint64_t position) {
            auto &out = *static_cast<Output *>(opaque);
            if (position > out.position || position < out.finalized) { out.failed = true; return; }
            out.finalized = static_cast<size_t>(position);
        };
        return result;
    }
};
struct RGBInput {
    const uint8_t *bytes; size_t width; size_t height;
    JxlChunkedFrameInputSource Source() {
        JxlChunkedFrameInputSource result{};
        result.opaque = this;
        result.get_color_channels_pixel_format = [](void *, JxlPixelFormat *format) {
            *format = JxlPixelFormat{3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
        };
        result.get_color_channel_data_at = [](void *opaque, size_t x, size_t y,
                                              size_t width, size_t height, size_t *stride) -> const void * {
            const auto &input = *static_cast<RGBInput *>(opaque);
            if (x >= input.width || y >= input.height || width > input.width - x || height > input.height - y) return nullptr;
            *stride = input.width * 3;
            return input.bytes + (y * input.width + x) * 3;
        };
        result.release_buffer = [](void *, const void *) {};
        return result;
    }
};
size_t Finish(JxlEncoder *encoder, uint8_t *output, size_t capacity) {
    JxlEncoderCloseInput(encoder);
    uint8_t *next = output;
    size_t remaining = capacity;
    if (JxlEncoderProcessOutput(encoder, &next, &remaining) != JXL_ENC_SUCCESS) return 0;
    return capacity - remaining;
}
}

size_t ziv_jxl_repack_jpeg(const uint8_t *jpeg, size_t size, uint8_t *output, size_t capacity,
                           size_t memory_limit, size_t *peak_memory) {
    if (peak_memory) *peak_memory = 0;
    if (!jpeg || !size || !output || !capacity || !memory_limit || memory_limit > kMaximumBudget) return 0;
    Budget budget{memory_limit}; ReportPeak report{budget, peak_memory}; JxlMemoryManager memory{&budget, Allocate, Free};
    std::unique_ptr<JxlEncoder, decltype(&JxlEncoderDestroy)> encoder(JxlEncoderCreate(&memory), JxlEncoderDestroy);
    if (!encoder) return 0;
    auto *settings = JxlEncoderFrameSettingsCreate(encoder.get(), nullptr);
    if (!settings || JxlEncoderUseContainer(encoder.get(), JXL_TRUE) != JXL_ENC_SUCCESS ||
        JxlEncoderStoreJPEGMetadata(encoder.get(), JXL_TRUE) != JXL_ENC_SUCCESS ||
        JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 3) != JXL_ENC_SUCCESS ||
        JxlEncoderAddJPEGFrame(settings, jpeg, size) != JXL_ENC_SUCCESS) return 0;
    return Finish(encoder.get(), output, capacity);
}

size_t ziv_jxl_encode_rgb(const uint8_t *rgb, uint32_t width, uint32_t height,
                          uint32_t orientation, const uint8_t *icc, size_t icc_size,
                          uint8_t *output, size_t capacity, size_t memory_limit, size_t *peak_memory) {
    if (peak_memory) *peak_memory = 0;
    if (!rgb || !width || !height || width > 32000000 / height || !output || !capacity || orientation < 1 || orientation > 8 || !memory_limit || memory_limit > kMaximumBudget) return 0;
    Budget budget{memory_limit}; ReportPeak report{budget, peak_memory}; JxlMemoryManager memory{&budget, Allocate, Free};
    // Callback state must also outlive encoder cleanup on an error path.
    Output sink{output, capacity};
    RGBInput input{rgb, width, height};
    std::unique_ptr<JxlEncoder, decltype(&JxlEncoderDestroy)> encoder(JxlEncoderCreate(&memory), JxlEncoderDestroy);
    if (!encoder) return 0;
    JxlBasicInfo info; JxlEncoderInitBasicInfo(&info);
    info.xsize = width; info.ysize = height; info.bits_per_sample = 8;
    info.num_color_channels = 3; info.orientation = static_cast<JxlOrientation>(orientation);
    if (JxlEncoderSetBasicInfo(encoder.get(), &info) != JXL_ENC_SUCCESS) return 0;
    JxlColorEncoding color; JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
    if ((icc && icc_size ? JxlEncoderSetICCProfile(encoder.get(), icc, icc_size)
                        : JxlEncoderSetColorEncoding(encoder.get(), &color)) != JXL_ENC_SUCCESS) return 0;
    auto *settings = JxlEncoderFrameSettingsCreate(encoder.get(), nullptr);
    if (!settings || JxlEncoderSetFrameDistance(settings, 0.5f) != JXL_ENC_SUCCESS ||
        JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 3) != JXL_ENC_SUCCESS ||
        JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_BUFFERING, 2) != JXL_ENC_SUCCESS ||
        JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_OUTPUT_MODE, 0) != JXL_ENC_SUCCESS ||
        JxlEncoderSetOutputProcessor(encoder.get(), sink.Processor()) != JXL_ENC_SUCCESS ||
        JxlEncoderAddChunkedFrame(settings, JXL_TRUE, input.Source()) != JXL_ENC_SUCCESS) return 0;
    JxlEncoderCloseInput(encoder.get());
    if (JxlEncoderFlushInput(encoder.get()) != JXL_ENC_SUCCESS || sink.failed) return 0;
    return sink.finalized;
}

size_t ziv_jxl_reconstruct_jpeg(const uint8_t *jxl, size_t size, uint8_t *output, size_t capacity) {
    if (!jxl || !size || !output || !capacity) return 0;
    Budget budget{kMaximumBudget}; JxlMemoryManager memory{&budget, Allocate, Free};
    std::unique_ptr<JxlDecoder, decltype(&JxlDecoderDestroy)> decoder(JxlDecoderCreate(&memory), JxlDecoderDestroy);
    if (!decoder || JxlDecoderSubscribeEvents(decoder.get(), JXL_DEC_JPEG_RECONSTRUCTION | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS ||
        JxlDecoderSetInput(decoder.get(), jxl, size) != JXL_DEC_SUCCESS) return 0;
    JxlDecoderCloseInput(decoder.get());
    bool reconstructing = false;
    for (;;) {
        auto status = JxlDecoderProcessInput(decoder.get());
        if (status == JXL_DEC_JPEG_RECONSTRUCTION) {
            if (JxlDecoderSetJPEGBuffer(decoder.get(), output, capacity) != JXL_DEC_SUCCESS) return 0;
            reconstructing = true;
        } else if (status == JXL_DEC_SUCCESS) {
            return reconstructing ? capacity - JxlDecoderReleaseJPEGBuffer(decoder.get()) : 0;
        } else if (status != JXL_DEC_FULL_IMAGE) return 0;
    }
}
