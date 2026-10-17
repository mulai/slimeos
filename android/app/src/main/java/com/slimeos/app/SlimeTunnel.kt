package com.slimeos.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
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
    private val resolver = Executors.newCachedThreadPool()
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

    /**
     * Looks up each peer's endpoint host within [timeoutMs] in all; the host that didn't
     * resolve, or null. GoBackend's own lookup has no time limit (10 tries a second apart,
     * each as long as the network's DNS takes), which left the app on "Connecting" for
     * minutes. InetEndpoint keeps an answer for a minute, so GoBackend then reuses ours.
     * Blocks: call off the main thread.
     */
    fun unresolvedHost(config: Config, timeoutMs: Long): String? {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        for (peer in config.peers) {
            val endpoint = peer.endpoint.orElse(null) ?: continue
            val left = (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0)
            val resolved = try {
                resolver.submit(Callable { endpoint.resolved }).get(left, TimeUnit.MILLISECONDS)
            } catch (e: Exception) {
                null
            }
            if (resolved?.isPresent != true) return endpoint.host
        }
        return null
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
