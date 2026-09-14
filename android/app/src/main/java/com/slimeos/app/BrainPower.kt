package com.slimeos.app

import android.util.Log
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
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
        object Failed : WakeState()
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
            val json = JSONObject(text)
            if (!json.optBoolean("managed", false)) return WakeState.Ready
            when (json.optString("state")) {
                "running" -> WakeState.Ready
                "failed" -> WakeState.Failed
                else -> WakeState.Starting // starting/deallocated/stopped/stopping/deallocating/unknown
            }
        } catch (e: Exception) {
            Log.e("BrainPower", "wake($host) failed", e)
            WakeState.Error(e.message ?: "wake request failed")
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
