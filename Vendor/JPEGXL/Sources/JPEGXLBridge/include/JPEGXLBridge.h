#ifndef ZIP_IMAGE_JPEGXL_BRIDGE_H
#define ZIP_IMAGE_JPEGXL_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Single-threaded, bounded operations. A zero result means unsupported input,
// insufficient budget, or encoder failure. The caller always owns the buffers.
// memory_limit caps codec-managed allocations (maximum 1280 MiB). Optional peak_memory
// reports their observed high-water mark, excluding caller buffers and OS decoder memory.
size_t ziv_jxl_repack_jpeg(const uint8_t *jpeg, size_t size, uint8_t *output, size_t capacity,
                           size_t memory_limit, size_t *peak_memory);
size_t ziv_jxl_encode_rgb(const uint8_t *rgb, uint32_t width, uint32_t height,
                          uint32_t orientation, const uint8_t *icc, size_t icc_size,
                          uint8_t *output, size_t capacity, size_t memory_limit, size_t *peak_memory);
// Exposed for byte-exact JPEG reconstruction regression tests.
size_t ziv_jxl_reconstruct_jpeg(const uint8_t *jxl, size_t size, uint8_t *output, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
