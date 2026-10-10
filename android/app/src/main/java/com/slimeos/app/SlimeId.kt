package com.slimeos.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.provider.Settings
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

/**
 * "Sign in with Slime ID", the same slimeos.com device endpoints the Membrane uses
 * (membrane/session/slime-id.sh, coordinator.sh's fetch_remote_brains, connect.sh's
 * fetch_brain_credential): a device-code sign-in approved on a phone, the account's
 * Brain list, saving a Brain to the account, and a paid Brain's Windows sign-in.
 * Slime ID never holds the WireGuard credential: a Brain from the list still needs
 * this tablet's pairing to reach it.
 */
object SlimeId {

    private const val API = "https://www.slimeos.com/api/device"

    class Session(val token: String, val email: String, val name: String)

    class DeviceCode(
        val deviceCode: String,
        val userCode: String,
        val verificationUri: String,
        val qr: Bitmap?,
        val expiresInS: Int,
        val intervalS: Int
    )

    sealed class Poll {
        object Pending : Poll()
        object Expired : Poll()
        class Approved(val session: Session) : Poll()
    }

    /** A Brain on the account (brains-list.ts). kind is "free" or "paid". */
    class RemoteBrain(val id: String, val kind: String, val name: String, val host: String, val port: Int)

    class Credential(val username: String, val password: String)

    class SlimeIdException(message: String) : Exception(message)

    /** device/start: a code to approve at slimeos.com/device. */
    fun start(context: Context): DeviceCode {
        val (code, text) = post("$API/start", JSONObject().put("label", deviceLabel(context)), 10_000)
        val json = try {
            JSONObject(text)
        } catch (e: Exception) {
            throw SlimeIdException("HTTP $code: ${text.take(200)}")
        }
        val deviceCode = json.optString("device_code")
        val userCode = json.optString("user_code")
        if (code !in 200..299 || deviceCode.isEmpty() || userCode.isEmpty()) {
            throw SlimeIdException("HTTP $code: ${json.optString("error", text.take(200))}")
        }
        return DeviceCode(
            deviceCode = deviceCode,
            userCode = userCode,
            verificationUri = json.optString("verification_uri"),
            qr = decodeDataUrl(json.optString("qr_data_url")),
            expiresInS = json.optInt("expires_in", 900),
            intervalS = json.optInt("interval", 4).coerceAtLeast(1)
        )
    }

    /** device/poll. Network trouble reads as Pending: the caller just asks again. */
    fun poll(deviceCode: String): Poll = try {
        val (_, text) = post("$API/poll", JSONObject().put("device_code", deviceCode), 5_000)
        val json = JSONObject(text)
        when (json.optString("status")) {
            "approved" -> {
                val user = json.optJSONObject("user")
                val token = json.optString("session_token")
                if (token.isEmpty()) {
                    Poll.Expired
                } else {
                    Poll.Approved(Session(token, user?.optString("email") ?: "", user?.optString("name") ?: ""))
                }
            }
            "expired" -> Poll.Expired
            else -> Poll.Pending
        }
    } catch (e: Exception) {
        Poll.Pending
    }

    /** Best effort, like slime_id_logout(): the tablet forgets the session either way. */
    fun logout(token: String) {
        try {
            post("$API/logout", JSONObject().put("session_token", token), 5_000)
        } catch (e: Exception) {
            Log.i("SlimeId", "logout: ${e.message}")
        }
    }

    /** device/brains-list; null when it couldn't be fetched (keep what's shown). */
    fun brains(token: String): List<RemoteBrain>? = try {
        val (code, text) = post("$API/brains-list", JSONObject().put("session_token", token), 5_000)
        if (code !in 200..299) {
            null
        } else {
            val list = JSONObject(text).optJSONArray("brains") ?: JSONArray()
            (0 until list.length()).mapNotNull { i ->
                val b = list.optJSONObject(i) ?: return@mapNotNull null
                val id = b.optString("id")
                // Server data: only well-formed addresses reach the picker (#37).
                val host = if (b.isNull("host")) "" else b.optString("host").trim()
                val port = if (b.isNull("port")) 3389 else b.optString("port").trim().toIntOrNull() ?: 3389
                if (id.isEmpty() || !validHost(host) || port !in 1..65535) return@mapNotNull null
                RemoteBrain(id, b.optString("kind", "free"), b.optString("name").ifBlank { "Untitled Brain" }, host, port)
            }
        }
    } catch (e: Exception) {
        Log.i("SlimeId", "brains-list: ${e.message}")
        null
    }

    /** device/brains-save: the opt-in "Save to your Slime ID?". */
    fun saveBrain(token: String, name: String, host: String, port: Int): Boolean = try {
        val body = JSONObject().put("session_token", token).put("name", name).put("host", host)
            .put("port", port.toString())
        val (code, text) = post("$API/brains-save", body, 5_000)
        code in 200..299 && JSONObject(text).optBoolean("ok")
    } catch (e: Exception) {
        false
    }

    /**
     * device/brain-credential: a paid Brain's Windows sign-in, fetched fresh before a
     * connect and never stored. null for any failure; the caller asks for it instead.
     */
    fun credential(token: String, brainId: String): Credential? = try {
        val body = JSONObject().put("session_token", token).put("brainId", brainId)
        val (code, text) = post("$API/brain-credential", body, 5_000)
        val json = JSONObject(text)
        val password = json.optString("password")
        if (code in 200..299 && json.optBoolean("ok") && password.isNotEmpty()) {
            Credential(json.optString("username"), password)
        } else {
            null
        }
    } catch (e: Exception) {
        null
    }

    /** Membrane's maskEmail(): j***e@example.com. */
    fun maskEmail(email: String): String {
        val parts = email.split("@")
        if (parts.size != 2 || parts[0].isEmpty()) return email
        val local = parts[0]
        val masked = if (local.length <= 2) "${local[0]}*" else "${local.first()}***${local.last()}"
        return "$masked@${parts[1]}"
    }

    /** XXXX-XXXX, as on the kiosk. */
    fun displayCode(userCode: String) =
        if (userCode.length == 8) "${userCode.take(4)}-${userCode.drop(4)}" else userCode

    private val HOST_RE = Regex(
        "^(?:(?:\\d{1,3}\\.){3}\\d{1,3}|[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?" +
            "(?:\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)$"
    )

    private fun validHost(host: String) = host.isNotEmpty() && host.length <= 253 && HOST_RE.matches(host)

    /** Names this tablet on slimeos.com/device and in the account's device list. */
    private fun deviceLabel(context: Context): String =
        (Settings.Global.getString(context.contentResolver, "device_name") ?: "")
            .ifBlank { Build.MODEL ?: "" }
            .ifBlank { "Slime OS tablet" }
            .take(40)

    private fun decodeDataUrl(url: String): Bitmap? = try {
        val comma = url.indexOf(',')
        if (!url.startsWith("data:image/") || comma < 0) {
            null
        } else {
            val bytes = Base64.decode(url.substring(comma + 1), Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }
    } catch (e: Exception) {
        null
    }

    private fun post(url: String, body: JSONObject, timeoutMs: Int): Pair<Int, String> {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            conn.setRequestProperty("Content-Type", "application/json")
            OutputStreamWriter(conn.outputStream, StandardCharsets.UTF_8).use { it.write(body.toString()) }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            return code to (stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally {
            conn.disconnect()
        }
    }
}
