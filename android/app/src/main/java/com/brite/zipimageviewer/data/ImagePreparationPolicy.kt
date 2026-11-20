package com.brite.zipimageviewer.data

/** Pure storage and phase-admission rules shared by the importer and its regression tests. */
object ImagePreparationPolicy {
    const val MIB = 1024L * 1024
    const val MAX_PIXELS = 32_000_000L
    const val MAX_INPUT = 128 * MIB
    const val JPEG_POLICY = "libjxl-0.13.0-jpeg-repack-v1"
    const val PNG_POLICY = "libjxl-0.13.0-png-d0.5-e3-stream-v2"

    fun eligible(width: Int, height: Int, frames: Int, bytes: Long): Boolean =
        width > 0 && height > 0 && width.toLong() * height <= MAX_PIXELS && frames == 1 && bytes in 1..MAX_INPUT

    fun phaseAllowance(availableBytes: Long): Long = minOf(1536 * MIB, (availableBytes - 64 * MIB).coerceAtLeast(0))
    fun previewEstimate(pixels: Long, input: Long): Long = pixels * 8 + input + 4 * MIB
    fun validationEstimate(pixels: Long, input: Long): Long = pixels * 8 + input + 16 * MIB
    fun pngPreparationEstimate(pixels: Long, input: Long): Long = pixels * 12 + input + 16 * MIB
    fun codecBudget(pixels: Long, input: Long, jpeg: Boolean, availableBytes: Long): Long? {
        val caller = (if (jpeg) pixels * 8 + input * 2 else pixels * 3 + input) + 16 * MIB
        val working = minOf(phaseAllowance(availableBytes), if (jpeg) 1536 * MIB else 512 * MIB)
        return minOf(if (jpeg) 1280 * MIB else 384 * MIB, working - caller).takeIf { it >= 128 * MIB }
    }

    fun profitable(original: Long, candidate: Long, preview: Long, originalAllocated: Long?, candidateAllocated: Long?, previewAllocated: Long?): Boolean {
        if (original <= 0 || candidate <= 0 || preview < 0 || candidate > original || preview > original - candidate) return false
        val required = maxOf(16 * 1024L, (original + 19) / 20)
        if (original - candidate - preview < required) return false
        if (originalAllocated == null || candidateAllocated == null || previewAllocated == null) return false
        if (originalAllocated < 0 || candidateAllocated < 0 || previewAllocated < 0) return false
        return candidateAllocated <= originalAllocated && previewAllocated <= originalAllocated - candidateAllocated
    }
}
