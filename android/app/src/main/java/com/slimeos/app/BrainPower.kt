package com.slimeos.app

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
