package com.slimeos.app

import com.wireguard.config.Config
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

/**
 * M1 spike: replicates membrane/session/pair.sh's pair_fetch_config() — the same
 * POST https://<host>/pair the desktop Membrane calls, hitting brain/enroll directly.
 */
class PairingFailedException(message: String) : Exception(message)

object PairingApi {

    fun fetchWireGuardConfig(enrollmentHost: String, code: String): Config {
        val url = URL("https://$enrollmentHost/pair")
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.doOutput = true
        conn.connectTimeout = 15_000
        conn.readTimeout = 15_000
        conn.setRequestProperty("Content-Type", "application/json")

        val body = JSONObject().put("code", code).toString()
        OutputStreamWriter(conn.outputStream, StandardCharsets.UTF_8).use { it.write(body) }

        val responseCode = conn.responseCode
        val stream = if (responseCode in 200..299) conn.inputStream else conn.errorStream
        val text = stream?.bufferedReader()?.use { it.readText() } ?: ""

        val json = try {
            JSONObject(text)
        } catch (e: Exception) {
            throw PairingFailedException("bad_response (HTTP $responseCode)")
        }

        if (!json.optBoolean("ok", false)) {
            throw PairingFailedException(json.optString("error", "unknown_error"))
        }

        val configText = json.getString("config")
        return Config.parse(ByteArrayInputStream(configText.toByteArray(StandardCharsets.UTF_8)))
    }
}
