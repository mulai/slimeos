package com.slimeos.app

import android.content.Context
import android.graphics.Point
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The session's resolution, Settings > Display & Sound > Video.
 *
 * Smooth (the default) asks Windows for a desktop whose long edge is at most
 * [SMOOTH_LONG_EDGE] and stretches it to the screen (freerdp-patches/
 * session-zoom-fit.patch). On the MatePad SE 11 that is 1440x900 instead of
 * 1920x1200: 56 % of the pixels for the one CPU core that decodes H.264, which
 * tops out around 24 frames/s at full size (2026-10-04), and bigger text and
 * buttons for fingers. Sharp uses every pixel of the screen.
 */
object DisplayPrefs {

    enum class Resolution { Smooth, Sharp }

    private const val SMOOTH_LONG_EDGE = 1440
    private const val KEY_RESOLUTION = "resolution"

    fun resolution(context: Context): Resolution =
        if (prefs(context).getString(KEY_RESOLUTION, null) == Resolution.Sharp.name) {
            Resolution.Sharp
        } else {
            Resolution.Smooth
        }

    fun setResolution(context: Context, value: Resolution) {
        prefs(context).edit().putString(KEY_RESOLUTION, value.name).apply()
    }

    /** The size to ask Windows for, given the window's size in pixels. */
    fun sessionSize(context: Context, window: Point): Point {
        val longEdge = max(window.x, window.y)
        if (resolution(context) == Resolution.Sharp || longEdge <= SMOOTH_LONG_EDGE) return window
        val scale = SMOOTH_LONG_EDGE.toFloat() / longEdge
        // Windows wants an even width; a multiple of 4 keeps the codecs happy.
        return Point(
            (window.x * scale / 4).roundToInt() * 4,
            (window.y * scale / 2).roundToInt() * 2
        )
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences("display", Context.MODE_PRIVATE)
}
