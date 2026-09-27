package com.slimeos.app

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.Toast
import androidx.lifecycle.lifecycleScope
import com.freerdp.freerdpcore.presentation.SessionActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// A healthy session answers a tap with a screen update within a couple of
// seconds. When, within FREEZE_WINDOW_MS, at least FREEZE_MIN_TAPS taps spread over
// FREEZE_MIN_SPAN_MS got none and at most one got one (a frozen Brain still let a
// frame through every ~30 s on 2026-09-28, when NVIDIA's encoder hung a session
// that only a Brain restart cleared), the Brain has most likely frozen. A tap on
// empty desktop can also change nothing, so this only asks.
private const val TAP_ANSWER_MS = 2_000L
private const val FREEZE_WINDOW_MS = 60_000L
private const val FREEZE_MIN_TAPS = 5
private const val FREEZE_MIN_SPAN_MS = 15_000L

/**
 * freeRDPCore's SessionActivity only takes connection settings from its
 * `freerdp://` URI, password included. RdpLauncher sends the password as an
 * extra instead, and it is added to the URI here, inside this process, just
 * before SessionActivity reads it (#47): the intent the system routes, logs
 * and keeps for recents never holds it. If Android ever recreates this
 * activity from its own copy of the intent, freeRDPCore asks for the password.
 */
class SlimeSessionActivity : SessionActivity() {

    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var lastFrameAt = 0L
    private val pendingTaps = ArrayDeque<Long>() // taps not yet TAP_ANSWER_MS old
    private val unansweredTaps = ArrayDeque<Long>()
    private val answeredTaps = ArrayDeque<Long>()
    private var askedAboutFreeze = false // the question is on screen

    private val freezeCheck = object : Runnable {
        override fun run() {
            checkForFreeze()
            handler.postDelayed(this, 1_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val password = intent.getStringExtra(EXTRA_PASSWORD)
        val uri = intent.data
        if (password != null && uri != null) {
            intent.data = uri.buildUpon().appendQueryParameter("p", password).build()
            intent.removeExtra(EXTRA_PASSWORD)
        }
        super.onCreate(savedInstanceState)
        // A remote desktop gets no touches while video plays; don't let Android
        // dim and lock the tablet under it. Only for this window, so it ends
        // with the session.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun onResume() {
        super.onResume()
        // Nothing counts from before the pause: the Brain may rightly have sent nothing.
        pendingTaps.clear()
        unansweredTaps.clear()
        answeredTaps.clear()
        handler.post(freezeCheck)
    }

    override fun onPause() {
        handler.removeCallbacks(freezeCheck)
        super.onPause()
    }

    override fun OnGraphicsUpdate(x: Int, y: Int, width: Int, height: Int) {
        lastFrameAt = SystemClock.elapsedRealtime()
        super.OnGraphicsUpdate(x, y, width, height)
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) pendingTaps.addLast(SystemClock.elapsedRealtime())
        return super.dispatchTouchEvent(ev)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) pendingTaps.addLast(SystemClock.elapsedRealtime())
        return super.dispatchKeyEvent(event)
    }

    private fun checkForFreeze() {
        val now = SystemClock.elapsedRealtime()
        val frame = lastFrameAt
        while (pendingTaps.isNotEmpty() && now - pendingTaps.first() >= TAP_ANSWER_MS) {
            val tap = pendingTaps.removeFirst()
            (if (frame >= tap) answeredTaps else unansweredTaps).addLast(tap)
        }
        for (taps in listOf(unansweredTaps, answeredTaps)) {
            while (taps.isNotEmpty() && now - taps.first() > FREEZE_WINDOW_MS) taps.removeFirst()
        }
        if (answeredTaps.size > 1) {
            unansweredTaps.clear() // responding again
            return
        }
        if (askedAboutFreeze || unansweredTaps.size < FREEZE_MIN_TAPS) return
        if (unansweredTaps.last() - unansweredTaps.first() < FREEZE_MIN_SPAN_MS) return
        askedAboutFreeze = true
        unansweredTaps.clear()
        Log.w("SlimeSession", "Brain looks frozen: $FREEZE_MIN_TAPS+ taps without a screen update")
        askToRestart()
    }

    private fun askToRestart() {
        if (isFinishing) return
        AlertDialog.Builder(this)
            .setTitle("Your Brain seems frozen")
            .setMessage(
                "The screen hasn't changed for your last few taps. Restart the Brain? " +
                    "Anything open on it closes. It takes about 2 minutes, then you're reconnected."
            )
            .setPositiveButton("Restart") { _, _ -> restartBrain() }
            .setNegativeButton("Keep waiting", null)
            // Asks again only after another FREEZE_MIN_TAPS unanswered taps.
            .setOnDismissListener { askedAboutFreeze = false }
            .show()
    }

    private fun restartBrain() {
        val host = intent.data?.host ?: return
        lifecycleScope.launch {
            val ok = withContext(Dispatchers.IO) { BrainPower.restart(host) }
            if (!ok) {
                Toast.makeText(
                    this@SlimeSessionActivity,
                    "Couldn't restart the Brain from here.",
                    Toast.LENGTH_LONG
                ).show()
                return@launch
            }
            // Before freeRDPCore sets its own result as the connection closes: a
            // finished activity's result is final.
            setResult(Activity.RESULT_CANCELED, Intent().putExtra(RESULT_RESTARTING, true))
            finish()
        }
    }

    companion object {
        const val EXTRA_PASSWORD = "com.slimeos.app.extra.PASSWORD"
        const val RESULT_RESTARTING = "com.slimeos.app.result.RESTARTING"
    }
}
