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
import java.util.concurrent.ScheduledFuture
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
 *
 * While up, a watchdog restarts a tunnel that went one-way (see [checkHealth]).
 */
object SlimeTunnel {
    private const val NAME = "slimeos0"
    private const val IDLE_CLOSE_MS = 60_000L
    private const val HEALTH_TICK_MS = 5_000L
    // Nothing received for this long: probe the hub; two failed probes in a row restart.
    private const val QUIET_PROBE_MS = 15_000L
    private const val FAILED_PROBES_TO_RESTART = 2

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
    private val health = Executors.newSingleThreadScheduledExecutor()
    private var healthJob: ScheduledFuture<*>? = null
    private var config: Config? = null
    @Volatile private var lastRx = -1L
    @Volatile private var lastRxAt = 0L
    private var failedProbes = 0
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
        this.config = config
        lastRx = -1L
        lastRxAt = SystemClock.elapsedRealtime()
        failedProbes = 0
        if (healthJob == null) {
            healthJob = health.scheduleWithFixedDelay(
                ::checkHealth, HEALTH_TICK_MS, HEALTH_TICK_MS, TimeUnit.MILLISECONDS
            )
        }
    }

    /** Blocks: call off the main thread. */
    @Synchronized
    fun down() {
        healthJob?.cancel(false)
        healthJob = null
        backend?.setState(tunnel, Tunnel.State.DOWN, null)
    }

    /** How long the tunnel has received nothing, in ms; 0 while it's down. */
    fun quietForMs(): Long =
        if (healthJob == null) 0 else SystemClock.elapsedRealtime() - lastRxAt

    /**
     * A home router can turn the tunnel's NAT mapping one-way: the hub gets the device's
     * packets and answers every handshake, but the answers never arrive (MatePad,
     * 2026-10-17: 10+ minutes, while another device behind the same router was fine).
     * WireGuard keeps retrying on the same UDP port, so it never recovers by itself.
     * Received bytes stopped: probe the hub (any answer counts as received bytes);
     * still nothing: bring the tunnel up again, on a new random port and so a new
     * mapping. A dead tunnel loses the session either way; the app reconnects.
     */
    private fun checkHealth() {
        val rx = try {
            backend?.getStatistics(tunnel)?.totalRx() ?: return
        } catch (e: Exception) {
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (rx != lastRx) {
            lastRx = rx
            lastRxAt = now
            failedProbes = 0
            return
        }
        if (now - lastRxAt < QUIET_PROBE_MS) return
        if (BrainPower.pingHubMs() != null) return // its answer moves rx on the next tick
        failedProbes++
        Log.w("SlimeTunnel", "Nothing from the hub for ${(now - lastRxAt) / 1000} s ($failedProbes failed probes)")
        if (failedProbes < FAILED_PROBES_TO_RESTART) return
        val config = config ?: return
        Log.w("SlimeTunnel", "Tunnel is one-way; bringing it up again on a new port")
        try {
            synchronized(this) {
                if (healthJob == null) return // closed meanwhile (down())
                backend?.setState(tunnel, Tunnel.State.DOWN, null)
                backend?.setState(tunnel, Tunnel.State.UP, config)
            }
        } catch (e: Exception) {
            Log.w("SlimeTunnel", "Couldn't restart the tunnel", e)
        }
        lastRx = -1L
        lastRxAt = SystemClock.elapsedRealtime()
        failedProbes = 0
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
