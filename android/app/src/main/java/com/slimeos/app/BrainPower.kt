package com.slimeos.app

import android.util.Log
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.nio.charset.StandardCharsets

/**
 * Fire-and-forget parity with membrane/freerdp/connect.sh's notify_session_ended():
 * tells brain/power to force-logoff the stale disconnected RDP session (see #17),
 * so this new client type doesn't reintroduce the bug that fix already closed.
 */
object BrainPower {

    private const val POWER_URL = "http://10.10.0.1:7677"

    /**
     * Mirrors connect.sh's wake_brain(): some Brains (e.g. the Azure GPU Brain) are
     * auto-deallocated when idle and need an explicit wake + poll before RDP will
     * connect — a bare TCP attempt against a deallocated VM just times out.
     */
    sealed class WakeState {
        object Ready : WakeState()
        object Starting : WakeState()
        /** The hub is still logging off the previous session (#17); usually ~10 s. */
        object Cleaning : WakeState()
        object Failed : WakeState()
        /** The hub refused: this device isn't on the Brain's POWER_VMS list. */
        object NotAllowed : WakeState()
        data class Error(val message: String) : WakeState()
    }

    fun wake(host: String): WakeState {
        return try {
            val conn = URL("$POWER_URL/wake").openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = 10_000
            conn.readTimeout = 10_000
            conn.setRequestProperty("Content-Type", "application/json")
            OutputStreamWriter(conn.outputStream, StandardCharsets.UTF_8).use {
                it.write(JSONObject().put("host", host).toString())
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            conn.disconnect()
            Log.i("BrainPower", "wake($host) -> HTTP $code: $text")
            // A 403 carries no "managed" field, which must not read as "unmanaged,
            // go ahead": a managed Brain that's asleep would then just time out.
            if (code == HttpURLConnection.HTTP_FORBIDDEN) return WakeState.NotAllowed
            val json = JSONObject(text)
            if (!json.optBoolean("managed", false)) return WakeState.Ready
            when (json.optString("state")) {
                "running" -> WakeState.Ready
                "failed" -> WakeState.Failed
                "cleaning" -> WakeState.Cleaning
                else -> WakeState.Starting // starting/deallocated/stopped/stopping/deallocating/unknown
            }
        } catch (e: Exception) {
            Log.e("BrainPower", "wake($host) failed", e)
            WakeState.Error(e.message ?: "wake request failed")
        }
    }

    /**
     * Azure reports a VM "running" well before Windows listens for RDP, and after a
     * TermService crash the port is closed until the service restarts. Mirrors
     * connect.sh's port probe after a wake.
     */
    fun rdpListening(host: String, port: Int): Boolean {
        return try {
            Socket().use { it.connect(InetSocketAddress(host, port), 2_000) }
            true
        } catch (e: Exception) {
            false
        }
    }

    fun notifySessionEnded(host: String) {
        try {
            val conn = URL("$POWER_URL/session-ended").openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = 5_000
            conn.readTimeout = 5_000
            conn.setRequestProperty("Content-Type", "application/json")
            OutputStreamWriter(conn.outputStream, StandardCharsets.UTF_8).use {
                it.write(JSONObject().put("host", host).toString())
            }
            conn.responseCode // drain, best-effort
            conn.disconnect()
        } catch (e: Exception) {
            // best-effort, matches connect.sh's fire-and-forget behavior
        }
    }
}
