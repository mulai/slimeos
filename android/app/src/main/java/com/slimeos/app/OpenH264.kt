package com.slimeos.app

import android.content.Context
import android.os.Build
import android.system.Os
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * H.264 video through Cisco's OpenH264 binary, downloaded on the device.
 *
 * Cisco's AVC/H.264 patent license covers its binary (and not a build of the
 * source) only if: 1. it is downloaded separately to the device, never bundled
 * (app/build.gradle keeps FreeRDP's own build out of the APK); 2. the user can
 * enable, disable and re-enable it; 3. that control shows [NOTICE]; 4. the
 * license text (assets/openh264-binary-license.txt) is shown where licensing
 * information is. See http://www.openh264.org/BINARY_LICENSE.txt.
 *
 * FreeRDP loads the library from FREERDP_OPENH264_LIBRARY and only offers H.264
 * to the Brain when it loads (android/freerdp-patches/openh264-runtime-loading.patch),
 * so without it the session falls back to the other codecs.
 */
object OpenH264 {

    const val NOTICE = "OpenH264 Video Codec provided by Cisco Systems, Inc."
    const val LICENSE_ASSET = "openh264-binary-license.txt"

    // Must match the headers FreeRDP is built against (OPENH264_TAG in
    // third_party/FreeRDP/cmake/DepVersions.cmake).
    private const val VERSION = "2.6.0"
    private const val URL_ARM64 =
        "https://ciscobinary.openh264.org/libopenh264-$VERSION-android-arm64.8.so.bz2"
    // SHA-256 of the unpacked library; its MD5 matches Cisco's signed
    // libopenh264-2.6.0-android-arm64.8.so.signed.md5.txt (c2d3d5da...).
    private const val SHA256_ARM64 =
        "4d9bc54d2d38e53eb7bd551ec61acb8ad8320d8b957bda751cfdbdcbfabc3b07"
    private const val MAX_DOWNLOAD_BYTES = 8L * 1024 * 1024

    private const val ENV_LIBRARY = "FREERDP_OPENH264_LIBRARY"
    private const val PREFS = "openh264"
    private const val KEY_ENABLED = "enabled"

    val isSupported: Boolean
        get() = Build.SUPPORTED_ABIS.contains("arm64-v8a")

    fun isEnabled(context: Context): Boolean =
        isSupported && prefs(context).getBoolean(KEY_ENABLED, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun isDownloaded(context: Context): Boolean = libraryFile(context).isFile

    /**
     * Downloads the library if it is enabled and missing, then tells FreeRDP
     * whether to use it. Blocking; call off the main thread. Returns whether
     * H.264 is on for the next session.
     */
    fun prepareSession(context: Context, onDownloading: () -> Unit): Boolean {
        val file = libraryFile(context)
        val ready = isEnabled(context) && (file.isFile || download(file, onDownloading))
        if (ready) {
            Os.setenv(ENV_LIBRARY, file.absolutePath, true)
        } else {
            Os.unsetenv(ENV_LIBRARY)
        }
        return ready
    }

    fun licenseText(context: Context): String =
        context.assets.open(LICENSE_ASSET).bufferedReader().use { it.readText() }

    private fun download(target: File, onDownloading: () -> Unit): Boolean {
        onDownloading()
        target.parentFile?.mkdirs()
        val partial = File(target.parentFile, target.name + ".part")
        return try {
            val conn = URL(URL_ARM64).openConnection() as HttpURLConnection
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            if (conn.responseCode != HttpURLConnection.HTTP_OK) return false

            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            BZip2CompressorInputStream(conn.inputStream.buffered()).use { input ->
                partial.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        total += n
                        if (total > MAX_DOWNLOAD_BYTES) return false
                        digest.update(buffer, 0, n)
                        output.write(buffer, 0, n)
                    }
                }
            }

            val sha256 = digest.digest().joinToString("") { "%02x".format(it) }
            if (sha256 != SHA256_ARM64) return false

            // Code loaded at runtime must not be writable (Android 14+ rule).
            partial.setReadOnly()
            partial.renameTo(target)
        } catch (e: Exception) {
            false
        } finally {
            partial.delete()
        }
    }

    private fun libraryFile(context: Context) =
        File(context.noBackupFilesDir, "openh264/libopenh264-$VERSION.so")

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
