package com.brite.zipimageviewer.data

import org.junit.Assert.*
import org.junit.Test

class ImagePreparationPolicyTest {
    @Test fun admissionMatchesBoundariesWithoutMultiplicationOverflow() {
        assertTrue(ImagePreparationPolicy.eligible(8000, 4000, 1, ImagePreparationPolicy.MAX_INPUT))
        assertFalse(ImagePreparationPolicy.eligible(8001, 4000, 1, 1))
        assertFalse(ImagePreparationPolicy.eligible(Int.MAX_VALUE, Int.MAX_VALUE, 1, 1))
        assertFalse(ImagePreparationPolicy.eligible(100, 100, 2, 1))
        assertFalse(ImagePreparationPolicy.eligible(100, 100, 1, 0))
        assertFalse(ImagePreparationPolicy.eligible(100, 100, 1, ImagePreparationPolicy.MAX_INPUT + 1))
    }

    @Test fun replacementRequiresBothAbsoluteAndFivePercentSavingsIncludingPreview() {
        assertFalse(ImagePreparationPolicy.profitable(100_000, 90_000, 0, 102_400, 90_112, 0))
        assertFalse(ImagePreparationPolicy.profitable(1_000_000, 960_000, 0, 1_003_520, 962_560, 0))
        assertFalse(ImagePreparationPolicy.profitable(1_000_000, 940_000, 20_000, 1_003_520, 942_080, 20_480))
        assertTrue(ImagePreparationPolicy.profitable(1_000_000, 940_000, 10_000, 1_003_520, 942_080, 12_288))
    }

    @Test fun diskAllocationMustBeKnownAndMustNotExpandEvenWithLogicalSavings() {
        assertFalse(ImagePreparationPolicy.profitable(100_000, 50_000, 1000, null, 53_248, 4096))
        assertFalse(ImagePreparationPolicy.profitable(100_000, 50_000, 1000, 49_152, 53_248, 4096))
        assertFalse(ImagePreparationPolicy.profitable(100_000, 50_000, 1000, 102_400, null, 4096))
        assertFalse(ImagePreparationPolicy.profitable(100_000, 50_000, 1000, 102_400, 53_248, null))
        assertTrue(ImagePreparationPolicy.profitable(100_000, 50_000, 1000, 102_400, 53_248, 4096))
        assertFalse(ImagePreparationPolicy.profitable(100_000, Long.MAX_VALUE, 1000, 102_400, 0, 0))
    }

    @Test fun codecPoliciesHaveDistinctCeilingsAndReserveCallerMemory() {
        val mib = ImagePreparationPolicy.MIB
        assertEquals(1536 * mib, ImagePreparationPolicy.phaseAllowance(Long.MAX_VALUE))
        assertEquals(0, ImagePreparationPolicy.phaseAllowance(63 * mib))
        val jpeg = ImagePreparationPolicy.codecBudget(24_000_000, 8 * mib, true, Long.MAX_VALUE)!!
        val png = ImagePreparationPolicy.codecBudget(24_000_000, 70 * mib, false, Long.MAX_VALUE)!!
        assertTrue(jpeg > png)
        assertTrue(jpeg <= 1280 * mib)
        assertTrue(png <= 384 * mib)
        assertNull(ImagePreparationPolicy.codecBudget(32_000_000, 128 * mib, true, 384 * mib))
        assertTrue(ImagePreparationPolicy.pngPreparationEstimate(24_000_000, 70 * mib) < 512 * mib)
    }

    @Test fun monotonicAccessSequenceWinsOverWallClockCorrections() {
        val old = ArchiveRecord("a", "old", "zip", emptyList(), 999_999, null, 10, accessSequence = 1)
        val recentlyRead = ArchiveRecord("b", "new", "zip", emptyList(), 10, null, 10, accessSequence = 2)
        assertEquals(listOf("a"), CachePolicy.evictionCandidates(listOf(old, recentlyRead), CacheLimits(10)))
    }
}
