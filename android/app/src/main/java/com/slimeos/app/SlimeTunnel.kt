package com.slimeos.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import kotlin.concurrent.thread

/**
 * The app's one WireGuard tunnel, shared by every MainActivity. GoBackend only takes a
 * tunnel down for the same Tunnel object that brought it up, so a backend per activity
 * couldn't close a tunnel an earlier activity had opened.
 *
 * The tunnel stays up only while Slime OS is in use: [closeWhenIdle] closes it a minute
 * after the app leaves the screen with no session running, [close] closes it at once when
 * the app is closed, and MainActivity.onResume opens it again.
 */
object SlimeTunnel {
    private const val NAME = "slimeos0"
    private const val IDLE_CLOSE_MS = 60_000L

    private var backend: GoBackend? = null

    /** The current activity's tunnel state; called on the thread that changed it. */
    @Volatile
    var onStateChange: ((Tunnel.State) -> Unit)? = null

    private val tunnel = object : Tunnel {
        override fun getName() = NAME
        override fun onStateChange(newState: Tunnel.State) {
            onStateChange?.invoke(newState)
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val idleClose = Runnable { close() }

    fun init(context: Context) {
        if (backend == null) backend = GoBackend(context.applicationContext)
    }

    val isUp: Boolean
        get() = backend?.getState(tunnel) == Tunnel.State.UP

    /** Blocks: call off the main thread. */
    @Synchronized
    fun up(config: Config) {
        cancelIdleClose()
        backend!!.setState(tunnel, Tunnel.State.UP, config)
    }

    /** Blocks: call off the main thread. */
    @Synchronized
    fun down() {
        backend?.setState(tunnel, Tunnel.State.DOWN, null)
    }

    fun closeWhenIdle() {
        main.removeCallbacks(idleClose)
        main.postDelayed(idleClose, IDLE_CLOSE_MS)
    }

    fun cancelIdleClose() = main.removeCallbacks(idleClose)

    /** Closes the tunnel on its own thread: the activity that asked may already be gone. */
    fun close() {
        cancelIdleClose()
        if (!isUp) return
        Log.i("SlimeTunnel", "Closing the tunnel: Slime OS isn't in use")
        thread(name = "tunnel-close") {
            try {
                down()
            } catch (e: Exception) {
                Log.w("SlimeTunnel", "Couldn't close the tunnel", e)
            }
        }
    }
}
