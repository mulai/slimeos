package com.slimeos.app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

/**
 * Feedback and crash reports, to the same slimeos.com endpoints the Membrane uses
 * (membrane/session/feedback.sh and crash-reporting.sh): public, rate-limited, and
 * each opens a GitHub issue. The server scrubs again before storing anything.
 *
 * Never sent: the Brain's address, name or password, the pairing, IP addresses,
 * Wi-Fi names, the PIN, or anything typed except the feedback message itself.
 *
 * Crash reports are opt-in (Settings > Security & Privacy > Privacy), as on the
 * Membrane. A Kotlin crash is written down as it happens and sent on the next
 * start. A native crash (FreeRDP) kills the process before anything can run, so a
 * session that never ended is reported on the next start instead, with Android's
 * own exit reason where the system keeps one (Android 11 and later).
 */
object Reporter {

    private const val FEEDBACK_URL = "https://www.slimeos.com/api/device/feedback"
    private const val CRASH_URL = "https://www.slimeos.com/api/report-error"
    private const val TAG = "Reporter"

    // --------------------------------------------------------------- feedback

    sealed class Result {
        data class Sent(val issueUrl: String?) : Result()
        data class Failed(val message: String) : Result()
    }

    /** category: "bug", "feature" or "other". Blocking; call off the main thread. */
    fun sendFeedback(context: Context, category: String, message: String, extra: Map<String, Any?>): Result {
        val body = JSONObject()
            .put("category", category)
            .put("message", scrub(message))
            .put("membrane_version", appVersion(context))
            .put("diagnostics", diagnostics(context, extra))
        return try {
            val (code, text) = post(FEEDBACK_URL, body, 15_000)
            val json = runCatching { JSONObject(text) }.getOrNull()
            if (code in 200..299 && json?.optBoolean("ok") == true) {
                Result.Sent(json.optString("issue_url").takeIf { it.isNotEmpty() && it != "null" })
            } else {
                Result.Failed(json?.optString("error")?.takeIf { it.isNotEmpty() } ?: "The server couldn’t accept that right now.")
            }
        } catch (e: Exception) {
            Log.w(TAG, "feedback failed: ${e.message}")
            Result.Failed("Couldn’t send just now — check your connection and try again.")
        }
    }

    // --------------------------------------------------------------- crash reports

    fun crashReportsEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_CRASH_REPORTS, false)

    fun setCrashReportsEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_CRASH_REPORTS, enabled).apply()
        if (!enabled) {
            pendingFile(context).delete()
            sessionFile(context).delete()
        }
    }

    /** Once per process: Kotlin crashes are written down for the next start. */
    fun install(context: Context) {
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is CrashCatcher) return
        Thread.setDefaultUncaughtExceptionHandler(CrashCatcher(app, previous))
    }

    private class CrashCatcher(
        private val context: Context,
        private val previous: Thread.UncaughtExceptionHandler?
    ) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, e: Throwable) {
            try {
                if (crashReportsEnabled(context)) {
                    val report = JSONObject()
                        .put("message", "${e.javaClass.simpleName}: ${e.message ?: ""}")
                        .put("stack", Log.getStackTraceString(e))
                        .put("source", "android:${thread.name}")
                    pendingFile(context).writeText(report.toString())
                }
            } catch (ignored: Throwable) {
                // Never let reporting get in the way of the crash itself.
            }
            previous?.uncaughtException(thread, e)
        }
    }

    /** Just before a session starts: if the process dies, the next start says so. */
    fun sessionStarted(context: Context) {
        if (!crashReportsEnabled(context)) return
        val note = JSONObject()
            .put("startedAt", System.currentTimeMillis())
            .put("resolution", DisplayPrefs.resolution(context).name)
            .put("h264", OpenH264.isEnabled(context))
        runCatching { sessionFile(context).writeText(note.toString()) }
    }

    fun sessionEnded(context: Context) {
        sessionFile(context).delete()
    }

    /** At start, off the main thread: sends what the last run left behind. */
    fun sendPending(context: Context) {
        val pending = pendingFile(context)
        val session = sessionFile(context)
        if (!crashReportsEnabled(context)) {
            pending.delete()
            session.delete()
            return
        }
        if (pending.isFile) {
            runCatching { JSONObject(pending.readText()) }.getOrNull()?.let { sendCrash(context, it) }
            pending.delete()
            session.delete() // the same death, already reported
            return
        }
        if (!session.isFile) return
        val note = runCatching { JSONObject(session.readText()) }.getOrNull()
        session.delete()
        if (note == null) return
        val exit = lastExitReason(context, note.optLong("startedAt"))
        // Nothing that differs between occurrences: the server groups repeats by the
        // message and the start of the stack, and files a GitHub issue per new group.
        val report = JSONObject()
            .put("message", "Session ended with the app process: ${exit ?: "no reason (Android ${Build.VERSION.RELEASE})"}")
            .put(
                "stack",
                "The app was gone without ending its session (crash, or stopped by the system or the user).\n" +
                    "Resolution: ${note.optString("resolution")}, H.264: ${note.optBoolean("h264")}"
            )
            .put("source", "android:session")
        sendCrash(context, report)
    }

    private fun lastExitReason(context: Context, since: Long): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        return try {
            val am = context.getSystemService(ActivityManager::class.java)
            val info = am.getHistoricalProcessExitReasons(context.packageName, 0, 5)
                .firstOrNull { it.timestamp >= since } ?: return null
            val reason = when (info.reason) {
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
                ApplicationExitInfo.REASON_CRASH -> "crash"
                ApplicationExitInfo.REASON_ANR -> "not responding (ANR)"
                ApplicationExitInfo.REASON_LOW_MEMORY -> "killed for low memory"
                ApplicationExitInfo.REASON_USER_REQUESTED -> "closed by the user"
                ApplicationExitInfo.REASON_SIGNALED -> "killed by signal ${info.status}"
                else -> "exit reason ${info.reason}"
            }
            listOfNotNull(reason, info.description?.takeIf { it.isNotBlank() }).joinToString(": ")
        } catch (e: Exception) {
            null
        }
    }

    private fun sendCrash(context: Context, report: JSONObject) {
        val body = JSONObject()
            .put("message", scrub(report.optString("message")).take(500))
            .put("stack", scrub(report.optString("stack")).take(4000))
            .put("source", report.optString("source").take(50))
            .put("slimeos_version", appVersion(context))
            .put("hardware_profile", hardwareProfile())
        try {
            val (code, _) = post(CRASH_URL, body, 10_000)
            Log.i(TAG, "crash report sent: HTTP $code")
        } catch (e: Exception) {
            Log.w(TAG, "crash report failed: ${e.message}")
        }
    }

    // --------------------------------------------------------------- shared

    fun appVersion(context: Context): String = try {
        "android-" + (context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "?")
    } catch (e: Exception) {
        "android-?"
    }

    private fun hardwareProfile() = "android-${Build.MODEL}".take(50)

    private fun diagnostics(context: Context, extra: Map<String, Any?>): JSONObject {
        val am = context.getSystemService(ActivityManager::class.java)
        val mem = ActivityManager.MemoryInfo().also { am?.getMemoryInfo(it) }
        val d = JSONObject()
            .put("client", "android")
            .put("hardware_profile", hardwareProfile())
            .put("manufacturer", Build.MANUFACTURER)
            .put("model", Build.MODEL)
            .put("android", "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            .put("abi", Build.SUPPORTED_ABIS.firstOrNull())
            .put("ram_mb", mem.totalMem / (1024 * 1024))
            .put("ram_available_mb", mem.availMem / (1024 * 1024))
            .put("resolution", DisplayPrefs.resolution(context).name)
            .put("h264", OpenH264.isEnabled(context))
        extra.forEach { (k, v) -> if (k != "tunnel") d.put(k, v) }
        // The shape the server's issue summary reads (net.iface_type / mtu / tunnel,
        // brain.stack_guess), as the Membrane's diagnostics have it.
        val (ifaceType, mtu) = underlyingNetwork(context)
        d.put(
            "net",
            JSONObject().put("iface_type", ifaceType).put("mtu", mtu).put("tunnel", extra["tunnel"])
        )
        d.put("brain", JSONObject().put("stack_guess", "windows (rdp)"))
        return d
    }

    /** The network under the VPN: wifi / cellular / ethernet, and its MTU if Android knows it. */
    private fun underlyingNetwork(context: Context): Pair<String?, Int?> {
        return try {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null to null
            @Suppress("DEPRECATION")
            for (network in cm.allNetworks) {
                val caps = cm.getNetworkCapabilities(network) ?: continue
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
                if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
                val type = when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    else -> "other"
                }
                val mtu = cm.getLinkProperties(network)?.mtu?.takeIf { it > 0 }
                return type to mtu
            }
            null to null
        } catch (e: Exception) {
            null to null
        }
    }

    private val IPV4 = Regex("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
    private val EMAIL = Regex("[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+")

    /** On-device first pass; the server's scrubPii() runs again. */
    private fun scrub(text: String) = text.replace(EMAIL, "[email]").replace(IPV4, "[ip]")

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

    private fun pendingFile(context: Context) = File(context.filesDir, "crash-pending.json")
    private fun sessionFile(context: Context) = File(context.filesDir, "session-running.json")
    private fun prefs(context: Context) = context.getSharedPreferences("reporting", Context.MODE_PRIVATE)
    private const val KEY_CRASH_REPORTS = "crash_reports"
}
