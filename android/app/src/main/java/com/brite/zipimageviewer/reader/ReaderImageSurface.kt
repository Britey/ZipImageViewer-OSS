package com.brite.zipimageviewer.reader

import android.animation.ValueAnimator
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Bundle
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import kotlin.math.abs
import kotlin.math.min

/** Native gesture arbitration keeps a pinch or zoomed pan from turning the page. */
internal class ReaderImageSurface(context: Context) : View(context) {
    var onStep: (Int) -> Unit = {}
    var onToggle: () -> Unit = {}
    var onZoomChanged: (Float) -> Unit = {}
    private var geometryGeneration = -1L
    var preferences = ReaderPreferences()
        set(value) {
            if (field.doubleTapZoom != value.doubleTapZoom) {
                // Drop pending confirmations before changing arbitration in a live reader.
                cancelGestures()
                detector.setOnDoubleTapListener(if (value.doubleTapZoom) gestureListener else null)
                scaleDetector.isQuickScaleEnabled = value.doubleTapZoom
            }
            field = value
        }
    private var pageIdentity: String? = null
    private var bitmap: Bitmap? = null
    private var previousBitmap: Bitmap? = null
    private var previousQuarterTurns = 0
    private var quarterTurns = 0
    private var slideProgress = 1f
    private var slideDirection = 1
    var navigationStep = 0
    private var zoom = 1f
    private var panX = 0f
    private var panY = 0f
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val destination = RectF()
    private var confirmedTap = false
    private var tapX = 0f
    private var tapY = 0f
    private var animator: ValueAnimator? = null
    private var multitouch = false
    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean { multitouch = true; return true }
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val old = zoom
            zoom = (zoom * detector.scaleFactor).coerceIn(1f, 3f)
            val ratio = zoom / old
            panX = (panX - (detector.focusX - width / 2f)) * ratio + (detector.focusX - width / 2f)
            panY = (panY - (detector.focusY - height / 2f)) * ratio + (detector.focusY - height / 2f)
            clampPan(); invalidate(); onZoomChanged(zoom); return true
        }
    })
    private val gestureListener = object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true
        override fun onSingleTapConfirmed(e: MotionEvent): Boolean = confirmTap(e)
        override fun onSingleTapUp(e: MotionEvent): Boolean =
            if (!preferences.doubleTapZoom) confirmTap(e) else false
        override fun onDoubleTap(e: MotionEvent): Boolean {
            if (!preferences.doubleTapZoom || multitouch) return false
            zoom = if (zoom > 1.01f) 1f else 2.5f
            panX = if (zoom == 1f) 0f else (width / 2f - e.x) * (zoom - 1f)
            panY = if (zoom == 1f) 0f else (height / 2f - e.y) * (zoom - 1f)
            clampPan(); invalidate(); onZoomChanged(zoom); return true
        }
        override fun onLongPress(e: MotionEvent) { onToggle(); performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS) }
        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
            if (zoom > 1.01f && !scaleDetector.isInProgress) { panX -= distanceX; panY -= distanceY; clampPan(); invalidate() }
            return true
        }
        override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
            if (e1 == null || zoom > 1.01f || multitouch) return false
            val dx = e2.x - e1.x; val dy = e2.y - e1.y
            if (abs(dx) > 48 * resources.displayMetrics.density && abs(dx) > abs(dy)) {
                onStep((if (dx < 0) 1 else -1) * if (preferences.reversed) -1 else 1)
                return true
            }
            return false
        }
    }
    private val detector = GestureDetector(context, gestureListener)
    private fun confirmTap(event: MotionEvent): Boolean {
        if (multitouch || scaleDetector.isInProgress) return false
        tapX = event.x; tapY = event.y; confirmedTap = true
        performClick(); return true
    }
    init { tag = "reader_image_surface"; isClickable = true; isFocusable = false; importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES }
    fun show(identity: String?, image: Bitmap?) {
        val pageChanged = identity != pageIdentity
        val outgoingQuarterTurns = quarterTurns
        if (pageChanged) { quarterTurns = 0; pageIdentity = identity; zoom = 1f; panX = 0f; panY = 0f }
        if (bitmap !== image) {
            val outgoing = bitmap
            cancelTransition()
            bitmap = image
            if (image != null && outgoing != null && pageChanged && navigationStep != 0 && preferences.animate && ValueAnimator.areAnimatorsEnabled()) {
                previousQuarterTurns = outgoingQuarterTurns
                previousBitmap = outgoing; slideProgress = 0f; slideDirection = if (navigationStep > 0) 1 else -1
                animator = ValueAnimator.ofFloat(0f, 1f).apply {
                    duration = 220
                    interpolator = android.view.animation.DecelerateInterpolator()
                    addUpdateListener { slideProgress = it.animatedValue as Float; invalidate() }
                    addListener(object : AnimatorListenerAdapter() {
                        override fun onAnimationEnd(animation: Animator) { previousBitmap = null; slideProgress = 1f; invalidate() }
                        override fun onAnimationCancel(animation: Animator) { previousBitmap = null; slideProgress = 1f }
                    })
                    start()
                }
            }
            invalidate()
        }
    }
    fun rotateImage(step: Int) {
        if (!preferences.showRotationButtons || bitmap == null) return
        setQuarterTurns((quarterTurns + step + 4) % 4)
    }
    fun setQuarterTurns(turns: Int) {
        if (quarterTurns == turns) return
        cancelGestures(); cancelTransition()
        quarterTurns = turns
        zoom = 1f; panX = 0f; panY = 0f
        invalidate(); onZoomChanged(zoom)
    }
    private fun cancelTransition() {
        animator?.cancel(); animator = null; previousBitmap = null; slideProgress = 1f; paint.alpha = 255
    }
    fun resetGeometry(generation: Long) {
        if (geometryGeneration == generation) return
        geometryGeneration = generation; zoom = 1f; panX = 0f; panY = 0f
        cancelTransition(); invalidate()
    }
    internal fun geometrySnapshot() = ReaderGeometry(zoom, panX, panY, bitmap?.width ?: 0, bitmap?.height ?: 0, paint.alpha, previousBitmap != null, slideDirection, quarterTurns)
    private fun baseScale(image: Bitmap, turns: Int = quarterTurns): Float =
        if (turns % 2 == 0) min(width.toFloat() / image.width, height.toFloat() / image.height)
        else min(width.toFloat() / image.height, height.toFloat() / image.width)
    private fun clampPan() {
        val image = bitmap ?: return
        val scale = baseScale(image) * zoom
        val limitX = (((if (quarterTurns % 2 == 0) image.width else image.height) * scale - width) / 2f).coerceAtLeast(0f)
        val limitY = (((if (quarterTurns % 2 == 0) image.height else image.width) * scale - height) / 2f).coerceAtLeast(0f)
        panX = panX.coerceIn(-limitX, limitX); panY = panY.coerceIn(-limitY, limitY)
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val image = bitmap ?: return
        clampPan()
        previousBitmap?.let { previous ->
            drawImage(canvas, previous, previousQuarterTurns, 1f, -width * slideDirection * slideProgress, 0f)
        }
        val translation = if (previousBitmap != null) width * slideDirection * (1f - slideProgress) else 0f
        drawImage(canvas, image, quarterTurns, zoom, panX + translation, panY)
    }
    private fun drawImage(canvas: Canvas, image: Bitmap, turns: Int, imageZoom: Float, x: Float, y: Float) {
        val scale = baseScale(image, turns) * imageZoom
        val w = image.width * scale; val h = image.height * scale
        canvas.save()
        canvas.translate(width / 2f + x, height / 2f + y)
        canvas.rotate(turns * 90f)
        destination.set(-w / 2f, -h / 2f, w / 2f, h / 2f)
        canvas.drawBitmap(image, null, destination, paint)
        canvas.restore()
    }
    // Without a double-tap listener, GestureDetector recognizes each single-tap-up
    // immediately. It still rejects scrolling, long presses and multi-touch sequences.
    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) { multitouch = false; parent?.requestDisallowInterceptTouchEvent(true) }
        if (event.pointerCount > 1) multitouch = true
        scaleDetector.onTouchEvent(event); detector.onTouchEvent(event)
        return true
    }
    private fun isCenterTap(x: Float, y: Float): Boolean {
        val density = resources.displayMetrics.density
        val patchWidth = min(width.toFloat(), (width * 0.2f).coerceIn(80f * density, 160f * density))
        val patchHeight = min(height.toFloat(), (height * 0.2f).coerceIn(80f * density, 160f * density))
        return abs(x - width / 2f) < patchWidth / 2f && abs(y - height / 2f) < patchHeight / 2f
    }
    override fun performClick(): Boolean {
        super.performClick()
        if (confirmedTap) {
            confirmedTap = false
            if (preferences.centerTap && isCenterTap(tapX, tapY)) onToggle()
            else if (zoom <= 1.01f) onStep((if (tapX < width * preferences.tapRatio) -1 else 1) * if (preferences.reversed) -1 else 1)
        } else {
            // Accessibility clicks have no touch coordinates: expose the reader controls.
            onToggle()
        }
        return true
    }
    private fun cancelGestures() {
        val now = android.os.SystemClock.uptimeMillis()
        val cancel = MotionEvent.obtain(now, now, MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
        scaleDetector.onTouchEvent(cancel)
        detector.onTouchEvent(cancel)
        cancel.recycle()
        confirmedTap = false
    }
    fun release() {
        cancelGestures()
        cancelTransition()
        bitmap = null
        onStep = {}; onToggle = {}; onZoomChanged = {}
    }
    override fun onDetachedFromWindow() {
        cancelGestures()
        cancelTransition()
        super.onDetachedFromWindow()
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w != oldw || h != oldh) cancelTransition()
    }
    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD)
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD)
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_LONG_CLICK)
    }
    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean = when (action) {
        AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> { onStep(1); true }
        AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> { onStep(-1); true }
        AccessibilityNodeInfo.ACTION_CLICK -> performClick()
        AccessibilityNodeInfo.ACTION_LONG_CLICK -> { onToggle(); true }
        else -> super.performAccessibilityAction(action, arguments)
    }
}

internal data class ReaderGeometry(val zoom: Float, val panX: Float, val panY: Float, val bitmapWidth: Int, val bitmapHeight: Int, val alpha: Int, val transitioning: Boolean, val direction: Int, val quarterTurns: Int)
