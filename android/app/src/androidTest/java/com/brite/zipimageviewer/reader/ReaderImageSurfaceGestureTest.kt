package com.brite.zipimageviewer.reader

import android.graphics.Bitmap
import android.os.SystemClock
import android.view.MotionEvent
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

/** Real native event arbitration, including the latency before each page-turn callback. */
class ReaderImageSurfaceGestureTest {
    private fun surface(block: (ReaderImageSurface, MutableList<Int>) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val image = Bitmap.createBitmap(1000, 1000, Bitmap.Config.RGB_565)
            val view = ReaderImageSurface(instrumentation.targetContext)
            val steps = mutableListOf<Int>()
            view.layout(0, 0, 1000, 1000)
            view.show("fixture", image)
            view.onStep = { steps += it }
            try { block(view, steps) } finally { view.release(); image.recycle() }
        }
    }

    private fun tap(view: ReaderImageSurface, time: Long, x: Float = 900f, y: Float = 300f) {
        for ((action, eventTime) in listOf(MotionEvent.ACTION_DOWN to time, MotionEvent.ACTION_UP to time + 20)) {
            val event = MotionEvent.obtain(time, eventTime, action, x, y, 0)
            try { view.onTouchEvent(event) } finally { event.recycle() }
        }
    }

    @Test fun rotationsDrawBothDirectionsRefitAndPreserveNativeGestures() = surface { view, steps ->
        val image = Bitmap.createBitmap(200, 100, Bitmap.Config.ARGB_8888)
        val source = android.graphics.Canvas(image)
        val paint = android.graphics.Paint()
        paint.color = android.graphics.Color.RED; source.drawRect(0f, 0f, 100f, 100f, paint)
        paint.color = android.graphics.Color.BLUE; source.drawRect(100f, 0f, 200f, 100f, paint)
        val rendered = Bitmap.createBitmap(1000, 1000, Bitmap.Config.ARGB_8888)
        fun draw() { rendered.eraseColor(android.graphics.Color.BLACK); view.draw(android.graphics.Canvas(rendered)) }
        try {
            view.show("colored", image)
            view.rotateImage(1); assertEquals(0, view.geometrySnapshot().quarterTurns)
            view.preferences = view.preferences.copy(showRotationButtons = true)
            view.rotateImage(1); draw()
            assertEquals(android.graphics.Color.RED, rendered.getPixel(500, 250))
            assertEquals(android.graphics.Color.BLUE, rendered.getPixel(500, 750))
            assertEquals(android.graphics.Color.BLACK, rendered.getPixel(100, 500))
            view.rotateImage(-1); draw()
            assertEquals(android.graphics.Color.RED, rendered.getPixel(250, 500))
            repeat(4) { view.rotateImage(-1) }
            assertEquals(0, view.geometrySnapshot().quarterTurns)
            view.rotateImage(-1); draw()
            assertEquals(android.graphics.Color.BLUE, rendered.getPixel(500, 250))
            assertEquals(android.graphics.Color.RED, rendered.getPixel(500, 750))
            val now = SystemClock.uptimeMillis()
            tap(view, now, 500f, 500f); tap(view, now + 80, 500f, 500f)
            assertEquals(2.5f, view.geometrySnapshot().zoom, .01f)
            val down = MotionEvent.obtain(now + 500, now + 500, MotionEvent.ACTION_DOWN, 500f, 500f, 0)
            val move = MotionEvent.obtain(now + 500, now + 550, MotionEvent.ACTION_MOVE, 600f, 650f, 0)
            view.onTouchEvent(down); view.onTouchEvent(move); down.recycle(); move.recycle()
            assertTrue(view.geometrySnapshot().panY > 0f)
            assertTrue(steps.isEmpty())
            view.rotateImage(1)
            assertEquals(1f, view.geometrySnapshot().zoom, .01f)
            assertEquals(0f, view.geometrySnapshot().panY, .01f)
            view.rotateImage(1)
            view.layout(0, 0, 600, 1000)
            assertEquals(1, view.geometrySnapshot().quarterTurns)
            view.show("colored", image); assertEquals(1, view.geometrySnapshot().quarterTurns)
            view.show("next", image); assertEquals(0, view.geometrySnapshot().quarterTurns)
        } finally { view.show(null, null); image.recycle(); rendered.recycle() }
    }

    @Test fun disablingDoubleTapDeliversEveryRapidTapImmediatelyAndPreservesZones() = surface { view, steps ->
        view.preferences = view.preferences.copy(doubleTapZoom = false, tapRatio = .7f)
        val now = SystemClock.uptimeMillis()
        repeat(4) { index ->
            tap(view, now + index * 80)
            assertEquals("Each up must turn the page without a confirmation timeout", index + 1, steps.size)
        }
        assertEquals(listOf(1, 1, 1, 1), steps)
        assertEquals(1f, view.geometrySnapshot().zoom, 0f)
        view.preferences = view.preferences.copy(reversed = true)
        tap(view, now + 400, x = 900f)
        tap(view, now + 480, x = 100f)
        assertEquals(listOf(1, 1, 1, 1, -1, 1), steps)
    }

    @Test fun enablingDoubleTapZoomsInAndOutAndChangingTheSettingCancelsPendingTaps() = surface { view, steps ->
        val now = SystemClock.uptimeMillis()
        tap(view, now)
        tap(view, now + 80)
        assertEquals(2.5f, view.geometrySnapshot().zoom, .01f)
        assertTrue(steps.isEmpty())
        tap(view, now + 500)
        tap(view, now + 580)
        assertEquals(1f, view.geometrySnapshot().zoom, .01f)
        tap(view, now + 1000)
        view.preferences = view.preferences.copy(doubleTapZoom = false)
        tap(view, now + 1080)
        assertEquals(listOf(1), steps)
        assertEquals(1f, view.geometrySnapshot().zoom, .01f)
    }

    @Test fun disabledDoubleTapAndDragCannotStartSingleFingerQuickScale() = surface { view, steps ->
        view.preferences = view.preferences.copy(doubleTapZoom = false)
        val now = SystemClock.uptimeMillis()
        tap(view, now, x = 500f, y = 300f)
        for ((action, elapsed, y) in listOf(
            Triple(MotionEvent.ACTION_DOWN, 80L, 300f),
            Triple(MotionEvent.ACTION_MOVE, 100L, 330f),
            Triple(MotionEvent.ACTION_MOVE, 120L, 400f),
            Triple(MotionEvent.ACTION_MOVE, 140L, 500f),
            Triple(MotionEvent.ACTION_UP, 160L, 500f),
        )) {
            val event = MotionEvent.obtain(now + 80, now + elapsed, action, 500f, y, 0)
            try { view.onTouchEvent(event) } finally { event.recycle() }
        }
        assertEquals(1f, view.geometrySnapshot().zoom, .01f)
        assertEquals("The initial tap turns a page; the subsequent vertical drag does not", listOf(1), steps)
    }

    @Test fun disabledDoubleTapPreservesPinchAndPanAndCannotUnzoom() = surface { view, steps ->
        view.preferences = view.preferences.copy(doubleTapZoom = false)
        val now = SystemClock.uptimeMillis()
        fun event(action: Int, elapsed: Long, points: List<Pair<Float, Float>>) {
            val properties = points.indices.map { index -> MotionEvent.PointerProperties().apply {
                id = index; toolType = MotionEvent.TOOL_TYPE_FINGER
            } }.toTypedArray()
            val coordinates = points.map { (px, py) -> MotionEvent.PointerCoords().apply {
                x = px; y = py; pressure = 1f; size = 1f
            } }.toTypedArray()
            val motion = MotionEvent.obtain(now, now + elapsed, action, points.size, properties, coordinates,
                0, 0, 1f, 1f, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { view.onTouchEvent(motion) } finally { motion.recycle() }
        }
        event(MotionEvent.ACTION_DOWN, 0, listOf(300f to 500f))
        event(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 20,
            listOf(300f to 500f, 700f to 500f))
        event(MotionEvent.ACTION_MOVE, 40, listOf(200f to 500f, 800f to 500f))
        event(MotionEvent.ACTION_MOVE, 60, listOf(100f to 500f, 900f to 500f))
        event(MotionEvent.ACTION_MOVE, 80, listOf(50f to 500f, 950f to 500f))
        event(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 100,
            listOf(50f to 500f, 950f to 500f))
        event(MotionEvent.ACTION_UP, 120, listOf(50f to 500f))
        val zoom = view.geometrySnapshot().zoom
        assertTrue("Pinch must still zoom", zoom > 1.01f)
        assertTrue("Pinch must never turn a page", steps.isEmpty())
        tap(view, now + 200)
        tap(view, now + 280)
        assertEquals("Disabled double tap must not zoom out", zoom, view.geometrySnapshot().zoom, .01f)
        event(MotionEvent.ACTION_DOWN, 400, listOf(500f to 500f))
        event(MotionEvent.ACTION_MOVE, 440, listOf(600f to 500f))
        event(MotionEvent.ACTION_MOVE, 480, listOf(650f to 500f))
        event(MotionEvent.ACTION_UP, 500, listOf(650f to 500f))
        assertTrue("Zoomed drag must pan", view.geometrySnapshot().panX > 0f)
        assertTrue("Zoomed taps and pans must preserve the page", steps.isEmpty())
    }
}
